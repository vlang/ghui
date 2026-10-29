module main

import os
import time
import ui2

const sample_pr_diff = 'diff --git a/example.v b/example.v\nindex abc..def 100644\n--- a/example.v\n+++ b/example.v\n@@ -1,3 +1,3 @@\n context\n-old value\n+Привет **literal** #42\n+++added prefix\n\\ No newline at end of file\ndiff --git a/old name.txt b/new name.txt\nsimilarity index 100%\nrename from old name.txt\nrename to new name.txt\ndiff --git a/image.png b/image.png\nindex abc..def 100644\nBinary files a/image.png and b/image.png differ\n'

fn diff_example_app() App {
	mut app := App{
		kind:   .prs
		repo:   Repository{ owner: 'alice', name: 'project' }
		issues: [Issue{ kind: .prs, number: 42, title: 'A pull request', state: 'OPEN' }]
	}
	app.open_issue(42)
	return app
}

fn test_diff_preserves_code_whitespace_and_distinguishes_headers_from_changes() {
	diff := decode_pull_request_diff(sample_pr_diff) or { panic(err) }
	assert diff.text == sample_pr_diff
	assert diff.runs.map(it.text).join('') == sample_pr_diff
	assert diff.changed_files == 3 && diff.additions == 2 && diff.deletions == 1
	assert diff.runs.filter(it.text == '+++ b/example.v\n')[0].style.color == muted
	assert diff.runs.filter(it.text == '+++added prefix\n')[0].style.color == green
	assert diff.runs.filter(it.text == '-old value\n')[0].style.color == red
	assert diff.runs.filter(it.text.starts_with('@@'))[0].style.color == blue
	assert diff.runs.filter(it.text.contains('**literal**'))[0].style.link == ''
	assert diff.runs.any(it.text.starts_with('Binary files'))
	whitespace := 'diff --git a/space b/space\n--- a/space\n+++ b/space\n@@ -0,0 +1 @@\n+ \t  \n'
	assert (decode_pull_request_diff(whitespace) or { panic(err) }).runs.map(it.text).join('') == whitespace
	assert (decode_pull_request_diff('') or { panic(err) }).changed_files == 0
	if _ := decode_pull_request_diff('{"message":"Not Found"}') {
		assert false, 'Unexpected GitHub output should not be presented as a diff.'
	}
}

fn test_diff_navigation_cancels_reads_and_discards_stale_results() {
	mut app := diff_example_app()
	description := app.detail
	request := app.begin_diff_fetch() or { panic('Diff did not start.') }
	assert app.diff_visible && app.diff_loading
	assert app.begin_diff_fetch() == none
	app.close_diff()
	assert cancelled(request.cancel) && !app.diff_visible && !app.diff_loading
	assert app.active_issue == 42 && app.detail == description
	reopened := app.begin_diff_fetch() or { panic('Diff did not reopen.') }
	diff := decode_pull_request_diff(sample_pr_diff) or { panic(err) }
	app.apply_diff_result(DiffResult{ request: request, diff: diff })
	assert app.diff_loading && !app.diff_loaded
	app.apply_diff_result(DiffResult{ request: reopened, diff: diff })
	assert app.diff_loaded && !app.diff_loading
	assert app.pr_diff.text == sample_pr_diff
	refresh := app.begin_diff_fetch() or { panic('Refresh did not start.') }
	app.open_issue(43)
	assert cancelled(refresh.cancel) && !app.diff_visible
	app.apply_diff_result(DiffResult{ request: refresh, diff: diff })
	assert app.active_issue == 43 && !app.diff_visible
	other := app.begin_diff_fetch() or { panic('Other PR diff did not start.') }
	assert !app.diff_loaded && app.pr_diff.text == ''
	app.change_kind(.issues)
	assert cancelled(other.cancel) && !app.diff_visible && app.active_issue == 0
	assert app.begin_diff_fetch() == none
}

fn test_failed_diff_refresh_retains_previous_changes_and_can_retry() {
	mut app := diff_example_app()
	request := app.begin_diff_fetch() or { panic('Diff did not start.') }
	diff := decode_pull_request_diff(sample_pr_diff) or { panic(err) }
	app.apply_diff_result(DiffResult{ request: request, error: 'gh: Forbidden (HTTP 403)' })
	assert !app.diff_loading && !app.diff_loaded && app.diff_error.contains('HTTP 403')
	retry := app.begin_diff_fetch() or { panic('Retry did not start.') }
	app.apply_diff_result(DiffResult{ request: retry, diff: diff })
	assert app.diff_loaded && app.diff_error == ''
	refresh := app.begin_diff_fetch() or { panic('Refresh did not start.') }
	app.apply_diff_result(DiffResult{ request: refresh, error: 'Network unavailable' })
	assert app.diff_loaded && app.pr_diff.text == sample_pr_diff
	assert app.diff_error == 'Network unavailable'
	for width in [800.0, 1440.0] {
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
	}
	empty := app.begin_diff_fetch() or { panic('Retry did not start.') }
	app.apply_diff_result(DiffResult{ request: empty, diff: decode_pull_request_diff('') or { panic(err) } })
	assert app.pr_diff.text == '' && app.diff_error == ''
	assert render_app(&app, ui2.rect(0, 0, 800, 860)).children.any(it.id == 'diff_empty')
}

fn test_diff_is_available_for_all_pr_states_and_renders_selectable_literal_code() {
	for state in ['OPEN', 'CLOSED', 'MERGED'] {
		for draft in [false, true] {
			mut app := diff_example_app()
			app.detail = IssueDetail{ issue: Issue{ ...app.detail.issue, state: state, is_draft: draft } }
			layout := detail_layout(&app, ui2.rect(0, 0, 800, 860))
			assert layout.content.children.any(it.id == 'view_diff')
			request := app.begin_diff_fetch() or { panic('Diff did not start.') }
			for width in [800.0, 1440.0] {
				ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
			}
			app.apply_diff_result(DiffResult{
				request: request
				diff:    decode_pull_request_diff(sample_pr_diff) or { panic(err) }
			})
			for width in [800.0, 1440.0] {
				screen := render_app(&app, ui2.rect(0, 0, width, 860))
				ui2.validate_element_tree(screen) or { panic(err) }
				area := screen.children.filter(it.id == 'pr_diff_42')[0]
				assert area.readonly && area.enabled && !area.disable_scroll
				assert area.text == sample_pr_diff
				assert area.text_runs.map(it.text).join('') == area.text
			}
		}
	}
	mut issue := App{}
	issue.open_issue(42)
	assert !detail_layout(&issue, ui2.rect(0, 0, 800, 860)).content.children.any(it.id == 'view_diff')
	assert issue.begin_diff_fetch() == none
}

fn test_diff_fetch_uses_explicit_repository_preserves_whitespace_and_reports_errors() {
	$if windows {
		return
	}
	root := os.join_path(os.temp_dir(), 'ghgui-diff-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(os.join_path(root, 'bin')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	old_path := os.getenv('PATH')
	old_root := os.getenv('FAKE_DIFF_ROOT')
	defer {
		os.setenv('PATH', old_path, true)
		os.setenv('FAKE_DIFF_ROOT', old_root, true)
	}
	os.setenv('PATH', '${os.join_path(root, 'bin')}:${old_path}', true)
	os.setenv('FAKE_DIFF_ROOT', root, true)
	script := r'#!/bin/sh
set -eu
printf "%s\n" "$@" > "$FAKE_DIFF_ROOT/args"
if [ -f "$FAKE_DIFF_ROOT/fail" ]; then
  printf "gh: Diff unavailable (HTTP 502)\n" >&2
  exit 1
fi
cat "$FAKE_DIFF_ROOT/response"
'
	os.write_file(os.join_path(root, 'bin', 'gh'), script) or { panic(err) }
	os.chmod(os.join_path(root, 'bin', 'gh'), 0o700) or { panic(err) }
	source := sample_pr_diff + 'diff --git a/spaces b/spaces\n--- a/spaces\n+++ b/spaces\n@@ -0,0 +1 @@\n+ \t  \n'
	os.write_file(os.join_path(root, 'response'), source) or { panic(err) }
	mut app := diff_example_app()
	request := app.begin_diff_fetch() or { panic('Diff did not start.') }
	worker := spawn fetch_diff_in_background(request, app.diff_results)
	worker.wait()
	result := <-app.diff_results
	assert result.error == '' && result.diff.text == source
	assert (os.read_file(os.join_path(root, 'args')) or { panic(err) }).split_into_lines() ==
		['pr', 'diff', '42', '--repo', 'github.com/alice/project', '--color', 'never']
	app.apply_diff_result(result)
	os.write_file(os.join_path(root, 'fail'), '') or { panic(err) }
	refresh := app.begin_diff_fetch() or { panic('Refresh did not start.') }
	failed_worker := spawn fetch_diff_in_background(refresh, app.diff_results)
	failed_worker.wait()
	failed := <-app.diff_results
	assert failed.error.contains('HTTP 502')
	app.apply_diff_result(failed)
	assert app.pr_diff.text == source && app.diff_error.contains('HTTP 502')
	app.close_issue()
	assert cancelled(refresh.cancel) && !app.diff_visible
}
