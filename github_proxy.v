module main

import net.urllib

const gh_proxy_variables = ['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY',
	'all_proxy']

// Only bypass a configured loopback proxy after its TCP connection was refused.
// Authentication, API errors, timeouts and remote proxy failures must not retry.
fn gh_proxy_retry_environment(env map[string]string, message string) ?map[string]string {
	prefix := 'proxyconnect tcp: dial tcp '
	suffix := ': connect: connection refused'
	if !message.contains(prefix) || !message.ends_with(suffix) { return none }
	endpoint := urllib.parse('http://' + message.all_after(prefix).all_before(suffix)) or { return none }
	if !gh_loopback_host(endpoint.hostname()) { return none }
	// gh's HTTPS transport prefers the uppercase variable when both are set.
	proxy_value := if env['HTTPS_PROXY'] != '' { env['HTTPS_PROXY'] } else { env['https_proxy'] }
	if proxy_value == '' { return none }
	proxy := urllib.parse(if proxy_value.contains('://') {
		proxy_value
	} else {
		'http://${proxy_value}'
	}) or { return none }
	host := proxy.hostname().to_lower()
	if proxy.scheme !in ['http', 'https'] || !gh_loopback_host(host) { return none }
	port := if proxy.port() != '' {
		proxy.port()
	} else if proxy.scheme == 'https' {
		'443'
	} else {
		'80'
	}
	if port != endpoint.port() || (host != 'localhost' && host != endpoint.hostname()) {
		return none
	}
	mut direct_env := env.clone()
	for name in gh_proxy_variables { direct_env.delete(name) }
	return direct_env
}

fn gh_loopback_host(host string) bool {
	if host in ['localhost', '::1'] { return true }
	parts := host.split('.')
	if parts.len != 4 || parts[0] != '127' { return false }
	for part in parts {
		if part == '' || part.len > 3 || part.int() > 255 { return false }
		for ch in part.bytes() {
			if ch < `0` || ch > `9` { return false }
		}
	}
	return true
}
