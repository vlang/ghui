module main

import os
import time
import ui2

const closed_pr_response = r'{"number":42,"state":"closed","merged":false,"merged_at":null,"updated_at":"2026-10-04T10:00:00Z"}'

fn close_pr_example_app() App {
	issue := Issue{
		kind:       .prs
		number:     42
		title:      'Add a feature'
		state:      'OPEN'
		head_oid:   'abc123'
		body:       'Description'
		created_at: '2026-10-01T00:00:00Z'
		updated_at: '2026-10-02T00:00:00Z'
		comments:   Count{ total: 1 }
	}
	mut app := App{
		repo:         Repository{ owner: 'org', name: 'repo' }
		kind:         .prs
		issues:       [issue]
		open_count:   4
		closed_count: 100
		loaded_state: 'OPEN'
	}
	app.open_issue(42)
	request := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{
		request: request
		detail:  IssueDetail{ issue: issue, comments: [IssueComment{ id: 'first', body: 'First reply' }] }
	})
	return app
}

fn test_close_pr_requires_a_loaded_open_pr_and_blocks_conflicting_writes() {
	mut app := close_pr_example_app()
	assert app.can_close_pr()
	valid := app.detail.issue
	for issue in [Issue{ ...valid, kind: .issues }, Issue{ ...valid, state: 'CLOSED' },
		Issue{ ...valid, state: 'MERGED' }, Issue{ ...valid, state: '' }, Issue{ ...valid, number: 0 }] {
		app.detail = IssueDetail{ issue: issue }
		assert app.begin_close_pr() == none
		close_pr_args(ClosePrRequest{ repo: app.repo, issue: issue }) or { continue }
		assert false, 'Invalid pull request should never reach GitHub.'
	}
	app.detail = IssueDetail{ issue: valid }
	app.detail_loaded = false
	assert app.begin_close_pr() == none
	app.detail_loaded = true
	app.detail_body_loading = true
	assert app.begin_close_pr() == none
	app.detail_body_loading = false
	app.merge_loading = true
	assert app.begin_close_pr() == none
	app.merge_loading = false
	app.ready_loading = true
	assert app.begin_close_pr() == none
	app.ready_loading = false
	app.kind = .issues
	assert app.begin_close_pr() == none
	app.kind = .prs
	app.active_issue = 7
	assert app.begin_close_pr() == none
	app.active_issue = 42
	request := app.begin_close_pr() or { panic('Closing did not start.') }
	assert app.closing_current_pr() && app.begin_close_pr() == none
	assert app.begin_squash_merge() == none
	app.detail = IssueDetail{ issue: Issue{ ...valid, is_draft: true, head_oid: '' } }
	assert app.begin_mark_ready() == none
	app.close_pr_loading = false
	assert app.can_close_pr(), 'Draft PRs can be closed without a head commit.'
	assert (close_pr_args(request) or { panic(err) }) == ['api', '--hostname', 'github.com',
		'--method', 'PATCH', 'repos/org/repo/pulls/42', '-f', 'state=closed']
	close_pr_args(ClosePrRequest{ repo: Repository{ owner: '..', name: 'repo' }, issue: valid }) or { return }
	assert false, 'Invalid repository should never reach GitHub.'
}

fn test_close_pr_response_requires_confirmation_of_unmerged_closure() {
	app := close_pr_example_app()
	issue := decode_closed_pr(closed_pr_response, app.detail.issue) or { panic(err) }
	assert issue.state == 'CLOSED' && issue.status() == 'Closed'
	assert issue.updated_at == '2026-10-04T10:00:00Z'
	assert issue.kind == .prs && issue.title == 'Add a feature' && issue.body == 'Description'
	for response in ['{"number":42,"state":"open","merged":false}',
		'{"number":7,"state":"closed","merged":false}', '{"number":42,"state":"closed"}',
		'{"number":42,"state":"closed","merged":null}', '{"number":42,"state":"closed","merged":true}',
		'{"number":42,"state":"closed","merged":false,"merged_at":"2026-10-04T10:00:00Z"}',
		'{"message":"Permission denied"}', '{}', 'invalid'] {
		decode_closed_pr(response, app.detail.issue) or { continue }
		assert false, response
	}
	decode_closed_pr('{"message":"Permission denied"}', app.detail.issue) or {
		assert err.msg() == 'Permission denied'
	}
}

fn test_close_pr_success_preserves_discussion_and_updates_lists_and_counts() {
	mut app := close_pr_example_app()
	app.list_cache['prs_OPEN'] = IssuePage{ issues: app.issues, open_count: 4, closed_count: 100, has_next: true, cursor: 'next' }
	app.list_cache['prs_CLOSED'] = IssuePage{ open_count: 4, closed_count: 100 }
	old_list := app.begin_fetch(false)
	old_detail := app.begin_detail_fetch(true)
	app.toggle_selection(42)
	request := app.begin_close_pr() or { panic('Closing did not start.') }
	app.set_comment_draft('New reply')
	comment_request := app.begin_add_comment() or { panic('Comment did not start.') }
	app.apply_comment_result(CommentResult{ request: comment_request, comment: IssueComment{ id: 'new', body: 'New reply' } })
	closed := decode_closed_pr(closed_pr_response, request.issue) or { panic(err) }
	result := ClosePrResult{ request: request, issue: closed }
	assert app.apply_close_pr_result(result)
	assert !app.close_pr_loading && !app.can_close_pr() && !app.can_squash_merge()
	assert app.detail.issue.state == 'CLOSED' && app.detail.issue.body == 'Description'
	assert app.detail.comments.len == 2 && app.detail.issue.comments.total == 2
	assert app.detail_cache[42].detail.issue.state == 'CLOSED'
	assert app.detail_cache[42].detail.comments.len == 2
	assert app.issues.len == 0 && 42 !in app.selected
	assert app.open_count == 3 && app.closed_count == 101
	assert app.list_cache['prs_OPEN'].issues.len == 0
	assert app.list_cache['prs_OPEN'].has_next && app.list_cache['prs_OPEN'].cursor == 'next'
	assert app.list_cache['prs_CLOSED'].issues[0].state == 'CLOSED'
	assert app.list_cache['prs_CLOSED'].issues[0].comments.total == 2
	assert cancelled(old_list.cancel) && cancelled(old_detail.cancel)
	app.apply_result(FetchResult{ request: old_list, page: IssuePage{ issues: [request.issue] } })
	app.apply_detail_result(DetailResult{ request: old_detail, detail: IssueDetail{ issue: request.issue } })
	assert app.issues.len == 0 && app.detail.issue.state == 'CLOSED'
	assert !app.apply_close_pr_result(result)
	assert app.open_count == 3 && app.closed_count == 101
	app.close_issue()
	app.change_state('CLOSED')
	assert app.issues.len == 1 && app.issues[0].state == 'CLOSED'
	app.open_issue(42)
	assert app.detail.issue.state == 'CLOSED'
}

fn test_close_pr_retry_navigation_and_repository_switch() {
	mut app := close_pr_example_app()
	request := app.begin_close_pr() or { panic('Closing did not start.') }
	assert !app.apply_close_pr_result(ClosePrResult{ request: request, error: 'Permission denied' })
	assert app.can_close_pr() && app.detail.issue.state == 'OPEN'
	assert app.close_pr_errors[42] == 'Permission denied'
	assert app.open_count == 4 && app.closed_count == 100
	retry := app.begin_close_pr() or { panic('Retry did not start.') }
	assert 42 !in app.close_pr_errors
	assert !app.apply_close_pr_result(ClosePrResult{ request: request, error: 'Old error' })
	assert app.close_pr_loading
	app.change_kind(.issues)
	app.issues = [Issue{ number: 42, title: 'Unrelated issue', state: 'OPEN' }]
	app.open_count = 9
	app.closed_count = 20
	app.open_issue(42)
	closed := decode_closed_pr(closed_pr_response, retry.issue) or { panic(err) }
	assert app.apply_close_pr_result(ClosePrResult{ request: retry, issue: closed })
	assert app.detail.issue.kind == .issues && app.detail.issue.state == 'OPEN'
	assert app.issues[0].state == 'OPEN' && app.open_count == 9 && app.closed_count == 20
	app.change_kind(.prs)
	assert app.issues.len == 0 && app.open_count == 3 && app.closed_count == 101
	app.open_issue(42)
	assert app.detail.issue.state == 'CLOSED'
	mut other := close_pr_example_app()
	old_repo := other.begin_close_pr() or { panic('Closing did not start.') }
	other.close_pr_errors[42] = 'Old repository error'
	assert other.change_repository(Repository{ owner: 'other', name: 'repo' })
	assert !other.close_pr_loading && other.close_pr_errors.len == 0
	assert !other.apply_close_pr_result(ClosePrResult{ request: old_repo, issue: closed })
	assert other.issues.len == 0 && other.detail_cache.len == 0
}

fn test_close_pr_button_progress_errors_and_visibility() {
	for draft in [false, true] {
		mut app := close_pr_example_app()
		app.detail = IssueDetail{ ...app.detail, issue: Issue{ ...app.detail.issue, is_draft: draft } }
		for width in [800.0, 1440.0] {
			ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
		}
		mut layout := detail_layout(&app, ui2.rect(0, 0, 800, 860))
		button := layout.content.children.filter(it.id == 'close_pr')[0]
		merge := layout.content.children.filter(it.id == 'squash_merge')[0]
		assert button.enabled && button.text == 'Close PR'
		assert button.accessibility_label == 'Close pull request #42 without merging'
		assert button.frame.x > merge.frame.x + merge.frame.width
		assert button.frame.x + button.frame.width <= layout.content.frame.width
		request := app.begin_close_pr() or { panic('Closing did not start.') }
		layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
		closing := layout.content.children.filter(it.id == 'close_pr')[0]
		assert closing.text == 'Closing…' && !closing.enabled
		assert !layout.content.children.filter(it.id == 'squash_merge')[0].enabled
		if draft { assert !layout.content.children.filter(it.id == 'mark_ready')[0].enabled }
		assert !render_detail(&app, ui2.rect(0, 0, 800, 860)).children.filter(it.id == 'refresh')[0].enabled
		app.apply_close_pr_result(ClosePrResult{ request: request, error: 'Permission denied' })
		layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
		assert layout.content.children.any(it.id == 'close_pr_error')
		assert layout.content.children.filter(it.id == 'close_pr')[0].enabled
		for state in ['CLOSED', 'MERGED'] {
			app.detail = IssueDetail{ ...app.detail, issue: Issue{ ...app.detail.issue, state: state } }
			layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
			assert !layout.content.children.any(it.id == 'close_pr')
		}
		app.detail = IssueDetail{ issue: Issue{ number: 42, state: 'OPEN' } }
		app.kind = .issues
		layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
		assert !layout.content.children.any(it.id in ['close_pr', 'close_pr_error'])
	}
}

fn test_close_pr_worker_persists_only_confirmed_unmerged_closure() {
	$if windows { return }
	root := os.join_path(os.temp_dir(), 'ghgui-close-pr-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(os.join_path(root, 'bin')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut previous := map[string]string{}
	for name in ['PATH', 'GHGUI_DB_PATH', 'GHGUI_CACHE_DIR', 'GHGUI_NO_CACHE', 'FAKE_CLOSE_PR_ROOT'] {
		previous[name] = os.getenv(name)
	}
	defer { for name, value in previous { os.setenv(name, value, true) } }
	os.setenv('PATH', '${os.join_path(root, 'bin')}:${previous['PATH']}', true)
	os.setenv('GHGUI_DB_PATH', os.join_path(root, 'issues.sqlite3'), true)
	os.setenv('GHGUI_CACHE_DIR', os.join_path(root, 'legacy'), true)
	os.setenv('GHGUI_NO_CACHE', '0', true)
	os.setenv('FAKE_CLOSE_PR_ROOT', root, true)
	script := r'#!/bin/sh
set -eu
printf "%s\n" "$@" > "$FAKE_CLOSE_PR_ROOT/args"
cat "$FAKE_CLOSE_PR_ROOT/response"
if [ -f "$FAKE_CLOSE_PR_ROOT/fail" ]; then
  printf "gh: Forbidden (HTTP 403)\n" >&2
  exit 1
fi
'
	os.write_file(os.join_path(root, 'bin', 'gh'), script) or { panic(err) }
	os.chmod(os.join_path(root, 'bin', 'gh'), 0o700) or { panic(err) }
	mut app := close_pr_example_app()
	issue := app.detail.issue
	list_request := FetchRequest{ kind: .prs, repo: app.repo, state: 'OPEN' }
	store_issue_page(list_request, IssuePage{ issues: [issue], open_count: 4, closed_count: 100 }, true) or { panic(err) }
	store_issue_body(DetailRequest{ kind: .prs, repo: app.repo, number: 42 }, issue) or { panic(err) }
	request := app.begin_close_pr() or { panic('Closing did not start.') }
	for response in ['{"message":"Cannot close PR"}', '{"number":42,"state":"closed","merged":true}'] {
		os.write_file(os.join_path(root, 'response'), response) or { panic(err) }
		worker := spawn close_pr_in_background(request, app.close_pr_results)
		worker.wait()
		failed := <-app.close_pr_results
		assert failed.error != ''
		assert (read_issue_cache(list_request) or { panic('Missing stored PR.') }).issues[0].state == 'OPEN'
	}
	os.write_file(os.join_path(root, 'fail'), '') or { panic(err) }
	worker_failure := spawn close_pr_in_background(request, app.close_pr_results)
	worker_failure.wait()
	assert (<-app.close_pr_results).error.contains('HTTP 403')
	os.rm(os.join_path(root, 'fail')) or { panic(err) }
	os.write_file(os.join_path(root, 'response'), closed_pr_response) or { panic(err) }
	worker := spawn close_pr_in_background(request, app.close_pr_results)
	app.close_issue()
	worker.wait()
	result := <-app.close_pr_results
	assert result.error == '' && result.storage_error == '' && result.issue.state == 'CLOSED'
	assert app.apply_close_pr_result(result)
	args := os.read_file(os.join_path(root, 'args')) or { panic(err) }
	assert args.contains('PATCH\nrepos/org/repo/pulls/42\n') && args.contains('state=closed\n')
	assert !args.contains('merge') && !args.contains('state_reason')
	store_closed_item(app.repo, result.issue) or { panic(err) }
	// A stale OPEN read from the same second must not undo the persisted closure.
	store_issue_page(list_request, IssuePage{ issues: [Issue{ ...issue, updated_at: result.issue.updated_at }], open_count: 3, closed_count: 101 }, true) or { panic(err) }
	open := read_issue_cache(list_request) or { panic('Missing stored counts.') }
	assert open.issues.len == 0 && open.open_count == 3 && open.closed_count == 101
	closed := read_issue_cache(FetchRequest{ ...list_request, state: 'CLOSED' }) or { panic('Missing closed PR.') }
	assert closed.issues.len == 1 && closed.issues[0].state == 'CLOSED'
	assert (read_issue_body(DetailRequest{ kind: .prs, repo: app.repo, number: 42 }) or { panic('Missing body.') }).body == 'Description'
	// A later reopen on GitHub remains authoritative.
	store_issue_page(list_request, IssuePage{ issues: [Issue{ ...issue, updated_at: '2026-10-04T10:00:01Z' }], open_count: 4, closed_count: 100 }, true) or { panic(err) }
	assert (read_issue_cache(list_request) or { panic('Missing reopened PR.') }).issues[0].state == 'OPEN'
}
