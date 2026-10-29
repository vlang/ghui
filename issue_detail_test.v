module main

import os
import ui2

const sample_detail_response = '{"data":{"repository":{"issue":{"number":29233,"title":"Compiler regression","body":"## Summary\n\nA regression.\n\n```v\nmut value := 1\n```","state":"OPEN","stateReason":null,"createdAt":"2026-10-01T12:40:22Z","author":{"login":"alice"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"milestone":null,"comments":{"totalCount":3,"pageInfo":{"hasNextPage":true,"endCursor":"next-comments"},"nodes":[{"id":"comment-one","body":"First response","createdAt":"2026-10-01T13:00:00Z","author":{"login":"bob"}},{"id":"comment-two","body":"> A quote\n\nSecond response","createdAt":"2026-10-01T14:00:00Z","author":null}]}}}}}'

fn detail_example_app() App {
	return App{
		repo:   Repository{ owner: 'vlang', name: 'v' }
		issues: [Issue{ number: 1, title: 'Compiler regression', state: 'OPEN' },
			Issue{ number: 2, title: 'Add widgets', state: 'OPEN' }]
	}
}

fn test_decode_description_and_comment_page() {
	detail := decode_detail(sample_detail_response) or { panic(err) }
	assert detail.issue.number == 29233
	assert detail.issue.body.contains('mut value := 1')
	assert detail.issue.comments.total == 3
	assert detail.comments.len == 2
	assert detail.comments[0].id == 'comment-one'
	assert detail.comments[0].author.login == 'bob'
	assert detail.comments[1].body == '> A quote\n\nSecond response'
	assert author_name(detail.comments[1].author) == 'ghost'
	assert detail.has_next
	assert detail.cursor == 'next-comments'
}

fn test_missing_issue_and_detail_api_errors() {
	for source in ['{"data":{"repository":{"issue":null}}}',
		'{"data":null,"errors":[{"message":"Access denied"}]}', 'invalid json'] {
		decode_detail(source) or { continue }
		assert false, source
	}
}

fn test_issue_detail_uses_numeric_argument_and_comment_cursor() {
	args := detail_args(DetailRequest{
		repo:   Repository{ owner: 'vlang', name: 'v' }
		number: 29233
		cursor: 'opaque=cursor=='
	})
	assert 'number=29233' in args
	assert args[args.index('number=29233') - 1] == '-F'
	assert 'cursor=opaque=cursor==' in args
	assert 'query=${issue_detail_query}' in args
}

fn test_back_preserves_the_list_and_discards_pending_details() {
	mut app := detail_example_app()
	app.search = 'Compiler'
	app.list_scroll = 320
	app.toggle_selection(1)
	app.open_issue(1)
	request := app.begin_detail_fetch(false)
	assert app.detail.issue.title == 'Compiler regression'
	app.close_issue()
	app.apply_detail_result(DetailResult{ request: request, detail: IssueDetail{ issue: Issue{ number: 1, title: 'Changed' } } })
	assert app.active_issue == 0
	assert !app.detail_loading
	assert !app.detail_loaded
	assert app.search == 'Compiler'
	assert app.list_scroll == 320
	assert app.selected[1]
	assert app.issues[0].title == 'Compiler regression'
}

fn test_switching_issue_ignores_a_stale_response() {
	mut app := detail_example_app()
	app.open_issue(1)
	old_request := app.begin_detail_fetch(false)
	app.open_issue(2)
	new_request := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{ request: old_request, error: 'Old error' })
	assert app.detail_loading
	assert app.detail_error == ''
	app.apply_detail_result(DetailResult{ request: new_request, detail: IssueDetail{ issue: Issue{ number: 2, title: 'Add widgets', body: 'Details' } } })
	assert !app.detail_loading
	assert app.detail_loaded
	assert app.detail.issue.body == 'Details'
}

fn test_comments_pagination_and_failed_refresh_retain_discussion() {
	mut app := detail_example_app()
	app.open_issue(29233)
	first := app.begin_detail_fetch(false)
	detail := decode_detail(sample_detail_response) or { panic(err) }
	app.apply_detail_result(DetailResult{ request: first, detail: detail })
	more := app.begin_detail_fetch(true)
	assert more.cursor == 'next-comments'
	app.apply_detail_result(DetailResult{
		request: more
		detail:  IssueDetail{
			issue:    detail.issue
			comments: [detail.comments[1], IssueComment{ id: 'comment-three', body: 'Last reply' }]
		}
	})
	assert app.detail.comments.map(it.id) == ['comment-one', 'comment-two', 'comment-three']
	assert !app.detail.has_next
	refresh := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{ request: refresh, error: 'Network unavailable' })
	assert app.detail_loaded
	assert app.detail.comments.len == 3
	assert app.detail.issue.body == detail.issue.body
	assert app.detail_error == 'Network unavailable'
}

fn test_body_is_readable_while_comments_are_still_loading() {
	mut app := detail_example_app()
	app.open_issue(29233)
	request := app.begin_detail_fetch(false)
	detail := decode_detail(sample_detail_response) or { panic(err) }
	app.apply_detail_result(DetailResult{ request: request, part: .body, detail: IssueDetail{ issue: detail.issue } })
	assert app.detail_loaded
	assert !app.detail_body_loading
	assert app.detail_comments_loading
	assert app.detail_loading
	assert app.detail.issue.body == detail.issue.body
	app.apply_detail_result(DetailResult{ request: request, part: .comments, detail: detail, done: false })
	assert app.detail.comments.len == 2
	assert app.detail_loading
	assert app.detail.issue.body == detail.issue.body
	app.apply_detail_result(DetailResult{ request: request, part: .comments, error: 'Comments unavailable' })
	assert !app.detail_loading
	assert app.detail_loaded
	assert app.detail.comments.len == 2
	assert app.detail_error == 'Comments unavailable'
}

fn test_comments_can_arrive_before_body_and_reopen_is_immediate() {
	mut app := detail_example_app()
	app.open_issue(29233)
	request := app.begin_detail_fetch(false)
	detail := decode_detail(sample_detail_response) or { panic(err) }
	app.apply_detail_result(DetailResult{ request: request, part: .comments, detail: detail })
	assert app.detail.comments.len == 2
	assert app.detail_comments_loaded
	assert !app.detail_loaded
	assert app.detail_body_loading
	app.apply_detail_result(DetailResult{ request: request, part: .body, detail: IssueDetail{ issue: detail.issue } })
	assert !app.detail_loading
	assert app.detail.comments.len == 2
	assert app.detail.has_next
	assert app.detail.cursor == 'next-comments'
	app.close_issue()
	assert cancelled(request.cancel)
	app.open_issue(29233)
	assert app.detail_loaded
	assert app.detail_comments_loaded
	assert app.detail.issue.body == detail.issue.body
	assert app.detail.comments.len == 2
}

fn test_split_queries_decode_without_the_other_half() {
	body := decode_detail_part('{"data":{"repository":{"issue":{"number":1,"title":"Title","body":"Description","comments":{"totalCount":8}}}}}', .body) or { panic(err) }
	assert body.issue.body == 'Description'
	assert body.issue.comments.total == 8
	assert body.comments.len == 0
	comments := decode_detail_part('{"data":{"repository":{"issue":{"number":1,"comments":{"totalCount":1,"nodes":[{"id":"reply","body":"Reply"}],"pageInfo":{"hasNextPage":false}}}}}}', .comments) or { panic(err) }
	assert comments.comments[0].body == 'Reply'
	assert comments.issue.comments.total == 1
	request := DetailRequest{ number: 1, limit: 10, cursor: 'after' }
	body_args := detail_query_args(request, .body)
	comments_args := detail_query_args(request, .comments)
	assert 'cursor=after' !in body_args
	assert 'first=10' !in body_args
	assert 'cursor=after' in comments_args
	assert comments_args[comments_args.index('first=10') - 1] == '-F'
	assert 'query=${issue_body_query}' in body_args
	assert 'query=${issue_comments_query}' in comments_args
}

fn test_stored_description_is_readable_while_live_refresh_is_pending() {
	mut app := detail_example_app()
	app.open_issue(1)
	request := app.begin_detail_fetch(false)
	issue := Issue{ number: 1, title: 'Compiler regression', state: 'OPEN', body: 'Stored description' }
	app.apply_detail_result(DetailResult{ request: request, part: .body, cached: true, detail: IssueDetail{ issue: issue } })
	assert app.detail_loaded && app.detail.issue.body == 'Stored description'
	assert app.detail_body_loading && app.detail_loading
	app.apply_detail_result(DetailResult{ request: request, part: .body, error: 'Offline' })
	app.apply_detail_result(DetailResult{ request: request, part: .comments, detail: IssueDetail{} })
	assert !app.detail_loading && app.detail_loaded
	assert app.detail.issue.body == 'Stored description'
	assert app.detail_error == 'Offline'
}

fn test_discussion_blocks_preserve_code_and_unclosed_fences() {
	blocks := body_blocks('## Summary\n\nSome text\n\n```v\n\tvalue := "### heading"\n\nprintln(value)\n```\n\n> A response')
	assert blocks.len == 4
	assert blocks[0].kind == .heading
	assert blocks[0].text == 'Summary'
	assert blocks[2].kind == .code
	assert blocks[2].text == '    value := "### heading"\n\nprintln(value)'
	assert blocks[3].kind == .quote
	assert body_blocks('~~~v\nfn main() {')[0].text == 'fn main() {'
	assert body_blocks('~~~v\nfn main() {')[0].kind == .code
}

fn test_detail_ui_loading_success_and_failure_have_valid_identity() {
	mut app := detail_example_app()
	app.open_issue(29233)
	request := app.begin_detail_fetch(false)
	for width in [800.0, 1440.0] {
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
	}
	app.apply_detail_result(DetailResult{ request: request, detail: decode_detail(sample_detail_response) or { panic(err) } })
	for width in [800.0, 1440.0] {
		layout := detail_layout(&app, ui2.rect(0, 0, width, 860))
		assert layout.comments_y > 0
		assert layout.content.frame.height > layout.comments_y
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
	}
	app.detail_error = 'Network unavailable'
	ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, 1440, 860))) or { panic(err) }
}

fn test_live_issue_description_and_comments_when_requested() {
	if os.getenv('GHGUI_LIVE_TESTS') != '1' { return }
	detail := fetch_detail(DetailRequest{ repo: Repository{ owner: 'vlang', name: 'v' }, number: 29233 }) or { panic(err) }
	assert detail.issue.number == 29233
	assert detail.issue.body != ''
	assert detail.comments.all(it.id != '')
	assert detail.comments.len == if detail.has_next { 50 } else { detail.issue.comments.total }
	if detail.has_next {
		next := fetch_detail(DetailRequest{ repo: Repository{ owner: 'vlang', name: 'v' }, number: 29233, cursor: detail.cursor }) or { panic(err) }
		assert next.comments.len > 0
		assert next.comments[0].id !in detail.comments.map(it.id)
	}
}
