module main

import net.urllib
import ui2
import os

struct GithubDestination {
	repo         Repository
	kind         ItemKind
	number       int
	needs_lookup bool
	diff         bool
}

// Keep unsupported pages in the browser rather than losing their destination.
fn parse_github_destination(target string) !GithubDestination {
	url := urllib.parse(target)!
	user := url.user or { urllib.Userinfo{} }
	if url.scheme !in ['http', 'https', 'ghui'] || url.host.to_lower() !in [
		'github.com',
		'www.github.com',
	]
		|| user.username != '' || user.password_set {
		return error('Expected a GitHub repository, issue, or pull request URL.')
	}
	// Preserve anchors and list filters that ghui cannot represent yet.
	if url.fragment != '' { return error('This GitHub anchor opens in your browser.') }
	parts := url.path.trim('/').split('/')
	if parts.len < 2 { return error('This GitHub page is not supported by ghui.') }
	if parts.len <= 3 && url.raw_query != '' {
		return error('This GitHub list filter opens in your browser.')
	}
	repo := parse_repository('${parts[0]}/${parts[1]}')!
	if parts.len == 2 { return GithubDestination{ repo: repo } }
	if parts[2] !in ['issues', 'pull', 'pulls'] {
		return error('This GitHub page is not supported by ghui.')
	}
	kind := if parts[2] == 'issues' { ItemKind.issues } else { ItemKind.prs }
	if parts.len == 3 { return GithubDestination{ repo: repo, kind: kind } }
	number := parts[3]
	if number == '' || !number.bytes().all(it.is_digit()) || number.len > 10
		|| (number.len == 10 && number > '2147483647') || number.int() <= 0 {
		return error('Invalid GitHub issue or pull request number.')
	}
	if parts[2] == 'pulls' || parts.len > 5
		|| (parts.len == 5 && (kind != .prs || parts[4] != 'files')) {
		return error('This GitHub page is not supported by ghui.')
	}
	return GithubDestination{
		repo:         repo
		kind:         kind
		number:       number.int()
		needs_lookup: kind == .issues
		diff:         parts.len == 5
	}
}

fn (mut app App) change_repository(repo Repository) bool {
	if app.repo.str().to_lower() == repo.str().to_lower() { return false }
	app.repository_drafts[app.repo.str().to_lower()] = app.comment_drafts.clone()
	app.close_issue()
	if !isnil(app.list_cancel) { app.list_cancel.stop() }
	app.generation++
	app.repo = repo
	app.list_cache.clear()
	app.detail_cache.clear()
	app.issues.clear()
	app.selected.clear()
	app.comment_drafts = (app.repository_drafts[repo.str().to_lower()] or { map[int]string{} }).clone()
	app.comment_errors.clear()
	app.close_errors.clear()
	app.close_pr_errors.clear()
	app.merge_errors.clear()
	app.ready_errors.clear()
	app.comment_generation++
	app.comment_loading = false
	app.close_generation++
	app.close_loading = false
	app.close_pr_generation++
	app.close_pr_loading = false
	app.merge_generation++
	app.merge_loading = false
	app.ready_generation++
	app.ready_loading = false
	app.loading = false
	app.list_cached = false
	app.list_received = false
	app.open_count = 0
	app.closed_count = 0
	app.updated = ''
	app.storage_error = ''
	app.list_scroll = 0
	app.change_state('OPEN')
	return true
}

fn open_github_destination(destination GithubDestination) {
	mut app := unsafe { app_state }
	changed := app.change_repository(destination.repo)
	old_kind := app.kind
	app.change_kind(destination.kind)
	app.close_issue()
	ui2.set_window_title('GitHub · ${app.repo}')
	if changed || old_kind != app.kind { start_fetch(false) }
	if destination.number > 0 {
		if destination.needs_lookup {
			if kind := app.known_reference_kind(destination.number) {
				open_reference_in_gui(destination.number, kind)
			} else {
				request := app.begin_reference(destination.number)
				spawn resolve_reference_in_background(request, app.reference_results)
			}
		} else {
			open_reference_in_gui(destination.number, destination.kind)
		}
	} else {
		ui2.scroll_to_offset(app.list_scroll_id(), 0)
	}
	app.pending_url_diff = destination.diff
	wake_ui()
}

fn handle_open_url(target string) {
	destination := parse_github_destination(target) or {
		open_browser_url(target) or { eprintln(err) }
		return
	}
	open_github_destination(destination)
}

fn open_browser_url(target string) ! {
	$if macos {
		if !C.ghui_open_browser(target.str) {
			return error('Could not open the link in your browser.')
		}
	} $else {
		os.open_uri(target)!
	}
}
