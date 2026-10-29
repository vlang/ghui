module main

import json2
import time

struct CloseIssueRequest {
	generation int
	repo       Repository
	issue      Issue
}

struct CloseIssueResult {
	request       CloseIssueRequest
	issue         Issue
	error         string
	storage_error string
}

fn close_issue_args(request CloseIssueRequest) ![]string {
	parse_repository(request.repo.str())!
	if request.issue.kind != .issues || request.issue.number <= 0 || request.issue.state != 'OPEN' {
		return error('Only open issues can be closed.')
	}
	return ['api', '--hostname', 'github.com', '--method', 'PATCH',
		'repos/${request.repo}/issues/${request.issue.number}', '-f', 'state=closed', '-f',
		'state_reason=completed']
}

fn decode_closed_issue(source string, issue Issue) !Issue {
	response := json2.decode[json2.Any](source) or {
		return error('Could not read GitHub’s close issue response: ${err}')
	}
	if json_field(response, 'number').int() != issue.number
		|| json_text(json_field(response, 'state')) != 'closed'
		|| 'pull_request' in json_object(response) {
		message := json_text(json_field(response, 'message'))
		return error(if message != '' {
			message
		} else {
			'GitHub did not confirm that the issue was closed.'
		})
	}
	reason := json_text(json_field(response, 'state_reason')).to_upper()
	updated := json_text(json_field(response, 'updated_at'))
	return Issue{
		...issue
		state:        'CLOSED'
		state_reason: if reason != '' { reason } else { 'COMPLETED' }
		updated_at:   if updated != '' {
			updated
		} else {
			time.now().format_rfc3339().all_before('.') + 'Z'
		}
	}
}

fn close_issue_in_background(request CloseIssueRequest, results chan CloseIssueResult) {
	// Closing is a write: navigation must not cancel it or discard its outcome.
	args := close_issue_args(request) or {
		results <- CloseIssueResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	response := run_gh_with_cancel(args, unsafe { nil }) or {
		results <- CloseIssueResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	issue := decode_closed_issue(response, request.issue) or {
		results <- CloseIssueResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	mut storage_error := ''
	store_closed_item(request.repo, issue) or { storage_error = err.msg() }
	results <- CloseIssueResult{ request: request, issue: issue, storage_error: storage_error }
	wake_ui()
}

fn (app &App) closing_current_issue() bool {
	return app.kind == .issues && app.close_loading && app.close_request.issue.number == app.active_issue
}

fn (app &App) can_close_issue() bool {
	issue := app.detail.issue
	return app.kind == .issues && app.active_issue > 0 && issue.number == app.active_issue
		&& issue.kind == .issues && issue.state == 'OPEN'
		&& app.detail_loaded && !app.detail_body_loading && !app.close_loading
}

fn (mut app App) begin_close_issue() ?CloseIssueRequest {
	if !app.can_close_issue() { return none }
	app.close_generation++
	app.close_loading = true
	app.close_errors.delete(app.active_issue)
	app.close_request = CloseIssueRequest{ generation: app.close_generation, repo: app.repo, issue: app.detail.issue }
	return app.close_request
}

fn issue_with_closure(issue Issue, closed Issue) Issue {
	// Keep replies and metadata that may have changed while the write was running.
	return Issue{ ...issue, state: closed.state, state_reason: closed.state_reason, updated_at: closed.updated_at }
}

fn closed_issue_page(page IssuePage, issue Issue, state string, sort string) IssuePage {
	mut issues := page.issues.filter(it.number != issue.number)
	if state == 'CLOSED' { issues << issue }
	return IssuePage{
		...page
		issues:       sort_issues(issues, sort)
		open_count:   int_max(0, page.open_count - 1)
		closed_count: page.closed_count + 1
	}
}

fn (mut app App) apply_close_issue_result(result CloseIssueResult) bool {
	if !app.close_loading || result.request.generation != app.close_generation
		|| result.request.repo.str() != app.repo.str()
		|| result.request.issue.number != app.close_request.issue.number {
		return false
	}
	app.close_loading = false
	number := result.request.issue.number
	if result.error != '' {
		app.close_errors[number] = result.error
		return false
	}
	app.close_errors.delete(number)
	if result.storage_error != '' { app.storage_error = result.storage_error }
	mut issue := result.issue
	if cached := app.detail_cache[number] {
		if cached.detail.issue.kind == .issues {
			issue = issue_with_closure(cached.detail.issue, result.issue)
			app.detail_cache[number] = CachedDetail{
				...cached
				detail: IssueDetail{ ...cached.detail, issue: issue }
			}
		}
	}
	for state in ['OPEN', 'CLOSED'] {
		key := 'issues_${state}'
		if page := app.list_cache[key] {
			app.list_cache[key] = closed_issue_page(page, issue, state, app.sort)
		}
	}
	if app.kind == .issues {
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
