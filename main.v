module main

import clipboard
import os
import ui2

fn usage() string {
	return 'Usage: ./ghgui OWNER/REPO|GITHUB_URL [--prs] [--check]\n\n  ./ghgui vlang/v                Open issues and pull requests\n  ./ghgui vlang/v --prs          Start with pull requests\n  ./ghgui https://github.com/vlang/v/pull/42\n  ./ghgui vlang/v --check        Fetch one page and print a summary\n\nRequires GitHub CLI (gh). Authenticate with gh auth login.'
}

fn main() {
	if os.args.len == 3 && os.args[1] == '--can-open' {
		parse_github_destination(os.args[2]) or { exit(1) }
		return
	}
	if os.args.len == 2 && os.args[1] in ['--help', '-h'] {
		println(usage())
		return
	}
	if os.args.len < 2 || os.args.len > 4 || os.args[2..].any(it !in ['--check', '--prs']) {
		eprintln(usage())
		exit(1)
	}
	destination := if os.args[1].contains('://') {
		parse_github_destination(os.args[1]) or { eprintln(err.msg()) exit(1) }
	} else {
		GithubDestination{ repo: parse_repository(os.args[1]) or { eprintln(err.msg()) exit(1) },
			kind: if '--prs' in os.args { ItemKind.prs } else { ItemKind.issues } }
	}
	repo := destination.repo
	kind := destination.kind
	if '--check' in os.args {
		request := FetchRequest{ kind: kind, repo: repo, state: 'OPEN', sort: 'Newest' }
		page := fetch_issues(request) or {
			eprintln(err.msg())
			exit(1)
		}
		store_issue_page(request, page, true) or {
			eprintln('Could not save ${kind.label()} locally: ${err}')
		}
		println('${repo}: ${page.open_count} open · ${page.closed_count} closed · ${page.issues.len} ${kind.label()} loaded')
		for issue in page.issues { println('#${issue.number} ${issue.title}') }
		return
	}
	mut app := unsafe { app_state }
	app.repo = repo
	app.kind = kind
	app.chatgpt_reviews = load_chatgpt_reviews() or {
		app.storage_error = 'Could not load saved ChatGPT reviews: ${err}'
		map[string]ChatgptReview{}
	}
	ui2.on_key(handle_key)
	ui2.on_key_event(handle_open_pr_key)
	install_app_menu()
	$if macos { install_macos_url_handler() }
	app.startup_url = if destination.number > 0 { os.args[1] } else { '' }
	ui2.run_window('GitHub · ${repo}', 1440, 860, build, handle_event)
}

fn install_app_menu() {
	ui2.set_menu_bar([
		ui2.Menu{
			title: 'File'
			items: [ui2.menu_item_with_shortcut('show_open_pr', 'Open pull request…', 'cmd+g')]
		},
	])
}

fn wake_ui() {
	ui2.request_refresh()
}

fn start_fetch(append_page bool) {
	mut app := unsafe { app_state }
	if append_page && (app.loading || !app.has_next) { return }
	request := app.begin_fetch(append_page)
	spawn fetch_in_background(request, app.results)
}

fn start_detail_fetch(append_page bool) {
	mut app := unsafe { app_state }
	if app.active_issue == 0 { return }
	if app.merging_current_pr() || app.closing_current_issue() || app.closing_current_pr() { return }
	if append_page && (app.detail_loading || !app.detail.has_next) { return }
	request := app.begin_detail_fetch(append_page)
	spawn fetch_detail_in_background(request, app.detail_results)
}

fn open_issue_in_gui(number int) {
	if number <= 0 { return }
	mut app := unsafe { app_state }
	if app.active_issue == 0 { app.list_scroll = ui2.scroll_offset(app.list_scroll_id()) }
	app.open_issue(number)
	ui2.scroll_to_offset(app.detail_scroll_id(), 0)
	start_detail_fetch(false)
}

fn open_reference_in_gui(number int, kind ItemKind) {
	mut app := unsafe { app_state }
	if kind != app.kind {
		app.change_kind(kind)
		start_fetch(false)
	}
	open_issue_in_gui(number)
}

fn handle_discussion_link(target string) {
	mut app := unsafe { app_state }
	app.cancel_reference()
	if reference := local_discussion_reference(target, app.repo) {
		if !reference.needs_lookup {
			open_reference_in_gui(reference.number, reference.kind)
		} else if kind := app.known_reference_kind(reference.number) {
			open_reference_in_gui(reference.number, kind)
		} else {
			request := app.begin_reference(reference.number)
			spawn resolve_reference_in_background(request, app.reference_results)
		}
	} else if destination := parse_github_destination(target) {
		open_github_destination(destination)
	} else {
		open_discussion_url(target) or {
			app.reference_error = err.msg()
		}
	}
}

fn close_issue_in_gui() {
	mut app := unsafe { app_state }
	if app.active_issue == 0 { return }
	app.close_issue()
	ui2.scroll_to_offset(app.list_scroll_id(), app.list_scroll)
}

fn start_chatgpt_review(target string) {
	mut app := unsafe { app_state }
	if review := app.begin_chatgpt_review(target) {
		spawn chatgpt_review_in_background(review, app.chatgpt_review_results)
	}
}

fn start_diff_fetch() {
	mut app := unsafe { app_state }
	if request := app.begin_diff_fetch() {
		spawn fetch_diff_in_background(request, app.diff_results)
	}
}

fn build() ui2.Element {
	mut app := unsafe { app_state }
	if !app.initialized {
		app.initialized = true
		start_fetch(false)
		if app.startup_url != '' {
			target := app.startup_url
			app.startup_url = ''
			handle_open_url(target)
		}
	}
	for {
		select {
			search_result := <-app.search_results {
				if app.apply_search_result(search_result) && app.active_issue == 0 {
					ui2.scroll_to_offset(app.list_scroll_id(), 0)
				}
			}
			result := <-app.results {
				app.apply_result(result)
			}
			detail_result := <-app.detail_results {
				app.apply_detail_result(detail_result)
			}
			diff_result := <-app.diff_results {
				app.apply_diff_result(diff_result)
			}
			close_result := <-app.close_results {
				if app.apply_close_issue_result(close_result) && app.kind == .issues {
					start_fetch(false)
					if app.active_issue == close_result.request.issue.number { start_detail_fetch(false) }
				}
			}
			merge_result := <-app.merge_results {
				if app.apply_merge_result(merge_result) && app.kind == .prs {
					start_fetch(false)
					if app.active_issue == merge_result.request.issue.number { start_detail_fetch(false) }
				}
			}
			close_pr_result := <-app.close_pr_results {
				if app.apply_close_pr_result(close_pr_result) && app.kind == .prs {
					start_fetch(false)
					if app.active_issue == close_pr_result.request.issue.number { start_detail_fetch(false) }
				}
			}
			ready_result := <-app.ready_results {
				if app.apply_ready_result(ready_result) && app.kind == .prs {
					start_fetch(false)
					if app.active_issue == ready_result.request.issue.number { start_detail_fetch(false) }
				}
			}
			comment_result := <-app.comment_results {
				app.apply_comment_result(comment_result)
			}
			chatgpt_review_result := <-app.chatgpt_review_results {
				app.apply_chatgpt_review_result(chatgpt_review_result)
			}
			reference_result := <-app.reference_results {
				if issue := app.apply_reference_result(reference_result) {
					open_reference_in_gui(issue.number, issue.kind)
				}
			}
			else {
				break
			}
		}
	}
	if app.pending_url_diff && app.active_issue > 0 && app.detail_loaded && !app.detail_loading {
		app.pending_url_diff = false
		start_diff_fetch()
	}
	// Use the normal navigation and fetch path for native detail screenshots.
	if !app.loading && app.loaded_state != '' && !app.screenshot_detail_started
		&& os.getenv('GHGUI_SCREENSHOT_ISSUE').int() > 0 {
		app.screenshot_detail_started = true
		open_issue_in_gui(os.getenv('GHGUI_SCREENSHOT_ISSUE').int())
	}
	if app.active_issue > 0 && app.detail_loaded && !app.screenshot_diff_started
		&& os.getenv('GHGUI_SCREENSHOT_DIFF') == '1' {
		app.screenshot_diff_started = true
		start_diff_fetch()
	}
	ready := if app.diff_visible { !app.diff_loading } else if app.active_issue > 0 { !app.detail_loading } else { !app.loading }
	if ready && os.getenv('GHGUI_SCREENSHOT_PATH') != '' {
		if !app.diff_visible && app.active_issue > 0 && app.detail_loaded && os.getenv('GHGUI_SCREENSHOT_COMMENTS') == '1' {
			// Mount the complete discussion before scrolling its native viewport.
			if !app.screenshot_comments_ready {
				app.screenshot_comments_ready = true
				ui2.request_refresh()
				return render_app(app, ui2.bounds())
			}
			layout := detail_layout(app, ui2.bounds())
			ui2.scroll_to_offset(app.detail_scroll_id(), layout.comments_y)
		}
		os.setenv('UI2_SCREENSHOT_PATH', os.getenv('GHGUI_SCREENSHOT_PATH'), true)
		os.setenv('UI2_EXIT_AFTER_SCREENSHOT', '1', true)
	}
	// A cancelled edit may never have rendered, so also reset its native text.
	if app.active_issue == 0 && ui2.text('search') != app.search_text() {
		ui2.set_text('search', app.search_text())
	}
	return render_app(app, ui2.bounds())
}

fn handle_key(key string) {
	if app_state.open_pr_visible {
		match key {
			'cmd+g', 'ctrl+g' { ui2.focus('open_pr_number') }
			'escape', 'alt+left', 'cmd+[' { handle_event('cancel_open_pr') }
			else {}
		}
		return
	}
	match key {
		'cmd+g', 'ctrl+g' {
			ui2.consume_key()
			handle_event('show_open_pr')
		}
		'cmd+r', 'ctrl+r', 'f5' { handle_event('refresh') }
		'cmd+shift+r', 'ctrl+shift+r' {
			ui2.consume_key()
			handle_event('review_on_chatgpt')
		}
		'cmd+f', 'ctrl+f' {
			if app_state.active_issue == 0 { ui2.focus('search') }
		}
		'escape', 'alt+left', 'cmd+[' { handle_event('back') }
		'cmd+enter', 'ctrl+enter' {
			if ui2.focused_id() == 'new_comment_text' { handle_event('add_comment') }
		}
		else {}
	}
}

fn handle_event(event string) {
	mut app := unsafe { app_state }
	match event {
		'show_open_pr' {
			app.show_open_pr_dialog(ui2.focused_id())
			ui2.refresh()
			ui2.focus('open_pr_number')
			return
		}
		'cancel_open_pr' {
			if !app.open_pr_visible { return }
			previous_focus := app.open_pr_previous_focus
			app.close_open_pr_dialog()
			ui2.refresh()
			ui2.focus(previous_focus)
			return
		}
		'open_pr_number' {
			app.open_pr_text = ui2.text('open_pr_number')
			if app.open_pr_error != '' {
				app.open_pr_error = ''
				ui2.request_refresh()
			}
			return
		}
		'submit_open_pr' {
			if destination := app.submit_open_pr(ui2.text('open_pr_number')) {
				open_reference_in_gui(destination.number, destination.kind)
			} else {
				ui2.refresh()
				ui2.focus('open_pr_number')
				return
			}
		}
		'mode_issues', 'mode_prs' {
			kind := if event == 'mode_prs' { ItemKind.prs } else { ItemKind.issues }
			if kind != app.kind {
				app.change_kind(kind)
				ui2.scroll_to_offset(app.list_scroll_id(), 0)
				start_fetch(false)
			} else {
				close_issue_in_gui()
			}
		}
		'refresh' {
			if app.diff_visible {
				start_diff_fetch()
			} else if app.active_issue > 0 {
				if !app.detail_loading { start_detail_fetch(false) }
			} else if !app.loading {
				start_fetch(false)
			}
		}
		'back' {
			if app.open_pr_visible {
				handle_event('cancel_open_pr')
				return
			} else if app.diff_visible {
				app.close_diff()
				ui2.scroll_to_offset(app.detail_scroll_id(), app.diff_discussion_scroll)
			} else {
				close_issue_in_gui()
			}
		}
		'view_diff' {
			if !app.diff_visible { app.diff_discussion_scroll = ui2.scroll_offset(app.detail_scroll_id()) }
			start_diff_fetch()
		}
		'review_on_chatgpt' {
			if target := app.chatgpt_review_shortcut_target() { start_chatgpt_review(target) }
		}
		'load_more_comments' { start_detail_fetch(true) }
		'close_issue' {
			if request := app.begin_close_issue() {
				spawn close_issue_in_background(request, app.close_results)
			}
		}
		'squash_merge' {
			if request := app.begin_squash_merge() {
				spawn squash_merge_in_background(request, app.merge_results)
			}
		}
		'close_pr' {
			if request := app.begin_close_pr() {
				spawn close_pr_in_background(request, app.close_pr_results)
			}
		}
		'mark_ready' {
			if request := app.begin_mark_ready() {
				spawn mark_ready_in_background(request, app.ready_results)
			}
		}
		'new_comment_text' {
			// Only the Comment button depends on the draft, so typing does not
			// redraw the whole discussion.
			if !app.set_comment_draft(ui2.text('new_comment_text')) { return }
		}
		'add_comment' {
			if request := app.begin_add_comment() {
				spawn add_comment_in_background(request, app.comment_results)
			}
		}
		'jump_comments' {
			if app.active_issue > 0 {
				layout := detail_layout(app, ui2.bounds())
				ui2.scroll_to_offset(app.detail_scroll_id(), layout.comments_y)
			}
		}
		'open', 'closed' {
			state := if event == 'open' { 'OPEN' } else { 'CLOSED' }
			if state != app.state {
				app.change_state(state)
				start_fetch(false)
			}
		}
		'search' {
			if request := app.begin_search(ui2.text('search')) {
				spawn search_in_background(request, app.search_results)
			}
			// Never rebuild the list inside the native text-change callback.
			return
		}
		'author' { app.author = ui2.text('author') }
		'label' { app.label = ui2.text('label') }
		'assignee' { app.assignee = ui2.text('assignee') }
		'milestone' { app.milestone = ui2.text('milestone') }
		'sort' {
			value := ui2.text('sort')
			if value != app.sort {
				app.change_sort(value)
				ui2.scroll_to_offset(app.list_scroll_id(), 0)
			}
		}
		'load_more' { start_fetch(true) }
		'clear_filters' {
			app.clear_filters()
			ui2.scroll_to_offset(app.list_scroll_id(), 0)
		}
		'select_all' { app.toggle_all() }
		'comfortable' { app.compact = false }
		'compact' { app.compact = true }
		else {
			if target := discussion_event_link(event) {
				handle_discussion_link(target)
			} else if event.starts_with('copy_github_url:') {
				if isnil(app.system_clipboard) { app.system_clipboard = clipboard.new() }
				if !app.system_clipboard.copy(event.all_after('copy_github_url:')) {
					eprintln('Could not copy the GitHub URL to the clipboard.')
				}
			} else if event.starts_with('review_on_chatgpt:') {
				start_chatgpt_review(event.all_after('review_on_chatgpt:'))
			} else if event.starts_with('select_') {
				app.toggle_selection(event.all_after('select_').int())
			} else if event.starts_with('pointer:up:issue_') {
				open_issue_in_gui(event.split(':')[2].all_after('issue_').int())
			}
		}
	}
	ui2.refresh()
}
