module main

import os
import time
import ui2

fn ready_example_app() App {
	issue := Issue{
		kind:       .prs
		is_draft:   true
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

fn test_mark_ready_requires_a_loaded_open_draft_and_prevents_duplicate_writes() {
	mut app := ready_example_app()
	assert app.can_mark_ready() && !app.can_squash_merge()
	valid := app.detail.issue
	for issue in [Issue{ ...valid, kind: .issues }, Issue{ ...valid, state: 'CLOSED' },
		Issue{ ...valid, state: 'MERGED' }, Issue{ ...valid, state: '' },
		Issue{ ...valid, is_draft: false }, Issue{ ...valid, number: 0 }] {
		app.detail = IssueDetail{ issue: issue }
		assert app.begin_mark_ready() == none
		mark_ready_args(ReadyRequest{ repo: app.repo, issue: issue }) or { continue }
		assert false, 'Invalid pull request should never reach GitHub.'
	}
	app.detail = IssueDetail{ issue: valid }
	app.detail_loaded = false
	assert app.begin_mark_ready() == none
	app.detail_loaded = true
	app.detail_body_loading = true
	assert app.begin_mark_ready() == none
	app.detail_body_loading = false
	app.merge_loading = true
	assert app.begin_mark_ready() == none
	app.merge_loading = false
	app.kind = .issues
	assert app.begin_mark_ready() == none
	app.kind = .prs
	request := app.begin_mark_ready() or { panic('Marking ready did not start.') }
	assert app.marking_current_pr_ready() && app.begin_mark_ready() == none
	assert (mark_ready_args(request) or { panic(err) }) == ['pr', 'ready', '42', '--repo',
		'github.com/org/repo']
	mark_ready_args(ReadyRequest{ repo: Repository{ owner: '..', name: 'repo' }, issue: valid }) or { return }
	assert false, 'Invalid repository should never reach GitHub.'
}

fn test_mark_ready_success_preserves_discussion_counts_and_pagination_and_rejects_old_reads() {
	mut app := ready_example_app()
	app.list_cache['prs_OPEN'] = IssuePage{ issues: app.issues, open_count: 4, closed_count: 100, has_next: true, cursor: 'next' }
	old_list := app.begin_fetch(false)
	old_detail := app.begin_detail_fetch(true)
	app.toggle_selection(42)
	request := app.begin_mark_ready() or { panic('Marking ready did not start.') }
	app.set_comment_draft('New reply')
	comment_request := app.begin_add_comment() or { panic('Comment did not start.') }
	app.apply_comment_result(CommentResult{ request: comment_request, comment: IssueComment{ id: 'new', body: 'New reply' } })
	ready := Issue{ ...request.issue, is_draft: false, updated_at: '2026-10-04T10:00:00Z' }
	result := ReadyResult{ request: request, issue: ready }
	assert app.apply_ready_result(result)
	assert !app.ready_loading && !app.can_mark_ready() && app.can_squash_merge()
	assert app.detail.issue.status() == 'Open' && !app.detail.issue.is_draft
	assert app.detail.issue.body == 'Description' && app.detail.comments.len == 2
	assert app.detail.issue.comments.total == 2
	assert !app.detail_cache[42].detail.issue.is_draft && app.detail_cache[42].detail.comments.len == 2
	assert app.issues.len == 1 && !app.issues[0].is_draft && app.selected[42]
	assert app.open_count == 4 && app.closed_count == 100
	page := app.list_cache['prs_OPEN']
	assert !page.issues[0].is_draft && page.open_count == 4 && page.closed_count == 100
	assert page.has_next && page.cursor == 'next'
	assert cancelled(old_list.cancel) && cancelled(old_detail.cancel)
	app.apply_result(FetchResult{ request: old_list, page: IssuePage{ issues: [request.issue] } })
	app.apply_detail_result(DetailResult{ request: old_detail, detail: IssueDetail{ issue: request.issue } })
	assert !app.issues[0].is_draft && !app.detail.issue.is_draft
	assert !app.apply_ready_result(result)
	app.close_issue()
	app.open_issue(42)
	assert !app.detail.issue.is_draft
}

fn test_mark_ready_errors_retry_navigation_and_repository_switch() {
	mut app := ready_example_app()
	request := app.begin_mark_ready() or { panic('Marking ready did not start.') }
	assert !app.apply_ready_result(ReadyResult{ request: request, error: 'Permission denied' })
	assert app.can_mark_ready() && app.detail.issue.is_draft
	assert app.ready_errors[42] == 'Permission denied'
	retry := app.begin_mark_ready() or { panic('Retry did not start.') }
	assert 42 !in app.ready_errors
	assert !app.apply_ready_result(ReadyResult{ request: request, error: 'Old error' })
	assert app.ready_loading
	app.change_kind(.issues)
	assert app.apply_ready_result(ReadyResult{ request: retry, issue: Issue{ ...retry.issue, is_draft: false } })
	assert app.kind == .issues && app.open_count == 0 && app.issues.len == 0
	app.change_kind(.prs)
	assert !app.issues[0].is_draft && app.open_count == 4 && app.closed_count == 100
	app.open_issue(42)
	assert !app.detail.issue.is_draft
	mut other := ready_example_app()
	old_repo := other.begin_mark_ready() or { panic('Marking ready did not start.') }
	other.ready_errors[42] = 'Old repository error'
	assert other.change_repository(Repository{ owner: 'other', name: 'repo' })
	assert !other.ready_loading && other.ready_errors.len == 0
	assert !other.apply_ready_result(ReadyResult{ request: old_repo, issue: Issue{ ...old_repo.issue, is_draft: false } })
	assert other.issues.len == 0 && other.detail_cache.len == 0
}

fn test_ready_button_progress_errors_and_visibility() {
	mut app := ready_example_app()
	for width in [800.0, 1440.0] {
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
	}
	mut layout := detail_layout(&app, ui2.rect(0, 0, 800, 860))
	button := layout.content.children.filter(it.id == 'mark_ready')[0]
	assert button.enabled && button.text == 'Ready for review'
	assert button.accessibility_label == 'Mark pull request #42 ready for review'
	request := app.begin_mark_ready() or { panic('Marking ready did not start.') }
	layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
	progress := layout.content.children.filter(it.id == 'mark_ready')[0]
	assert !progress.enabled && progress.text == 'Marking ready…'
	assert !render_detail(&app, ui2.rect(0, 0, 800, 860)).children.filter(it.id == 'refresh')[0].enabled
	app.apply_ready_result(ReadyResult{ request: request, error: 'Permission denied' })
	layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
	assert layout.content.children.any(it.id == 'ready_error')
	assert layout.content.children.filter(it.id == 'mark_ready')[0].enabled
	ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, 800, 860))) or { panic(err) }
	retry := app.begin_mark_ready() or { panic('Retry did not start.') }
	app.apply_ready_result(ReadyResult{ request: retry, issue: Issue{ ...retry.issue, is_draft: false } })
	layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
	assert !layout.content.children.any(it.id in ['mark_ready', 'ready_error'])
	assert layout.content.children.filter(it.id == 'squash_merge')[0].enabled
	for state in ['CLOSED', 'MERGED'] {
		app.detail = IssueDetail{ issue: Issue{ ...request.issue, state: state } }
		assert !detail_layout(&app, ui2.rect(0, 0, 800, 860)).content.children.any(it.id == 'mark_ready')
	}
	app.kind = .issues
	app.detail = IssueDetail{ issue: Issue{ ...request.issue, kind: .issues } }
	assert !detail_layout(&app, ui2.rect(0, 0, 800, 860)).content.children.any(it.id == 'mark_ready')
}

fn test_ready_worker_uses_gh_and_persists_success_without_reverting_to_stale_drafts() {
	$if windows {
		return
	}
	root := os.join_path(os.temp_dir(), 'ghgui-ready-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(os.join_path(root, 'bin')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut previous := map[string]string{}
	for name in ['PATH', 'GHGUI_DB_PATH', 'GHGUI_NO_CACHE', 'FAKE_READY_ROOT'] {
		previous[name] = os.getenv(name)
	}
	defer { for name, value in previous { os.setenv(name, value, true) }
	 }
	os.setenv('PATH', '${os.join_path(root, 'bin')}:${previous['PATH']}', true)
	os.setenv('GHGUI_DB_PATH', os.join_path(root, 'issues.sqlite3'), true)
	os.setenv('GHGUI_NO_CACHE', '0', true)
	os.setenv('FAKE_READY_ROOT', root, true)
	script := r'#!/bin/sh
set -eu
printf "%s\n" "$@" > "$FAKE_READY_ROOT/args"
if [ -f "$FAKE_READY_ROOT/fail" ]; then
  printf "gh: Permission denied\n" >&2
  exit 1
fi
'
	os.write_file(os.join_path(root, 'bin', 'gh'), script) or { panic(err) }
	os.chmod(os.join_path(root, 'bin', 'gh'), 0o700) or { panic(err) }
	mut app := ready_example_app()
	pr := app.detail.issue
	list_request := FetchRequest{ kind: .prs, repo: app.repo, state: 'OPEN' }
	store_issue_page(list_request, IssuePage{ issues: [pr], open_count: 4, closed_count: 100 }, true) or { panic(err) }
	store_issue_body(DetailRequest{ kind: .prs, repo: app.repo, number: 42 }, pr) or { panic(err) }
	request := app.begin_mark_ready() or { panic('Marking ready did not start.') }
	os.write_file(os.join_path(root, 'fail'), '') or { panic(err) }
	failed_worker := spawn mark_ready_in_background(request, app.ready_results)
	failed_worker.wait()
	failed := <-app.ready_results
	assert failed.error.contains('Permission denied')
	assert (read_issue_cache(list_request) or { panic('Missing stored PR.') }).issues[0].is_draft
	os.rm(os.join_path(root, 'fail')) or { panic(err) }
	worker := spawn mark_ready_in_background(request, app.ready_results)
	app.close_issue()
	worker.wait()
	result := <-app.ready_results
	assert result.error == '' && result.storage_error == '' && !result.issue.is_draft
	assert app.apply_ready_result(result)
	assert (os.read_file(os.join_path(root, 'args')) or { panic(err) }) == 'pr\nready\n42\n--repo\ngithub.com/org/repo\n'
	for timestamp in [pr.updated_at, result.issue.updated_at] {
		store_issue_page(list_request, IssuePage{ issues: [Issue{ ...pr, updated_at: timestamp }], open_count: 4, closed_count: 100 }, true) or { panic(err) }
		assert !(read_issue_cache(list_request) or { panic('Missing ready PR.') }).issues[0].is_draft
	}
	page := read_issue_cache(list_request) or { panic('Missing ready PR.') }
	assert page.open_count == 4 && page.closed_count == 100
	assert (read_issue_body(DetailRequest{ kind: .prs, repo: app.repo, number: 42 }) or { panic('Missing description.') }).body == 'Description'
	// A later conversion back to draft on GitHub remains authoritative.
	store_issue_page(list_request, IssuePage{ issues: [Issue{ ...pr, updated_at: '2099-01-01T00:00:00Z' }], open_count: 4, closed_count: 100 }, true) or { panic(err) }
	assert (read_issue_cache(list_request) or { panic('Missing later draft.') }).issues[0].is_draft
}
