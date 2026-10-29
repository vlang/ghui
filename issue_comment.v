module main

import json2

struct CommentRequest {
	generation int
	repo       Repository
	kind       ItemKind
	number     int
	body       string
}

struct CommentResult {
	request CommentRequest
	comment IssueComment
	error   string
}

fn add_comment_args(request CommentRequest) ![]string {
	parse_repository(request.repo.str())!
	if request.number <= 0 || request.body.trim_space() == '' {
		return error('Write a comment before posting it.')
	}
	// Pull request conversations use the issue comments endpoint too. A raw
	// field keeps the text literal, whatever characters it starts with.
	return ['api', '--hostname', 'github.com', '--method', 'POST',
		'repos/${request.repo}/issues/${request.number}/comments', '-f', 'body=${request.body}']
}

fn decode_added_comment(source string) !IssueComment {
	response := json2.decode[json2.Any](source) or {
		return error('Could not read GitHub’s comment response: ${err}')
	}
	// REST's node_id is the ID that the GraphQL comment pages return.
	id := json_text(json_field(response, 'node_id'))
	if id == '' {
		message := json_text(json_field(response, 'message'))
		return error(if message != '' {
			message
		} else {
			'GitHub did not confirm that the comment was posted.'
		})
	}
	return IssueComment{
		id:         id
		body:       json_text(json_field(response, 'body'))
		created_at: json_text(json_field(response, 'created_at'))
		author:     User{ login: json_text(json_field(json_field(response, 'user'), 'login')) }
	}
}

fn add_comment_in_background(request CommentRequest, results chan CommentResult) {
	// A comment is a write: navigation must not cancel it or discard its outcome.
	args := add_comment_args(request) or {
		results <- CommentResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	response := run_gh_with_cancel(args, unsafe { nil }) or {
		results <- CommentResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	comment := decode_added_comment(response) or {
		results <- CommentResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	results <- CommentResult{ request: request, comment: comment }
	wake_ui()
}

fn (app &App) comment_draft() string {
	return app.comment_drafts[app.active_issue] or { '' }
}

// Returns whether the Comment button's state changed.
fn (mut app App) set_comment_draft(text string) bool {
	if app.active_issue == 0 { return false }
	was_blank := app.comment_draft().trim_space() == ''
	if text == '' {
		app.comment_drafts.delete(app.active_issue)
	} else {
		app.comment_drafts[app.active_issue] = text
	}
	return was_blank != (text.trim_space() == '')
}

fn (app &App) posting_current_comment() bool {
	return app.comment_loading && app.comment_request.kind == app.kind
		&& app.comment_request.number == app.active_issue
}

fn (app &App) can_add_comment() bool {
	return app.active_issue > 0 && !app.comment_loading && app.comment_draft().trim_space() != ''
}

fn (mut app App) begin_add_comment() ?CommentRequest {
	if !app.can_add_comment() { return none }
	app.comment_generation++
	app.comment_loading = true
	app.comment_errors.delete(app.active_issue)
	app.comment_request = CommentRequest{
		generation: app.comment_generation
		repo:       app.repo
		kind:       app.kind
		number:     app.active_issue
		body:       app.comment_draft()
	}
	return app.comment_request
}

fn detail_with_comment(detail IssueDetail, comment IssueComment) IssueDetail {
	return IssueDetail{
		...detail
		issue:    Issue{ ...detail.issue, comments: Count{ total: detail.issue.comments.total + 1 } }
		comments: merge_comments(detail.comments, [comment])
	}
}

fn (mut app App) apply_comment_result(result CommentResult) {
	request := result.request
	if !app.comment_loading || request.generation != app.comment_generation
		|| request.repo.str() != app.repo.str() {
		return
	}
	app.comment_loading = false
	number := request.number
	if result.error != '' {
		app.comment_errors[number] = result.error
		return
	}
	if (app.comment_drafts[number] or { '' }) == request.body { app.comment_drafts.delete(number) }
	// Reads that began before now may not include the comment yet.
	comment := IssueComment{ ...result.comment, posted: app.detail_generation }
	if cached := app.detail_cache[number] {
		if cached.detail.issue.kind == request.kind {
			app.detail_cache[number] = CachedDetail{ ...cached, detail: detail_with_comment(cached.detail, comment) }
		}
	}
	if app.kind != request.kind { return }
	for i, issue in app.issues {
		if issue.number == number {
			app.issues[i] = Issue{ ...issue, comments: Count{ total: issue.comments.total + 1 } }
			break
		}
	}
	if app.active_issue == number { app.detail = detail_with_comment(app.detail, comment) }
}
