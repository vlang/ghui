module main

import time

// Active run statuses, listed one server-filtered query each.
const ci_active_statuses = ['in_progress', 'queued', 'waiting', 'pending', 'requested']
// Cancel POSTs cost 5 secondary-limit points; ~150/min stays under the ~900/min budget.
const ci_cancel_interval = 400 * time.millisecond
const ci_page_size = 100
const ci_max_pages = 10

struct StopCiRequest {
	generation int
	repo       Repository
}

struct StopCiResult {
	request StopCiRequest
mut:
	cancelled int
	already   int
	failed    int
	error     string
}

fn list_active_runs_args(repo Repository, status string, page int) ![]string {
	parse_repository(repo.str())!
	if status !in ci_active_statuses || page < 1 {
		return error('Invalid workflow run query.')
	}
	return ['api', '/repos/${repo}/actions/runs?status=${status}&per_page=${ci_page_size}&page=${page}&exclude_pull_requests=true',
		'-q', '.workflow_runs[].id']
}

fn cancel_run_args(repo Repository, id int) ![]string {
	parse_repository(repo.str())!
	if id <= 0 { return error('Invalid workflow run id.') }
	return ['api', '-X', 'POST', '/repos/${repo}/actions/runs/${id}/cancel']
}

fn parse_run_ids(output string) []int {
	mut ids := []int{}
	for line in output.split_into_lines() {
		id := line.trim_space()
		if id.len > 0 && id.bytes().all(it >= `0` && it <= `9`) && id.int() > 0 { ids << id.int() }
	}
	return ids
}

fn list_active_run_ids(repo Repository) ![]int {
	mut seen := map[int]bool{}
	mut ids := []int{}
	for status in ci_active_statuses {
		for page in 1 .. ci_max_pages + 1 {
			found := parse_run_ids(run_gh_with_cancel(list_active_runs_args(repo, status, page)!, unsafe { nil })!)
			for id in found {
				if id !in seen {
					seen[id] = true
					ids << id
				}
			}
			if found.len < ci_page_size { break }
		}
	}
	return ids
}

fn is_rate_limited(message string) bool {
	return message.contains('HTTP 403') || message.contains('HTTP 429')
}

fn stop_ci_in_background(request StopCiRequest, results chan StopCiResult) {
	ids := list_active_run_ids(request.repo) or {
		results <- StopCiResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	mut result := StopCiResult{ request: request }
	for i, id in ids {
		args := cancel_run_args(request.repo, id) or { continue }
		mut message := ''
		run_gh_with_cancel(args, unsafe { nil }) or { message = err.msg() }
		if message != '' && is_rate_limited(message) {
			// Secondary rate limit: wait it out once, as the CLI script does.
			time.sleep(60 * time.second)
			message = ''
			run_gh_with_cancel(args, unsafe { nil }) or { message = err.msg() }
		}
		if message == '' {
			result.cancelled++
		} else if message.contains('HTTP 409') {
			result.already++
		} else {
			result.failed++
			if result.error == '' { result.error = message }
		}
		if i + 1 < ids.len { time.sleep(ci_cancel_interval) }
	}
	results <- result
	wake_ui()
}

fn (app &App) can_stop_ci() bool {
	return !app.stop_ci_loading
}

fn (mut app App) begin_stop_ci() ?StopCiRequest {
	if !app.can_stop_ci() { return none }
	app.stop_ci_generation++
	app.stop_ci_loading = true
	app.stop_ci_message = ''
	app.stop_ci_request = StopCiRequest{ generation: app.stop_ci_generation, repo: app.repo }
	return app.stop_ci_request
}

fn stop_ci_summary(result StopCiResult) string {
	if result.error != '' && result.cancelled + result.already == 0 {
		return 'Could not stop CI runs: ${result.error}'
	}
	if result.cancelled + result.already + result.failed == 0 { return 'No running CI jobs to stop' }
	mut text := 'Stopped ${result.cancelled} CI run(s)'
	if result.already > 0 { text += ' · ${result.already} already stopping' }
	if result.failed > 0 { text += ' · ${result.failed} failed (${result.error})' }
	return text
}

fn (mut app App) apply_stop_ci_result(result StopCiResult) bool {
	if !app.stop_ci_loading || result.request.generation != app.stop_ci_generation { return false }
	app.stop_ci_loading = false
	app.stop_ci_message = stop_ci_summary(result)
	return true
}

const ci_poll_interval = 30 * time.second

struct CiCountsResult {
	repo        Repository
	in_progress int
	queued      int
	error       string
}

fn ci_count_args(repo Repository, status string) ![]string {
	parse_repository(repo.str())!
	if status !in ci_active_statuses { return error('Invalid workflow run status.') }
	return ['api', '/repos/${repo}/actions/runs?status=${status}&per_page=1&exclude_pull_requests=true',
		'-q', '.total_count']
}

fn fetch_ci_counts(repo Repository) CiCountsResult {
	in_progress := run_gh_with_cancel(ci_count_args(repo, 'in_progress') or { return CiCountsResult{ repo: repo, error: err.msg() } },
		unsafe { nil }) or { return CiCountsResult{ repo: repo, error: err.msg() } }
	queued := run_gh_with_cancel(ci_count_args(repo, 'queued') or { return CiCountsResult{ repo: repo, error: err.msg() } },
		unsafe { nil }) or { return CiCountsResult{ repo: repo, error: err.msg() } }
	return CiCountsResult{ repo: repo, in_progress: in_progress.int(), queued: queued.int() }
}

fn ci_counts_once(repo Repository, results chan CiCountsResult) {
	results <- fetch_ci_counts(repo)
	wake_ui()
}

fn ci_counts_poll(repo Repository, results chan CiCountsResult) {
	for {
		results <- fetch_ci_counts(repo)
		wake_ui()
		time.sleep(ci_poll_interval)
	}
}

fn (mut app App) apply_ci_counts(result CiCountsResult) {
	if result.repo.str() != app.repo.str() { return }
	app.ci_counts_known = result.error == ''
	if result.error == '' {
		app.ci_in_progress = result.in_progress
		app.ci_queued = result.queued
	}
}

fn (app &App) ci_counts_label() string {
	if !app.ci_counts_known { return 'CI: –' }
	return 'CI: ${app.ci_in_progress} running · ${app.ci_queued} queued'
}
