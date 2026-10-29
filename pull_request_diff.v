module main

import math
import ui2

struct DiffRequest {
	generation int
	repo       Repository
	number     int
	cancel     &FetchCancellation = unsafe { nil }
}

struct PullRequestDiff {
	text          string
	runs          []ui2.TextRun
	changed_files int
	additions     int
	deletions     int
}

struct DiffResult {
	request DiffRequest
	diff    PullRequestDiff
	error   string
}

fn pull_request_diff_args(request DiffRequest) ![]string {
	parse_repository(request.repo.str())!
	if request.number <= 0 { return error('A pull request number is required.') }
	return ['pr', 'diff', request.number.str(), '--repo', 'github.com/${request.repo}', '--color',
		'never']
}

fn diff_text_style() ui2.TextStyle {
	return ui2.TextStyle{ size: 12, font_family: 'Courier New', color: ink, valign: .top }
}

fn decode_pull_request_diff(source string) !PullRequestDiff {
	if source.trim_space() != '' && !source.starts_with('diff --git ') {
		return error('GitHub did not return a unified diff.')
	}
	mut runs := []ui2.TextRun{}
	mut changed_files := 0
	mut additions := 0
	mut deletions := 0
	mut in_hunk := false
	lines := source.split('\n')
	for i, line in lines {
		mut style := diff_text_style()
		if line.starts_with('diff --git ') {
			changed_files++
			in_hunk = false
			style = ui2.TextStyle{ ...style, bold: true, background_color: subtle }
		} else if line.starts_with('@@ ') {
			in_hunk = true
			style = ui2.TextStyle{ ...style, color: blue, background_color: 0xddf4ff }
		} else if in_hunk && line.starts_with('+') {
			additions++
			style = ui2.TextStyle{ ...style, color: green, background_color: 0xe6ffec }
		} else if in_hunk && line.starts_with('-') {
			deletions++
			style = ui2.TextStyle{ ...style, color: red, background_color: 0xffebe9 }
		} else if !in_hunk || line.starts_with('\\') {
			style = ui2.TextStyle{ ...style, color: muted }
		}
		text := line + if i < lines.len - 1 { '\n' } else { '' }
		if text != '' { runs << ui2.TextRun{ text: text, style: style } }
	}
	return PullRequestDiff{
		text:          source
		runs:          runs
		changed_files: changed_files
		additions:     additions
		deletions:     deletions
	}
}

fn fetch_pull_request_diff(request DiffRequest) !PullRequestDiff {
	args := pull_request_diff_args(request)!
	return decode_pull_request_diff(run_gh_raw_with_cancel(args, request.cancel)!)
}

fn fetch_diff_in_background(request DiffRequest, results chan DiffResult) {
	diff := fetch_pull_request_diff(request) or {
		if cancelled(request.cancel) { return }
		results <- DiffResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	if cancelled(request.cancel) { return }
	results <- DiffResult{ request: request, diff: diff }
	wake_ui()
}

fn (mut app App) begin_diff_fetch() ?DiffRequest {
	if app.kind != .prs || app.active_issue <= 0 || app.diff_loading { return none }
	if !app.diff_visible {
		app.pr_diff = PullRequestDiff{}
		app.diff_loaded = false
	}
	if !isnil(app.diff_request.cancel) { app.diff_request.cancel.stop() }
	app.diff_generation++
	app.diff_visible = true
	app.diff_loading = true
	app.diff_error = ''
	app.diff_request = DiffRequest{
		generation: app.diff_generation
		repo:       app.repo
		number:     app.active_issue
		cancel:     &FetchCancellation{}
	}
	return app.diff_request
}

fn (mut app App) close_diff() {
	if !isnil(app.diff_request.cancel) { app.diff_request.cancel.stop() }
	app.diff_generation++
	app.diff_visible = false
	app.diff_loading = false
}

fn (mut app App) apply_diff_result(result DiffResult) {
	if !app.diff_visible || !app.diff_loading || app.kind != .prs
		|| result.request.generation != app.diff_generation
		|| result.request.number != app.active_issue || result.request.repo.str() != app.repo.str() {
		return
	}
	app.diff_loading = false
	app.diff_error = result.error
	if result.error != '' { return }
	app.pr_diff = result.diff
	app.diff_loaded = true
}

fn render_pr_diff(app &App, bounds ui2.Rect) ui2.Element {
	margin := 18.0
	width := math.max(1, bounds.width - margin * 2)
	mut children := [render_mode_switch(app, margin)]
	refresh := ui2.button('refresh', if app.diff_loading {
		'↻  Loading…'
	} else {
		'↻  Refresh'
	},
		ui2.rect(margin + 156, 12, 132, 30), bordered_box(subtle, 6), text_style(13, ink, false))
	children << ui2.Element{ ...refresh, enabled: !app.diff_loading, tooltip: 'Refresh the pull request diff (⌘R / Ctrl+R / F5)' }
	children << ui2.with_tooltip(ui2.button('back', '←  Back to PR', ui2.rect(margin + 300, 12, 128, 30),
		bordered_box(subtle, 6), text_style(12, ink, false)), 'Return to the pull request discussion (Esc)')
	if bounds.width > 900 {
		children << ui2.label('repository', app.repo.str(), ui2.rect(margin + 446, 12, math.max(1, width - 446), 30),
			text_style(16, ink, true))
	}
	children << ui2.label('diff_title', 'Diff · PR #${app.active_issue}', ui2.rect(margin, 58, width, 28),
		text_style(20, ink, true))
	summary := if app.diff_loaded {
		'${app.pr_diff.changed_files} files changed · +${app.pr_diff.additions} −${app.pr_diff.deletions}'
	} else if app.diff_loading {
		'Loading changes from GitHub…'
	} else {
		'Use Refresh to try again.'
	}
	children << ui2.label('diff_summary', summary, ui2.rect(margin, 94, width, 24), text_style(12, muted, false))
	mut top := 130.0
	if app.diff_error != '' {
		notice := error_notice('diff_error', 'Diff could not be loaded: ${app.diff_error}', width, top)
		children << ui2.Element{ ...notice, frame: ui2.rect(margin, top, width, notice.frame.height) }
		top += notice.frame.height + 14
	}
	if app.diff_loaded && app.pr_diff.text.trim_space() != '' {
		area := ui2.rich_text_area('pr_diff_${app.active_issue}', app.pr_diff.text, app.pr_diff.runs,
			ui2.rect(margin, top, width, math.max(1, bounds.height - top - 18)),
			bordered_box(0xffffff, 6), diff_text_style())
		children << ui2.Element{ ...area, readonly: true, accessibility_label: 'Pull request diff' }
	} else if app.diff_loaded {
		children << ui2.label('diff_empty', 'No changes in this pull request.', ui2.rect(margin, top, width, 30),
			text_style(13, muted, false))
	}
	return ui2.screen(0xffffff, children)
}
