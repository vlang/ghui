module main

import os
import time
import ui2

const closed_issue_response = r'{"number":42,"state":"closed","state_reason":"completed","updated_at":"2026-10-04T10:00:00Z"}'

fn close_example_app() App {
	issue := Issue{
		number:     42
		title:      'Fix a bug'
		state:      'OPEN'
		body:       'Description'
		created_at: '2026-10-01T00:00:00Z'
		updated_at: '2026-10-02T00:00:00Z'
		comments:   Count{ total: 1 }
	}
	mut app := App{
		repo:         Repository{ owner: 'org', name: 'repo' }
		issues:       [issue]
		open_count:   4
		closed_count: 100
		loaded_state: 'OPEN'
	}
	app.open_issue(42)
	request := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{
		request: request
		detail:  IssueDetail{
			issue:    issue
			comments: [IssueComment{ id: 'first', body: 'First reply' }]
		}
	})
	return app
}

fn test_close_issue_requires_a_loaded_open_issue_and_prevents_double_clicks() {
	mut app := close_example_app()
	assert app.can_close_issue()
	valid := app.detail.issue
	for issue in [Issue{ ...valid, kind: .prs }, Issue{ ...valid, state: 'CLOSED' },
		Issue{ ...valid, state: '' }, Issue{ ...valid, number: 0 }] {
		app.detail = IssueDetail{ issue: issue }
		assert app.begin_close_issue() == none
		close_issue_args(CloseIssueRequest{ repo: app.repo, issue: issue }) or { continue }
		assert false, 'Invalid issue should never reach GitHub.'
	}
	app.detail = IssueDetail{ issue: valid }
	app.detail_loaded = false
	assert app.begin_close_issue() == none
	app.detail_loaded = true
	app.detail_body_loading = true
	assert app.begin_close_issue() == none
	app.detail_body_loading = false
	app.kind = .prs
	assert app.begin_close_issue() == none
	app.kind = .issues
	request := app.begin_close_issue() or { panic('Closing did not start.') }
	assert app.closing_current_issue() && app.begin_close_issue() == none
	args := close_issue_args(request) or { panic(err) }
	assert 'PATCH' in args && 'repos/org/repo/issues/42' in args
	assert 'state=closed' in args && 'state_reason=completed' in args
	close_issue_args(CloseIssueRequest{ repo: Repository{ owner: '..', name: 'repo' }, issue: valid }) or { return }
	assert false, 'Invalid repository should never reach GitHub.'
}

fn test_close_response_requires_confirmation_for_the_requested_issue() {
	app := close_example_app()
	issue := decode_closed_issue(closed_issue_response, app.detail.issue) or { panic(err) }
	assert issue.state == 'CLOSED' && issue.state_reason == 'COMPLETED'
	assert issue.updated_at == '2026-10-04T10:00:00Z'
	assert issue.title == 'Fix a bug' && issue.body == 'Description'
	for response in ['{"number":42,"state":"open"}', '{"number":7,"state":"closed"}',
		'{"number":42,"state":"closed","pull_request":{}}', '{"message":"Permission denied"}',
		'{}', 'invalid'] {
		decode_closed_issue(response, app.detail.issue) or { continue }
		assert false, response
	}
	decode_closed_issue('{"message":"Permission denied"}', app.detail.issue) or {
		assert err.msg() == 'Permission denied'
	}
}

fn test_close_success_updates_lists_counts_and_details_and_rejects_obsolete_reads() {
	mut app := close_example_app()
	app.list_cache['issues_OPEN'] = IssuePage{
		issues:       app.issues
		open_count:   4
		closed_count: 100
		has_next:     true
		cursor:       'next'
	}
	app.list_cache['issues_CLOSED'] = IssuePage{ open_count: 4, closed_count: 100 }
	old_list := app.begin_fetch(false)
	old_detail := app.begin_detail_fetch(true)
	app.toggle_selection(42)
	app.set_comment_draft('Unsent draft')
	request := app.begin_close_issue() or { panic('Closing did not start.') }
	// A reply posted during the closure must stay in the discussion and caches.
	comment_request := app.begin_add_comment() or { panic('Comment did not start.') }
	app.apply_comment_result(CommentResult{ request: comment_request, comment: IssueComment{ id: 'new', body: 'Unsent draft' } })
	closed := decode_closed_issue(closed_issue_response, request.issue) or { panic(err) }
	result := CloseIssueResult{ request: request, issue: closed }
	assert app.apply_close_issue_result(result)
	assert !app.close_loading && !app.can_close_issue()
	assert app.detail.issue.state == 'CLOSED' && app.detail.issue.state_reason == 'COMPLETED'
	assert app.detail.issue.body == 'Description' && app.detail.comments.len == 2
	assert app.detail.issue.comments.total == 2
	assert app.detail_cache[42].detail.issue.state == 'CLOSED'
	assert app.detail_cache[42].detail.comments.len == 2
	assert app.issues.len == 0 && 42 !in app.selected
	assert app.open_count == 3 && app.closed_count == 101
	assert app.list_cache['issues_OPEN'].issues.len == 0
	assert app.list_cache['issues_OPEN'].has_next && app.list_cache['issues_OPEN'].cursor == 'next'
	assert app.list_cache['issues_CLOSED'].issues[0].state == 'CLOSED'
	assert app.list_cache['issues_CLOSED'].issues[0].comments.total == 2
	assert cancelled(old_list.cancel) && cancelled(old_detail.cancel)
	app.apply_result(FetchResult{ request: old_list, page: IssuePage{ issues: [request.issue] } })
	app.apply_detail_result(DetailResult{ request: old_detail, detail: IssueDetail{ issue: request.issue } })
	assert app.issues.len == 0 && app.detail.issue.state == 'CLOSED'
	assert !app.apply_close_issue_result(result)
	assert app.open_count == 3 && app.closed_count == 101
	app.close_issue()
	app.change_state('CLOSED')
	assert app.issues.len == 1 && app.issues[0].state == 'CLOSED'
	app.open_issue(42)
	assert app.detail.issue.state == 'CLOSED'
}

fn test_close_failure_allows_retry_and_navigation_preserves_the_outcome() {
	mut app := close_example_app()
	request := app.begin_close_issue() or { panic('Closing did not start.') }
	assert !app.apply_close_issue_result(CloseIssueResult{ request: request, error: 'Permission denied' })
	assert app.can_close_issue() && app.detail.issue.state == 'OPEN'
	assert app.close_errors[42] == 'Permission denied'
	assert app.open_count == 4 && app.closed_count == 100
	retry := app.begin_close_issue() or { panic('Retry did not start.') }
	assert 42 !in app.close_errors
	assert !app.apply_close_issue_result(CloseIssueResult{ request: request, error: 'Old error' })
	assert app.close_loading
	app.change_kind(.prs)
	app.issues = [Issue{ kind: .prs, number: 42, title: 'Unrelated PR', state: 'OPEN' }]
	app.open_count = 9
	app.closed_count = 20
	app.open_issue(42)
	closed := decode_closed_issue(closed_issue_response, retry.issue) or { panic(err) }
	assert app.apply_close_issue_result(CloseIssueResult{ request: retry, issue: closed })
	assert app.detail.issue.kind == .prs && app.detail.issue.state == 'OPEN'
	assert app.issues[0].state == 'OPEN' && app.open_count == 9 && app.closed_count == 20
	app.change_kind(.issues)
	assert app.issues.len == 0 && app.open_count == 3 && app.closed_count == 101
	app.open_issue(42)
	assert app.detail.issue.state == 'CLOSED'
}

fn test_close_issue_button_loading_failure_and_closed_states() {
	mut app := close_example_app()
	for width in [800.0, 1440.0] {
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
	}
	mut layout := detail_layout(&app, ui2.rect(0, 0, 800, 860))
	button := layout.content.children.filter(it.id == 'close_issue')[0]
	assert button.enabled && button.text == 'Close issue'
	assert button.accessibility_label == 'Close issue #42'
	request := app.begin_close_issue() or { panic('Closing did not start.') }
	layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
	closing := layout.content.children.filter(it.id == 'close_issue')[0]
	assert closing.text == 'Closing…' && !closing.enabled
	assert !render_detail(&app, ui2.rect(0, 0, 800, 860)).children.filter(it.id == 'refresh')[0].enabled
	app.apply_close_issue_result(CloseIssueResult{ request: request, error: 'Permission denied' })
	layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
	assert layout.content.children.any(it.id == 'close_issue_error')
	assert layout.content.children.filter(it.id == 'close_issue')[0].enabled
	ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, 800, 860))) or { panic(err) }
	retry := app.begin_close_issue() or { panic('Retry did not start.') }
	closed := decode_closed_issue(closed_issue_response, retry.issue) or { panic(err) }
	app.apply_close_issue_result(CloseIssueResult{ request: retry, issue: closed })
	layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
	assert !layout.content.children.any(it.id in ['close_issue', 'close_issue_error'])
	app.detail = IssueDetail{ issue: Issue{ ...request.issue, kind: .prs } }
	app.kind = .prs
	layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
	assert !layout.content.children.any(it.id == 'close_issue')
}

fn test_close_worker_uses_gh_and_persists_success_only() {
	$if windows {
		return
	}
	root := os.join_path(os.temp_dir(), 'ghgui-close-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(os.join_path(root, 'bin')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut previous := map[string]string{}
	for name in ['PATH', 'GHGUI_DB_PATH', 'GHGUI_CACHE_DIR', 'GHGUI_NO_CACHE', 'FAKE_CLOSE_ROOT'] {
		previous[name] = os.getenv(name)
	}
	defer {
		for name, value in previous { os.setenv(name, value, true) }
	}
	os.setenv('PATH', '${os.join_path(root, 'bin')}:${previous['PATH']}', true)
	os.setenv('GHGUI_DB_PATH', os.join_path(root, 'issues.sqlite3'), true)
	os.setenv('GHGUI_CACHE_DIR', os.join_path(root, 'legacy'), true)
	os.setenv('GHGUI_NO_CACHE', '0', true)
	os.setenv('FAKE_CLOSE_ROOT', root, true)
	script := r'#!/bin/sh
set -eu
printf "%s\n" "$@" > "$FAKE_CLOSE_ROOT/args"
cat "$FAKE_CLOSE_ROOT/response"
if [ -f "$FAKE_CLOSE_ROOT/fail" ]; then
  printf "gh: Forbidden (HTTP 403)\n" >&2
  exit 1
fi
'
	os.write_file(os.join_path(root, 'bin', 'gh'), script) or { panic(err) }
	os.chmod(os.join_path(root, 'bin', 'gh'), 0o700) or { panic(err) }
	mut app := close_example_app()
	issue := app.detail.issue
	list_request := FetchRequest{ repo: app.repo, state: 'OPEN' }
	store_issue_page(list_request, IssuePage{ issues: [issue], open_count: 4, closed_count: 100 }, true) or { panic(err) }
	store_issue_body(DetailRequest{ repo: app.repo, number: 42 }, issue) or { panic(err) }
	os.write_file(os.join_path(root, 'response'), '{"message":"Cannot close issue"}') or { panic(err) }
	request := app.begin_close_issue() or { panic('Closing did not start.') }
	for process_failure in [false, true] {
		if process_failure { os.write_file(os.join_path(root, 'fail'), '') or { panic(err) } }
		worker := spawn close_issue_in_background(request, app.close_results)
		worker.wait()
		failed := <-app.close_results
		assert failed.error.contains(if process_failure { 'HTTP 403' } else { 'Cannot close issue' })
		assert (read_issue_cache(list_request) or { panic('Missing stored issue.') }).issues[0].state == 'OPEN'
	}
	os.rm(os.join_path(root, 'fail')) or { panic(err) }
	os.write_file(os.join_path(root, 'response'), closed_issue_response) or { panic(err) }
	worker := spawn close_issue_in_background(request, app.close_results)
	app.close_issue()
	worker.wait()
	result := <-app.close_results
	assert result.error == '' && result.storage_error == '' && result.issue.state == 'CLOSED'
	assert app.apply_close_issue_result(result)
	args := os.read_file(os.join_path(root, 'args')) or { panic(err) }
	assert args.contains('PATCH\nrepos/org/repo/issues/42\n')
	assert args.contains('state=closed\n') && args.contains('state_reason=completed\n')
	store_closed_item(app.repo, result.issue) or { panic(err) }
	// A stale OPEN read from the same second must not undo the persisted closure.
	store_issue_page(list_request, IssuePage{
		issues:       [Issue{ ...issue, updated_at: result.issue.updated_at }]
		open_count:   3
		closed_count: 101
	}, true) or { panic(err) }
	open := read_issue_cache(list_request) or { panic('Missing stored counts.') }
	assert open.issues.len == 0 && open.open_count == 3 && open.closed_count == 101
	closed := read_issue_cache(FetchRequest{ ...list_request, state: 'CLOSED' }) or { panic('Missing closed issue.') }
	assert closed.issues.len == 1 && closed.issues[0].state_reason == 'COMPLETED'
	assert (read_issue_body(DetailRequest{ repo: app.repo, number: 42 }) or { panic('Missing body.') }).body == 'Description'
	// Issues can still be reopened on GitHub; a later timestamp is authoritative.
	store_issue_page(list_request, IssuePage{
		issues:       [Issue{ ...issue, updated_at: '2026-10-04T10:00:01Z' }]
		open_count:   4
		closed_count: 100
	}, true) or { panic(err) }
	assert (read_issue_cache(list_request) or { panic('Missing reopened issue.') }).issues[0].state == 'OPEN'
}
