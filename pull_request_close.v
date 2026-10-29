module main

import json2
import time

struct ClosePrRequest {
	generation int
	repo       Repository
	issue      Issue
}

struct ClosePrResult {
	request       ClosePrRequest
	issue         Issue
	error         string
	storage_error string
}

fn close_pr_args(request ClosePrRequest) ![]string {
	parse_repository(request.repo.str())!
	if request.issue.kind != .prs || request.issue.number <= 0 || request.issue.state != 'OPEN' {
		return error('Only open pull requests can be closed without merging.')
	}
	return ['api', '--hostname', 'github.com', '--method', 'PATCH',
		'repos/${request.repo}/pulls/${request.issue.number}', '-f', 'state=closed']
}

fn decode_closed_pr(source string, issue Issue) !Issue {
	response := json2.decode[json2.Any](source) or {
		return error('Could not read GitHub’s close pull request response: ${err}')
	}
	merged := json_field(response, 'merged')
	if json_field(response, 'number').int() != issue.number
		|| json_text(json_field(response, 'state')) != 'closed' || merged !is bool {
		message := json_text(json_field(response, 'message'))
		return error(if message != '' {
			message
		} else {
			'GitHub did not confirm that the pull request was closed without merging.'
		})
	}
	if merged.bool() || json_text(json_field(response, 'merged_at')) != '' {
		return error('The pull request has already been merged. Refresh the PR.')
	}
	updated := json_text(json_field(response, 'updated_at'))
	return Issue{
		...issue
		state:        'CLOSED'
		state_reason: ''
		updated_at:   if updated != '' {
			updated
		} else {
			time.now().format_rfc3339().all_before('.') + 'Z'
		}
	}
}

fn close_pr_in_background(request ClosePrRequest, results chan ClosePrResult) {
	// Closing is a write: navigation must not cancel it or discard its outcome.
	args := close_pr_args(request) or {
		results <- ClosePrResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	response := run_gh_with_cancel(args, unsafe { nil }) or {
		results <- ClosePrResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	issue := decode_closed_pr(response, request.issue) or {
		results <- ClosePrResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	mut storage_error := ''
	store_closed_item(request.repo, issue) or { storage_error = err.msg() }
	results <- ClosePrResult{ request: request, issue: issue, storage_error: storage_error }
	wake_ui()
}

fn (app &App) closing_current_pr() bool {
	return app.kind == .prs && app.close_pr_loading && app.close_pr_request.issue.number == app.active_issue
}

fn (app &App) can_close_pr() bool {
	issue := app.detail.issue
	return app.kind == .prs && app.active_issue > 0 && issue.number == app.active_issue
		&& issue.kind == .prs && issue.state == 'OPEN'
		&& app.detail_loaded && !app.detail_body_loading && !app.close_pr_loading
		&& !app.merge_loading && !app.ready_loading
}

fn (mut app App) begin_close_pr() ?ClosePrRequest {
	if !app.can_close_pr() { return none }
	app.close_pr_generation++
	app.close_pr_loading = true
	app.close_pr_errors.delete(app.active_issue)
	app.close_pr_request = ClosePrRequest{ generation: app.close_pr_generation, repo: app.repo, issue: app.detail.issue }
	return app.close_pr_request
}

fn (mut app App) apply_close_pr_result(result ClosePrResult) bool {
	if !app.close_pr_loading || result.request.generation != app.close_pr_generation
		|| result.request.repo.str() != app.repo.str()
		|| result.request.issue.number != app.close_pr_request.issue.number {
		return false
	}
	app.close_pr_loading = false
	number := result.request.issue.number
	if result.error != '' {
		app.close_pr_errors[number] = result.error
		return false
	}
	app.close_pr_errors.delete(number)
	if result.storage_error != '' { app.storage_error = result.storage_error }
	mut issue := result.issue
	if cached := app.detail_cache[number] {
		if cached.detail.issue.kind == .prs {
			issue = issue_with_closure(cached.detail.issue, result.issue)
			app.detail_cache[number] = CachedDetail{
				...cached
				detail: IssueDetail{ ...cached.detail, issue: issue }
			}
		}
	}
	for state in ['OPEN', 'CLOSED'] {
		key := 'prs_${state}'
		if page := app.list_cache[key] {
			app.list_cache[key] = closed_issue_page(page, issue, state, app.sort)
		}
	}
	if app.kind == .prs {
		// Obsolete reads must not restore OPEN after GitHub confirms the closure.
		if !isnil(app.list_cancel) { app.list_cancel.stop() }
		app.generation++
		app.loading = false
		page := closed_issue_page(IssuePage{ issues: app.issues, open_count: app.open_count, closed_count: app.closed_count },
			issue, app.state, app.sort)
		app.issues = page.issues
		app.open_count = page.open_count
		app.closed_count = page.closed_count
		app.selected.delete(number)
		if app.active_issue == number {
			if !isnil(app.detail_cancel) { app.detail_cancel.stop() }
			app.detail_generation++
			app.detail_loading = false
			app.detail_body_loading = false
			app.detail_comments_loading = false
			app.detail = IssueDetail{ ...app.detail, issue: issue_with_closure(app.detail.issue, result.issue) }
		}
	}
	return true
}
