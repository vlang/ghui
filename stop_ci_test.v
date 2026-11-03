module main

fn test_stop_ci_args() {
	repo := parse_repository('vlang/v')!
	assert cancel_run_args(repo, 42)! == ['api', '-X', 'POST', '/repos/vlang/v/actions/runs/42/cancel']
	assert list_active_runs_args(repo, 'queued', 2)![1].contains('status=queued&per_page=100&page=2')
	if _ := cancel_run_args(repo, 0) { assert false }
	if _ := list_active_runs_args(repo, 'x/../y', 1) { assert false }
}

fn test_parse_run_ids() {
	assert parse_run_ids('1\n22\r\nfoo\n\n-3\n') == [1, 22]
}

fn test_stop_ci_lifecycle() {
	mut app := App{ repo: parse_repository('vlang/v')! }
	request := app.begin_stop_ci() or { panic('expected request') }
	assert app.begin_stop_ci() == none
	assert !app.apply_stop_ci_result(StopCiResult{ request: StopCiRequest{ generation: 99 } })
	assert app.apply_stop_ci_result(StopCiResult{ request: request, cancelled: 3, already: 1 })
	assert app.stop_ci_message == 'Stopped 3 CI run(s) · 1 already stopping'
	assert !app.stop_ci_loading
}

fn test_ci_counts() {
	mut app := App{ repo: parse_repository('vlang/v')! }
	assert app.ci_counts_label() == 'CI: –'
	app.apply_ci_counts(CiCountsResult{ repo: app.repo, in_progress: 2, queued: 5 })
	assert app.ci_counts_label() == 'CI: 2 running · 5 queued'
	app.apply_ci_counts(CiCountsResult{ repo: parse_repository('a/b')!, in_progress: 9 })
	assert app.ci_in_progress == 2
	assert ci_count_args(app.repo, 'queued')![1].contains('status=queued&per_page=1')
}
