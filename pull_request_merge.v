module main

import json2
import time

const squash_merge_message_query = r'query SquashMergeMessage($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      headRefOid mergeable
      viewerMergeBodyText(mergeType: SQUASH)
    }
  }
}'

struct MergeRequest {
	generation int
	repo       Repository
	issue      Issue
}

struct MergeResult {
	request       MergeRequest
	issue         Issue
	error         string
	storage_error string
}

fn squash_merge_args(request MergeRequest) ![]string {
	parse_repository(request.repo.str())!
	issue := request.issue
	if issue.kind != .prs || issue.number <= 0 || issue.state != 'OPEN' || issue.is_draft {
		return error('Only open, non-draft pull requests can be squash merged.')
	}
	if issue.head_oid == '' {
		return error('Refresh the pull request to load its head commit before merging.')
	}
	if issue.has_merge_conflicts() {
		return error('Resolve merge conflicts and refresh before squash merging.')
	}
	return ['api', '--hostname', 'github.com', '--method', 'PUT',
		'repos/${request.repo}/pulls/${issue.number}/merge', '-f', 'merge_method=squash', '-f',
		'sha=${issue.head_oid}']
}

fn remove_commit_coauthors(message string) string {
	mut lines := []string{}
	mut removed := false
	for line in message.split_into_lines() {
		if line.trim_space().to_lower().starts_with('co-authored-by:') {
			removed = true
			continue
		}
		lines << line
	}
	if !removed { return message }
	for lines.len > 0 && lines.last().trim_space() == '' {
		lines.delete_last()
	}
	return lines.join('\n')
}

fn decode_squash_merge_message(source string, expected_head string) !string {
	response := decode_detail_response(source)!
	pr := json_field(json_field(json_field(response, 'data'), 'repository'), 'pullRequest')
	message := json_field(pr, 'viewerMergeBodyText')
	if message !is string || json_text(json_field(pr, 'headRefOid')) == '' {
		return error('GitHub did not return the squash commit description.')
	}
	if json_text(json_field(pr, 'headRefOid')) != expected_head {
		return error('The head branch was modified. Refresh the PR before merging.')
	}
	if json_text(json_field(pr, 'mergeable')) == 'CONFLICTING' {
		return error('Resolve merge conflicts and refresh before squash merging.')
	}
	return remove_commit_coauthors(json_text(message))
}

fn fetch_squash_merge_message(request MergeRequest) !string {
	args := ['api', '--hostname', 'github.com', 'graphql', '-f',
		'query=${squash_merge_message_query}', '-f', 'owner=${request.repo.owner}', '-f',
		'name=${request.repo.name}', '-F', 'number=${request.issue.number}']
	return decode_squash_merge_message(run_gh_with_cancel(args, unsafe { nil })!, request.issue.head_oid)
}

fn decode_squash_merge(source string) ! {
	response := json2.decode[json2.Any](source) or {
		return error('Could not read GitHub’s merge response: ${err}')
	}
	if !json_field(response, 'merged').bool() {
		message := json_text(json_field(response, 'message'))
		return error(if message != '' {
			message
		} else {
			'GitHub did not confirm that the pull request was merged.'
		})
	}
}

fn squash_merge_in_background(request MergeRequest, results chan MergeResult) {
	// A merge is a write: navigation must not cancel it or discard its outcome.
	mut args := squash_merge_args(request) or {
		results <- MergeResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	message := fetch_squash_merge_message(request) or {
		results <- MergeResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	// Explicitly send even an empty body so GitHub does not regenerate co-authors.
	args << ['-f', 'commit_message=${message}']
	response := run_gh_with_cancel(args, unsafe { nil }) or {
		results <- MergeResult{ request: request, error: '${err.msg()} Refresh the PR before retrying.' }
		wake_ui()
		return
	}
	decode_squash_merge(response) or {
		results <- MergeResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	merged_at := time.now().format_rfc3339().all_before('.') + 'Z'
	issue := Issue{ ...request.issue, state: 'MERGED', merged_at: merged_at, updated_at: merged_at }
	mut storage_error := ''
	store_merged_pull_request(request.repo, issue) or { storage_error = err.msg() }
	results <- MergeResult{ request: request, issue: issue, storage_error: storage_error }
	wake_ui()
}

fn (app &App) merging_current_pr() bool {
	return app.kind == .prs && app.merge_loading && app.merge_request.issue.number == app.active_issue
}

fn (app &App) can_squash_merge() bool {
	issue := app.detail.issue
	return app.kind == .prs && app.active_issue > 0 && issue.number == app.active_issue
		&& issue.kind == .prs && issue.state == 'OPEN' && !issue.is_draft && !issue.has_merge_conflicts()
		&& app.detail_loaded && !app.detail_body_loading && issue.head_oid != '' && !app.merge_loading && !app.ready_loading && !app.close_pr_loading
}

fn (mut app App) begin_squash_merge() ?MergeRequest {
	if !app.can_squash_merge() { return none }
	app.merge_generation++
	app.merge_loading = true
	app.merge_errors.delete(app.active_issue)
	app.merge_request = MergeRequest{ generation: app.merge_generation, repo: app.repo, issue: app.detail.issue }
	return app.merge_request
}

fn merged_pr_page(page IssuePage, issue Issue, state string, sort string) IssuePage {
	mut issues := page.issues.filter(it.number != issue.number)
	if state == 'CLOSED' { issues << issue }
	return IssuePage{
		...page
		issues:       sort_issues(issues, sort)
		open_count:   int_max(0, page.open_count - 1)
		closed_count: page.closed_count + 1
	}
}

fn (mut app App) apply_merge_result(result MergeResult) bool {
	if !app.merge_loading || result.request.generation != app.merge_generation
		|| result.request.repo.str() != app.repo.str()
		|| result.request.issue.number != app.merge_request.issue.number {
		return false
	}
	app.merge_loading = false
	number := result.request.issue.number
	if result.error != '' {
		app.merge_errors[number] = result.error
		return false
	}
	app.merge_errors.delete(number)
	if result.storage_error != '' { app.storage_error = result.storage_error }
	for state in ['OPEN', 'CLOSED'] {
		key := 'prs_${state}'
		if page := app.list_cache[key] {
			app.list_cache[key] = merged_pr_page(page, result.issue, state, app.sort)
		}
	}
	if cached := app.detail_cache[number] {
		if cached.detail.issue.kind == .prs {
			app.detail_cache[number] = CachedDetail{
				...cached
				detail: IssueDetail{ ...cached.detail, issue: Issue{ ...cached.detail.issue, state: 'MERGED', merged_at: result.issue.merged_at, updated_at: result.issue.updated_at } }
			}
		}
	}
	if app.kind == .prs {
		// Invalidate reads started before the merge so they cannot restore OPEN.
		if !isnil(app.list_cancel) { app.list_cancel.stop() }
		app.generation++
		app.loading = false
		page := merged_pr_page(IssuePage{ issues: app.issues, open_count: app.open_count, closed_count: app.closed_count },
			result.issue, app.state, app.sort)
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
			app.detail = IssueDetail{ ...app.detail, issue: Issue{ ...app.detail.issue, state: 'MERGED', merged_at: result.issue.merged_at, updated_at: result.issue.updated_at } }
		}
	}
	return true
}
