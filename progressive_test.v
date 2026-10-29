module main

import os
import time

// Real worker/process tests with controllable responses: a later response
// stays blocked until the test has observed and rendered the earlier one.
const fake_gh_script = r'#!/bin/sh
set -eu
printf "call\n" >> "$FAKE_GH_ROOT/calls"
query=""
first=""
cursor=""
for arg in "$@"; do
  case "$arg" in
    query=*) query="$arg" ;;
    first=*) first="${arg#first=}" ;;
    cursor=*) cursor="${arg#cursor=}" ;;
  esac
done
wait_for() {
  n=0
  while [ ! -f "$FAKE_GH_ROOT/$1" ]; do
    n=$((n+1))
    [ "$n" -lt 300 ] || exit 2
    sleep 0.01
  done
}
case "$query" in
  *"query Issues"*)
    if [ "$first" = 15 ]; then
      if [ -f "$FAKE_GH_ROOT/hold-first" ]; then
        touch "$FAKE_GH_ROOT/first-started"
        wait_for release-first
      fi
      cat "$FAKE_GH_ROOT/issues-first.json"
    else
      [ "$first" = 35 ] || exit 3
      touch "$FAKE_GH_ROOT/issues-next-started"
      wait_for release-issues
      cat "$FAKE_GH_ROOT/issues-next.json"
    fi ;;
  *"query IssueBody"*)
    wait_for release-body
    cat "$FAKE_GH_ROOT/noise.txt" >&2
    cat "$FAKE_GH_ROOT/body.json" ;;
  *"query IssueComments"*)
    if [ "$first" = 10 ]; then
      cat "$FAKE_GH_ROOT/comments-first.json"
    else
      [ "$first" = 20 ] || exit 4
      wait_for release-comments
      if [ "$cursor" = comment10 ]; then
        cat "$FAKE_GH_ROOT/comments-next.json"
      else
        cat "$FAKE_GH_ROOT/comments-last.json"
      fi
    fi ;;
  *) exit 5 ;;
esac
'

fn fixture_issue_page(first int, count int, cursor string) string {
	mut nodes := []string{}
	for number in first .. first + count {
		date := '2026-10-01T12:00:${60 - number}Z'
		nodes << '{"number":${number},"title":"Issue ${number}","state":"OPEN","createdAt":"${date}","updatedAt":"${date}"}'
	}
	return '{"data":{"repository":{"open":{"totalCount":80},"closed":{"totalCount":1},"issues":{"pageInfo":{"hasNextPage":true,"endCursor":"${cursor}"},"nodes":[${nodes.join(',')}]}}}}'
}

fn fixture_comment_page(first int, count int, cursor string) string {
	mut nodes := []string{}
	for number in first .. first + count {
		nodes << '{"id":"comment${number}","body":"Reply ${number}"}'
	}
	return '{"data":{"repository":{"issue":{"number":1,"comments":{"totalCount":55,"pageInfo":{"hasNextPage":true,"endCursor":"${cursor}"},"nodes":[${nodes.join(',')}]}}}}}'
}

fn next_issue_result(results chan FetchResult) FetchResult {
	select {
		result := <-results {
			return result
		}
		2 * time.second {
			panic('No issue batch arrived while the next batch was blocked.')
		}
	}
	return FetchResult{}
}

fn next_detail_result(results chan DetailResult) DetailResult {
	select {
		result := <-results {
			return result
		}
		2 * time.second {
			panic('No detail batch arrived while another part was blocked.')
		}
	}
	return DetailResult{}
}

fn wait_for_marker(path string) {
	started := time.now()
	for !os.exists(path) {
		assert time.since(started) < 2 * time.second
		time.sleep(5 * time.millisecond)
	}
}

fn test_workers_publish_partial_data_and_cache_without_waiting_for_later_pages() {
	$if windows {
		return
	} // The controllable CLI fixture uses a POSIX shell.
	root := os.join_path(os.temp_dir(), 'ghgui-progress-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(os.join_path(root, 'bin')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	os.write_file(os.join_path(root, 'bin', 'gh'), fake_gh_script) or { panic(err) }
	os.chmod(os.join_path(root, 'bin', 'gh'), 0o700) or { panic(err) }
	old_path := os.getenv('PATH')
	old_root := os.getenv('FAKE_GH_ROOT')
	old_cache := os.getenv('GHGUI_CACHE_DIR')
	old_disable := os.getenv('GHGUI_NO_CACHE')
	old_database := os.getenv('GHGUI_DB_PATH')
	defer {
		os.setenv('PATH', old_path, true)
		os.setenv('FAKE_GH_ROOT', old_root, true)
		os.setenv('GHGUI_CACHE_DIR', old_cache, true)
		os.setenv('GHGUI_NO_CACHE', old_disable, true)
		os.setenv('GHGUI_DB_PATH', old_database, true)
	}
	os.setenv('PATH', '${os.join_path(root, 'bin')}:${old_path}', true)
	os.setenv('FAKE_GH_ROOT', root, true)
	os.setenv('GHGUI_CACHE_DIR', os.join_path(root, 'cache'), true)
	os.setenv('GHGUI_NO_CACHE', '0', true)
	os.setenv('GHGUI_DB_PATH', os.join_path(root, 'issues.sqlite3'), true)
	os.write_file(os.join_path(root, 'issues-first.json'), fixture_issue_page(1, 15, 'issue15')) or { panic(err) }
	os.write_file(os.join_path(root, 'issues-next.json'), fixture_issue_page(16, 35, 'issue50')) or { panic(err) }
	large_body := 'Description ${'x'.repeat(512 * 1024)}'
	os.write_file(os.join_path(root, 'body.json'), '{"data":{"repository":{"issue":{"number":1,"title":"Issue 1","state":"OPEN","createdAt":"2026-10-01T12:00:59Z","updatedAt":"2026-10-01T12:00:59Z","body":"${large_body}","comments":{"totalCount":55}}}}}') or { panic(err) }
	os.write_file(os.join_path(root, 'noise.txt'), 'warning\n'.repeat(8192)) or { panic(err) }
	os.write_file(os.join_path(root, 'comments-first.json'), fixture_comment_page(1, 10, 'comment10')) or { panic(err) }
	os.write_file(os.join_path(root, 'comments-next.json'), fixture_comment_page(11, 20, 'comment30')) or { panic(err) }
	os.write_file(os.join_path(root, 'comments-last.json'), fixture_comment_page(31, 20, 'comment50')) or { panic(err) }

	mut app := App{ repo: Repository{ owner: 'test', name: 'repo' } }
	request := app.begin_fetch(false)
	worker := spawn fetch_in_background(request, app.results)
	first := next_issue_result(app.results)
	assert first.error == ''
	assert !first.done && !first.cached
	app.apply_result(first)
	assert app.loading && app.issues.len == 15
	wait_for_marker(os.join_path(root, 'issues-next-started'))
	// Sorting during a delayed fetch neither restarts it nor changes its cursor.
	calls := os.read_file(os.join_path(root, 'calls')) or { panic(err) }
	app.change_sort('Oldest')
	assert app.issues[0].number == 15
	assert app.generation == request.generation && !cancelled(request.cancel)
	assert (os.read_file(os.join_path(root, 'calls')) or { panic(err) }) == calls
	os.write_file(os.join_path(root, 'release-issues'), '') or { panic(err) }
	last := next_issue_result(app.results)
	assert last.error == '' && last.done
	app.apply_result(last)
	assert !app.loading && app.issues.len == 50
	assert app.issues[0].number == 50 && app.issues.last().number == 1
	worker.wait()
	cache := read_issue_cache(request) or { panic('The last successful list was not cached.') }
	assert cache.issues.len == 50 && cache.cursor == 'issue50'
	assert (os.read_file(issue_database_path()) or { panic(err) }).starts_with('SQLite format 3')

	// The cache is published even when the first live response hasn't arrived.
	os.write_file(os.join_path(root, 'hold-first'), '') or { panic(err) }
	mut next_app := App{ repo: app.repo }
	next_request := next_app.begin_fetch(false)
	cache_worker := spawn fetch_in_background(next_request, next_app.results)
	cached := next_issue_result(next_app.results)
	assert cached.cached && !cached.done && cached.page.issues.len == 50
	next_app.apply_result(cached)
	assert next_app.loading && next_app.list_cached
	wait_for_marker(os.join_path(root, 'first-started'))
	next_app.list_cancel.stop()
	cache_worker.wait()
	assert next_app.results.len == 0

	app.open_issue(1)
	detail_request := app.begin_detail_fetch(false)
	detail_worker := spawn fetch_detail_in_background(detail_request, app.detail_results)
	comments := next_detail_result(app.detail_results)
	assert comments.part == .comments && !comments.done && comments.error == ''
	app.apply_detail_result(comments)
	assert app.detail.comments.len == 10 && !app.detail_loaded
	assert app.detail_body_loading && app.detail_comments_loading
	os.write_file(os.join_path(root, 'release-body'), '') or { panic(err) }
	body := next_detail_result(app.detail_results)
	assert body.part == .body && body.error == ''
	app.apply_detail_result(body)
	assert app.detail_loaded && app.detail.issue.body.len == large_body.len
	assert app.detail.issue.body.starts_with('Description')
	assert app.detail_comments_loading && app.detail.comments.len == 10
	os.write_file(os.join_path(root, 'release-comments'), '') or { panic(err) }
	app.apply_detail_result(next_detail_result(app.detail_results))
	assert app.detail_comments_loading && app.detail.comments.len == 30
	app.apply_detail_result(next_detail_result(app.detail_results))
	assert !app.detail_loading && app.detail.comments.len == 50
	assert app.detail.cursor == 'comment50' && app.detail.has_next
	detail_worker.wait()
}
