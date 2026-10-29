module main

import os
import time
import ui2

const added_comment_response = r'{"id":4242,"node_id":"IC_new","body":"Thanks, **fixed**.","created_at":"2026-10-04T10:00:00Z","user":{"login":"alice"}}'

fn comment_example_app(kind ItemKind) App {
	issue := Issue{
		kind:     kind
		number:   42
		title:    'Add a feature'
		state:    'OPEN'
		body:     'Description'
		comments: Count{ total: 1 }
	}
	mut app := App{
		repo:         Repository{ owner: 'org', name: 'repo' }
		kind:         kind
		issues:       [issue]
		loaded_state: 'OPEN'
	}
	app.open_issue(42)
	request := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{ request: request, detail: IssueDetail{ issue: issue, comments: [IssueComment{ id: 'IC_first', body: 'First reply' }] } })
	return app
}

fn added_comment() IssueComment {
	return decode_added_comment(added_comment_response) or { panic(err) }
}

fn comment_form_of(app &App) ui2.Element {
	layout := detail_layout(app, ui2.rect(0, 0, 800, 860))
	return layout.content.children.filter(it.id == 'new_comment')[0]
}

fn test_comments_on_issues_and_prs_use_the_issue_comments_endpoint() {
	repo := Repository{ owner: 'org', name: 'repo' }
	body := '@alice -F looks = good\n\nSecond paragraph'
	for kind in [ItemKind.issues, .prs] {
		args := add_comment_args(CommentRequest{ repo: repo, kind: kind, number: 42, body: body }) or { panic(err) }
		assert 'POST' in args && 'repos/org/repo/issues/42/comments' in args
		assert args[args.len - 2] == '-f' && args.last() == 'body=${body}'
	}
	for request in [CommentRequest{ repo: repo, number: 42, body: ' \n\t' },
		CommentRequest{ repo: repo, body: 'Text' },
		CommentRequest{ repo: Repository{ owner: '..', name: 'repo' }, number: 42, body: 'Text' }] {
		add_comment_args(request) or { continue }
		assert false, 'Invalid comment should never reach GitHub.'
	}
}

fn test_comment_response_requires_the_created_comment() {
	comment := added_comment()
	assert comment.id == 'IC_new' && comment.body == 'Thanks, **fixed**.'
	assert comment.author.login == 'alice' && comment.created_at == '2026-10-04T10:00:00Z'
	for response in ['{"message":"Issue is locked"}', '{}', 'invalid'] {
		decode_added_comment(response) or { continue }
		assert false, response
	}
	decode_added_comment('{"message":"Issue is locked"}') or { assert err.msg() == 'Issue is locked' }
}

fn test_drafts_are_kept_per_item_and_gate_posting() {
	mut app := comment_example_app(.issues)
	assert !app.can_add_comment() && app.begin_add_comment() == none
	assert !app.set_comment_draft('  \n')
	assert !app.can_add_comment()
	assert app.set_comment_draft('Looks good')
	assert !app.set_comment_draft('Looks good to me')
	assert app.can_add_comment()
	app.close_issue()
	app.open_issue(7)
	assert app.comment_draft() == '' && !app.can_add_comment()
	app.close_issue()
	app.open_issue(42)
	assert app.comment_draft() == 'Looks good to me'
	request := app.begin_add_comment() or { panic('Comment did not start.') }
	assert request.number == 42 && request.kind == .issues && request.body == 'Looks good to me'
	assert app.posting_current_comment() && app.begin_add_comment() == none
	assert app.set_comment_draft('')
	assert 42 !in app.comment_drafts
}

fn test_posted_comment_updates_the_discussion_and_counts_and_clears_the_draft() {
	for kind in [ItemKind.issues, .prs] {
		mut app := comment_example_app(kind)
		app.set_comment_draft('Thanks, **fixed**.')
		request := app.begin_add_comment() or { panic('Comment did not start.') }
		result := CommentResult{ request: request, comment: added_comment() }
		app.apply_comment_result(result)
		assert !app.comment_loading && app.comment_draft() == '' && !app.can_add_comment()
		assert app.detail.comments.map(it.id) == ['IC_first', 'IC_new']
		assert app.detail.comments[1].author.login == 'alice'
		assert app.detail.issue.comments.total == 2 && app.issues[0].comments.total == 2
		assert app.detail_cache[42].detail.comments.len == 2
		assert app.detail_cache[42].detail.issue.comments.total == 2
		app.apply_comment_result(result)
		assert app.detail.comments.len == 2 && app.detail.issue.comments.total == 2
	}
}

fn test_comment_errors_keep_the_draft_and_navigation_preserves_the_outcome() {
	mut app := comment_example_app(.issues)
	app.set_comment_draft('Draft')
	request := app.begin_add_comment() or { panic('Comment did not start.') }
	app.apply_comment_result(CommentResult{ request: request, error: 'gh: Not Found (HTTP 404)' })
	assert app.comment_draft() == 'Draft' && app.can_add_comment()
	assert app.comment_errors[42].contains('Not Found')
	assert app.detail.comments.len == 1 && app.detail.issue.comments.total == 1
	retry := app.begin_add_comment() or { panic('Retry did not start.') }
	assert 42 !in app.comment_errors
	app.apply_comment_result(CommentResult{ request: request, error: 'Old error' })
	assert app.comment_loading && 42 !in app.comment_errors
	app.close_issue()
	app.open_issue(7)
	app.set_comment_draft('Other draft')
	assert !app.posting_current_comment() && !app.can_add_comment()
	app.apply_comment_result(CommentResult{ request: retry, comment: added_comment() })
	assert app.detail.comments.len == 0 && app.comment_draft() == 'Other draft'
	assert app.can_add_comment() && app.issues[0].comments.total == 2
	app.close_issue()
	app.open_issue(42)
	assert app.comment_draft() == ''
	assert app.detail.comments.map(it.id) == ['IC_first', 'IC_new']
}

fn test_posted_comment_stays_last_until_a_later_read_returns_the_whole_discussion() {
	mut app := comment_example_app(.issues)
	issue := Issue{ ...app.detail.issue, comments: Count{ total: 3 } }
	first := IssueComment{ id: 'IC_first', body: 'First reply' }
	refresh := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{ request: refresh, detail: IssueDetail{ issue: issue, comments: [first], has_next: true, cursor: 'one' } })
	more := app.begin_detail_fetch(true)
	app.set_comment_draft('Thanks, **fixed**.')
	request := app.begin_add_comment() or { panic('Comment did not start.') }
	app.apply_comment_result(CommentResult{ request: request, comment: added_comment() })
	assert app.detail.comments.map(it.id) == ['IC_first', 'IC_new']
	assert app.detail.issue.comments.total == 4 && app.detail.has_next
	// This page was requested before the comment existed.
	rest := [IssueComment{ id: 'IC_second' }, IssueComment{ id: 'IC_third' }]
	app.apply_detail_result(DetailResult{ request: more, part: .comments, detail: IssueDetail{ issue: issue, comments: rest } })
	assert app.detail.comments.map(it.id) == ['IC_first', 'IC_second', 'IC_third', 'IC_new']
	assert app.detail.issue.comments.total == 4
	first_page := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{ request: first_page, detail: IssueDetail{ issue: issue, comments: [first], has_next: true, cursor: 'one' } })
	assert app.detail.comments.map(it.id) == ['IC_first', 'IC_new']
	mut all := [first]
	all << rest
	all << IssueComment{ id: 'IC_new', body: 'Thanks, **fixed**.' }
	whole := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{ request: whole, detail: IssueDetail{ issue: Issue{ ...issue, comments: Count{ total: 4 } }, comments: all } })
	assert app.detail.comments.map(it.id) == ['IC_first', 'IC_second', 'IC_third', 'IC_new']
	assert app.detail.comments.all(it.posted == 0)
	// A comment deleted on GitHub does not linger here.
	remaining := all[..3].clone()
	app.detail = detail_with_comment(IssueDetail{ ...app.detail, comments: remaining }, IssueComment{ ...added_comment(), posted: app.detail_generation })
	deleted := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{ request: deleted, detail: IssueDetail{ issue: issue, comments: remaining } })
	assert app.detail.comments.map(it.id) == ['IC_first', 'IC_second', 'IC_third']
	assert app.detail.issue.comments.total == 3
}

fn test_comment_form_draft_posting_and_failure_states() {
	mut app := comment_example_app(.prs)
	for width in [800.0, 1440.0] {
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
	}
	mut form := comment_form_of(&app)
	assert form.key == 'new_comment_42'
	assert !form.children.filter(it.id == 'add_comment')[0].enabled
	app.set_comment_draft('Looks good')
	form = comment_form_of(&app)
	area := form.children.filter(it.id == 'new_comment_box')[0].children[0]
	assert area.id == 'new_comment_text' && area.kind == .text_area && area.text == 'Looks good'
	assert area.enabled && !area.readonly && area.emit_change
	assert form.children.filter(it.id == 'add_comment')[0].enabled
	request := app.begin_add_comment() or { panic('Comment did not start.') }
	form = comment_form_of(&app)
	button := form.children.filter(it.id == 'add_comment')[0]
	assert button.text == 'Commenting…' && !button.enabled
	assert !form.children.filter(it.id == 'new_comment_box')[0].children[0].enabled
	height := form.frame.height
	app.apply_comment_result(CommentResult{ request: request, error: 'Permission denied' })
	form = comment_form_of(&app)
	assert form.children.any(it.id == 'new_comment_error') && form.frame.height > height
	assert form.children.filter(it.id == 'add_comment')[0].enabled
	ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, 800, 860))) or { panic(err) }
	layout := detail_layout(&app, ui2.rect(0, 0, 800, 860))
	assert layout.content.frame.height >= form.frame.y + form.frame.height
}

fn test_comment_worker_posts_through_gh_and_reports_failures() {
	$if windows {
		return
	}
	root := os.join_path(os.temp_dir(), 'ghgui-comment-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(os.join_path(root, 'bin')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut previous := map[string]string{}
	for name in ['PATH', 'FAKE_COMMENT_ROOT'] { previous[name] = os.getenv(name) }
	defer {
		for name, value in previous { os.setenv(name, value, true) }
	}
	os.setenv('PATH', '${os.join_path(root, 'bin')}:${previous['PATH']}', true)
	os.setenv('FAKE_COMMENT_ROOT', root, true)
	script := r'#!/bin/sh
set -eu
printf "%s\n" "$@" > "$FAKE_COMMENT_ROOT/args"
cat "$FAKE_COMMENT_ROOT/response"
if [ -f "$FAKE_COMMENT_ROOT/fail" ]; then
  printf "gh: Not Found (HTTP 404)\n" >&2
  exit 1
fi
'
	os.write_file(os.join_path(root, 'bin', 'gh'), script) or { panic(err) }
	os.chmod(os.join_path(root, 'bin', 'gh'), 0o700) or { panic(err) }
	mut app := comment_example_app(.prs)
	app.set_comment_draft('First line\n\n- [ ] "quoted" `code`')
	request := app.begin_add_comment() or { panic('Comment did not start.') }
	os.write_file(os.join_path(root, 'response'), '{"message":"Not Found"}') or { panic(err) }
	for process_failure in [false, true] {
		if process_failure { os.write_file(os.join_path(root, 'fail'), '') or { panic(err) } }
		worker := spawn add_comment_in_background(request, app.comment_results)
		worker.wait()
		failed := <-app.comment_results
		assert failed.error.contains(if process_failure { 'HTTP 404' } else { 'Not Found' })
		assert failed.comment.id == ''
	}
	os.rm(os.join_path(root, 'fail')) or { panic(err) }
	os.write_file(os.join_path(root, 'response'), added_comment_response) or { panic(err) }
	worker := spawn add_comment_in_background(request, app.comment_results)
	app.close_issue()
	worker.wait()
	result := <-app.comment_results
	assert result.error == '' && result.comment.id == 'IC_new'
	args := os.read_file(os.join_path(root, 'args')) or { panic(err) }
	assert args.contains('POST\nrepos/org/repo/issues/42/comments\n')
	assert args.ends_with('-f\nbody=First line\n\n- [ ] "quoted" `code`\n')
	app.apply_comment_result(result)
	assert 42 !in app.comment_drafts && app.issues[0].comments.total == 2
	assert app.detail_cache[42].detail.comments.last().id == 'IC_new'
}
