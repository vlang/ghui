module main

import os
import time

fn refused_proxy_message(endpoint string) string {
	return 'Post "https://api.github.com/graphql": proxyconnect tcp: dial tcp ${endpoint}: connect: connection refused'
}

fn test_proxy_retry_requires_the_configured_loopback_proxy_to_refuse_connection() {
	for proxy in ['http://127.0.0.1:49224', '127.0.0.1:49224', 'http://localhost:49224',
		'https://user:password@localhost:49224'] {
		for name in ['HTTPS_PROXY', 'https_proxy'] {
			env := {
				name:       proxy
				'GH_TOKEN': 'test-token'
				'NO_PROXY': 'example.com'
			}
			direct := gh_proxy_retry_environment(env, refused_proxy_message('127.0.0.1:49224')) or {
				panic('Expected recovery for ${name}=${proxy}')
			}
			assert direct['GH_TOKEN'] == 'test-token'
			assert direct['NO_PROXY'] == 'example.com'
			assert name !in direct
			assert env[name] == proxy
		}
	}
	for endpoint in ['[::1]:49224', '127.0.0.2:49224'] {
		gh_proxy_retry_environment({
			'HTTPS_PROXY': 'http://${endpoint}'
		}, refused_proxy_message(endpoint)) or {
			panic('Expected loopback recovery for ${endpoint}')
		}
	}
	for proxy in ['http://localhost', 'https://localhost'] {
		port := if proxy.starts_with('https:') { '443' } else { '80' }
		gh_proxy_retry_environment({
			'HTTPS_PROXY': proxy
		}, refused_proxy_message('127.0.0.1:${port}')) or {
			panic('Expected default proxy port recovery.')
		}
	}
	for proxy in ['', 'http://proxy.example.com:49224', 'http://192.168.1.1:49224',
		'http://127.evil.example.com:49224', 'http://localhost:8080'] {
		// A lowercase local proxy cannot override an uppercase remote proxy.
		env := {
			'HTTPS_PROXY': proxy
			'https_proxy': 'http://localhost:8080'
		}
		if _ := gh_proxy_retry_environment(env, refused_proxy_message('127.0.0.1:49224')) {
			assert false, 'Must not bypass ${proxy}'
		}
	}
	for message in ['gh: Bad credentials (HTTP 401)', 'gh: Forbidden (HTTP 403)',
		'Post "https://api.github.com/graphql": dial tcp 127.0.0.1:49224: connect: connection refused',
		refused_proxy_message('192.0.2.1:49224'),
		refused_proxy_message('127.0.0.1:49224').replace('connection refused', 'i/o timeout')] {
		if _ := gh_proxy_retry_environment({
			'HTTPS_PROXY': 'http://localhost:49224'
		}, message) {
			assert false, 'Must not retry ${message}'
		}
	}
}

fn test_gh_recovers_from_a_stale_proxy_without_changing_parent_environment_or_repeating_api_errors() {
	$if windows {
		return
	} // The controllable CLI fixture uses a POSIX shell.
	root := os.join_path(os.temp_dir(), 'ghgui-proxy-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(root) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	previous := os.environ()
	names := ['PATH', 'FAKE_GH_PROXY_ROOT', 'NO_PROXY', 'no_proxy', ...gh_proxy_variables]
	defer {
		for name in names {
			if name in previous { os.setenv(name, previous[name], true) } else { os.unsetenv(name) }
		}
	}
	os.setenv('PATH', '${root}:${previous['PATH']}', true)
	os.setenv('FAKE_GH_PROXY_ROOT', root, true)
	os.setenv('NO_PROXY', 'example.com', true)
	os.setenv('no_proxy', 'example.com', true)
	for name in gh_proxy_variables { os.setenv(name, 'http://127.0.0.1:49224', true) }
	script := r'#!/bin/sh
set -eu
printf "call\n" >> "$FAKE_GH_PROXY_ROOT/calls"
printf "%s\n" "$@" >> "$FAKE_GH_PROXY_ROOT/args"
if [ -n "${HTTPS_PROXY:-${https_proxy:-}}" ] && [ ! -f "$FAKE_GH_PROXY_ROOT/proxy-works" ]; then
  cat "$FAKE_GH_PROXY_ROOT/error" >&2
  exit 1
fi
if [ ! -f "$FAKE_GH_PROXY_ROOT/proxy-works" ]; then
  [ -z "${HTTPS_PROXY:-}${https_proxy:-}${HTTP_PROXY:-}${http_proxy:-}${ALL_PROXY:-}${all_proxy:-}" ] || exit 2
fi
[ "$NO_PROXY" = example.com ] || exit 3
if [ -f "$FAKE_GH_PROXY_ROOT/direct-fails" ]; then
  printf "gh: Forbidden (HTTP 403)\n" >&2
  exit 1
fi
cat "$FAKE_GH_PROXY_ROOT/response"
'
	os.write_file(os.join_path(root, 'gh'), script) or { panic(err) }
	os.chmod(os.join_path(root, 'gh'), 0o700) or { panic(err) }
	os.write_file(os.join_path(root, 'error'), refused_proxy_message('127.0.0.1:49224')) or { panic(err) }
	response := '  diff --git a/file b/file\n+added\n\n'
	os.write_file(os.join_path(root, 'response'), response) or { panic(err) }
	args := ['api', '--hostname', 'github.com', 'graphql', '-f', 'query=query { viewer { login } }']
	assert (run_gh_raw_with_cancel(args, unsafe { nil }) or { panic(err) }) == response
	assert (os.read_file(os.join_path(root, 'calls')) or { panic(err) }) == 'call\ncall\n'
	assert (os.read_file(os.join_path(root, 'args')) or { panic(err) }) == '${args.join('\n')}\n'.repeat(2)
	for name in gh_proxy_variables {
		assert os.getenv(name) == 'http://127.0.0.1:49224'
	}
	// Each request starts with the configured proxy, which may have recovered.
	os.write_file(os.join_path(root, 'proxy-works'), '') or { panic(err) }
	assert (run_gh_with_cancel(args, unsafe { nil }) or { panic(err) }) == response.trim_space()
	assert (os.read_file(os.join_path(root, 'calls')) or { panic(err) }) == 'call\n'.repeat(3)
	os.rm(os.join_path(root, 'proxy-works')) or { panic(err) }
	// Never replay an API failure; this also protects comment and merge calls.
	os.write_file(os.join_path(root, 'error'), 'gh: Forbidden (HTTP 403)') or { panic(err) }
	if _ := run_gh_with_cancel(args, unsafe { nil }) {
		assert false
	} else {
		assert err.msg() == 'gh: Forbidden (HTTP 403)'
	}
	assert (os.read_file(os.join_path(root, 'calls')) or { panic(err) }) == 'call\n'.repeat(4)
	// Recovery has only one attempt, and reports a failed direct connection.
	os.write_file(os.join_path(root, 'error'), refused_proxy_message('127.0.0.1:49224')) or { panic(err) }
	os.write_file(os.join_path(root, 'direct-fails'), '') or { panic(err) }
	if _ := run_gh_with_cancel(args, unsafe { nil }) {
		assert false
	} else {
		assert err.msg().contains('direct GitHub connection also failed: gh: Forbidden (HTTP 403)')
	}
	assert (os.read_file(os.join_path(root, 'calls')) or { panic(err) }) == 'call\n'.repeat(6)
	mut token := &FetchCancellation{}
	token.stop()
	if _ := run_gh_with_cancel(args, token) {
		assert false
	} else {
		assert err.msg() == 'Request cancelled.'
	}
	assert (os.read_file(os.join_path(root, 'calls')) or { panic(err) }) == 'call\n'.repeat(6)
}
