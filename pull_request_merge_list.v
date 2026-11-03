module main

const merge_info_query = r'query MergeInfo($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) { state isDraft mergeable headRefOid }
  }
}'

const max_merge_info_fetches = 6

struct MergeInfo {
	head_oid   string
	mergeable  string
	mergeable_now bool
}

struct MergeInfoResult {
	repo   Repository
	number int
	info   MergeInfo
	error  string
}

fn decode_merge_info(source string) !MergeInfo {
	response := decode_detail_response(source)!
	pr := json_field(json_field(json_field(response, 'data'), 'repository'), 'pullRequest')
	head := json_text(json_field(pr, 'headRefOid'))
	if head == '' { return error('GitHub did not return the head commit.') }
	mergeable := json_text(json_field(pr, 'mergeable'))
	open := json_text(json_field(pr, 'state')) == 'OPEN' && !json_field(pr, 'isDraft').bool()
	return MergeInfo{ head_oid: head, mergeable: mergeable, mergeable_now: open && mergeable != 'CONFLICTING' }
}

fn fetch_merge_info_in_background(repo Repository, number int, results chan MergeInfoResult) {
	args := ['api', '--hostname', 'github.com', 'graphql', '-f', 'query=${merge_info_query}', '-f',
		'owner=${repo.owner}', '-f', 'name=${repo.name}', '-F', 'number=${number}']
	output := run_gh_with_cancel(args, unsafe { nil }) or {
		results <- MergeInfoResult{ repo: repo, number: number, error: err.msg() }
		wake_ui()
		return
	}
	info := decode_merge_info(output) or {
		results <- MergeInfoResult{ repo: repo, number: number, error: err.msg() }
		wake_ui()
		return
	}
	results <- MergeInfoResult{ repo: repo, number: number, info: info }
	wake_ui()
}

fn (issue Issue) wants_list_merge() bool {
	return issue.kind == .prs && issue.state == 'OPEN' && !issue.is_draft && !issue.has_merge_conflicts()
		&& issue.codex_review_passed()
}

// Starts up to a few parallel lookups so buttons appear as each result arrives.
fn (mut app App) pending_merge_info_numbers() []int {
	mut numbers := []int{}
	if app.kind != .prs || app.active_issue > 0 { return numbers }
	for issue in app.issues {
		if app.merge_info_pending.len + numbers.len >= max_merge_info_fetches { break }
		if !issue.wants_list_merge() || issue.number in app.merge_infos || issue.number in app.merge_info_pending
			|| issue.number in app.merge_info_failed {
			continue
		}
		numbers << issue.number
	}
	for number in numbers {
		app.merge_info_pending[number] = true
	}
	return numbers
}

fn (mut app App) apply_merge_info_result(result MergeInfoResult) {
	if result.repo.str() != app.repo.str() { return }
	app.merge_info_pending.delete(result.number)
	if result.error != '' {
		app.merge_info_failed[result.number] = true
		return
	}
	app.merge_infos[result.number] = result.info
}

fn (app &App) list_merge_ready(issue Issue) bool {
	info := app.merge_infos[issue.number] or { return false }
	return issue.wants_list_merge() && info.mergeable_now
}

fn (mut app App) begin_list_squash_merge(number int) ?MergeRequest {
	if app.kind != .prs || app.merge_loading || app.ready_loading || app.close_pr_loading { return none }
	for issue in app.issues {
		if issue.number != number { continue }
		if !app.list_merge_ready(issue) { return none }
		info := app.merge_infos[number] or { return none }
		app.merge_generation++
		app.merge_loading = true
		app.merge_errors.delete(number)
		app.merge_request = MergeRequest{
			generation: app.merge_generation
			repo:       app.repo
			issue:      Issue{ ...issue, head_oid: info.head_oid, mergeable: info.mergeable }
		}
		return app.merge_request
	}
	return none
}

fn (app &App) merging_pr(number int) bool {
	return app.merge_loading && app.merge_request.issue.number == number
}
