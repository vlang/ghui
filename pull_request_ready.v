module main

import time

struct ReadyRequest {
	generation int
	repo       Repository
	issue      Issue
}

struct ReadyResult {
	request       ReadyRequest
	issue         Issue
	error         string
	storage_error string
}

fn mark_ready_args(request ReadyRequest) ![]string {
	parse_repository(request.repo.str())!
	issue := request.issue
	if issue.kind != .prs || issue.number <= 0 || issue.state != 'OPEN' || !issue.is_draft {
		return error('Only open draft pull requests can be marked ready for review.')
	}
	return ['pr', 'ready', issue.number.str(), '--repo', 'github.com/${request.repo}']
}

fn mark_ready_in_background(request ReadyRequest, results chan ReadyResult) {
	// This write continues when navigating away, just like a merge or comment.
	args := mark_ready_args(request) or {
		results <- ReadyResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	run_gh_with_cancel(args, unsafe { nil }) or {
		results <- ReadyResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	issue := Issue{ ...request.issue, is_draft: false, updated_at: time.now().format_rfc3339().all_before('.') + 'Z' }
	mut storage_error := ''
	store_issue_body(DetailRequest{ kind: .prs, repo: request.repo, number: issue.number }, issue) or { storage_error = err.msg() }
	results <- ReadyResult{ request: request, issue: issue, storage_error: storage_error }
	wake_ui()
}

fn (app &App) marking_current_pr_ready() bool {
	return app.kind == .prs && app.ready_loading && app.ready_request.issue.number == app.active_issue
}

fn (app &App) can_mark_ready() bool {
	issue := app.detail.issue
	return app.kind == .prs && app.active_issue > 0 && issue.number == app.active_issue
		&& issue.kind == .prs && issue.state == 'OPEN' && issue.is_draft
		&& app.detail_loaded && !app.detail_body_loading && !app.ready_loading && !app.merge_loading && !app.close_pr_loading
}

fn (mut app App) begin_mark_ready() ?ReadyRequest {
	if !app.can_mark_ready() { return none }
	app.ready_generation++
	app.ready_loading = true
	app.ready_errors.delete(app.active_issue)
	app.ready_request = ReadyRequest{ generation: app.ready_generation, repo: app.repo, issue: app.detail.issue }
	return app.ready_request
}

fn issue_marked_ready(issue Issue, ready Issue) Issue {
	// Preserve metadata and replies that changed while the request was running.
	return Issue{ ...issue, is_draft: false, updated_at: if issue.updated_at > ready.updated_at {
		issue.updated_at
	} else {
		ready.updated_at
	} }
}

fn ready_pr_page(page IssuePage, ready Issue, sort string) IssuePage {
	mut issues := page.issues.clone()
	for i, issue in issues {
		if issue.number == ready.number { issues[i] = issue_marked_ready(issue, ready) }
	}
	return IssuePage{ ...page, issues: sort_issues(issues, sort) }
}

fn (mut app App) apply_ready_result(result ReadyResult) bool {
	if !app.ready_loading || result.request.generation != app.ready_generation
		|| result.request.repo.str() != app.repo.str()
		|| result.request.issue.number != app.ready_request.issue.number {
		return false
	}
	app.ready_loading = false
	number := result.request.issue.number
	if result.error != '' {
		app.ready_errors[number] = result.error
		return false
	}
	app.ready_errors.delete(number)
	if result.storage_error != '' { app.storage_error = result.storage_error }
	for state in ['OPEN', 'CLOSED'] {
		key := 'prs_${state}'
		if page := app.list_cache[key] {
			app.list_cache[key] = ready_pr_page(page, result.issue, app.sort)
		}
	}
	if cached := app.detail_cache[number] {
		if cached.detail.issue.kind == .prs {
			app.detail_cache[number] = CachedDetail{
				...cached
				detail: IssueDetail{ ...cached.detail, issue: issue_marked_ready(cached.detail.issue, result.issue) }
			}
		}
	}
	if app.kind == .prs {
		// Reads started before this write must not restore the draft status.
		if !isnil(app.list_cancel) { app.list_cancel.stop() }
		app.generation++
		app.loading = false
		app.issues = ready_pr_page(IssuePage{ issues: app.issues }, result.issue, app.sort).issues
		if app.active_issue == number {
			if !isnil(app.detail_cancel) { app.detail_cancel.stop() }
			app.detail_generation++
			app.detail_loading = false
			app.detail_body_loading = false
			app.detail_comments_loading = false
			app.detail = IssueDetail{ ...app.detail, issue: issue_marked_ready(app.detail.issue, result.issue) }
		}
	}
	return true
}
