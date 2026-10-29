module main

import db.sqlite
import net.urllib
import os
import time

@[table: 'chatgpt_reviews']
struct ChatgptReview {
	key              string @[primary]
	pr_url           string
	conversation_url string
}

struct ChatgptReviewResult {
	review        ChatgptReview
	error         string
	storage_error string
}

const chatgpt_conversation_url_prefix = 'https://chatgpt.com/c/'
const chatgpt_local_conversation_url_prefix = 'https://chatgpt.com/c/local-chatgpt'

fn chatgpt_review_url(target string) string {
	prompt := 'Review PR ${target}. Ignore CI, Leave comment.'
	// Fusecode uses prompt to fill the composer without sending. Spell spaces
	// as %20 so they cannot appear as literal plus signs in the composer.
	return 'https://chatgpt.com/?prompt=${urllib.query_escape(prompt).replace('+', '%20')}'
}

fn chatgpt_review_prefill_urls(target string) []string {
	prompt := 'Review PR ${target}. Ignore CI, Leave comment.'
	// Also find chats opened by ghui's original q-based review action.
	return [chatgpt_review_url(target),
		'https://chatgpt.com/?q=${urllib.query_escape(prompt)}&submit=false']
}

fn (app &App) chatgpt_review_marker(issue Issue) string {
	if issue.kind == .prs && issue.github_url(app.repo).to_lower() in app.chatgpt_reviews {
		return ' · ChatGPT review'
	}
	return ''
}

fn (app &App) chatgpt_review_shortcut_target() ?string {
	if app.kind != .prs { return none }
	if app.active_issue > 0 { return app.detail.issue.github_url(app.repo) }
	selected := app.visible_issues().filter(app.selected[it.number] or { false })
	if selected.len == 1 { return selected[0].github_url(app.repo) }
	if selected.len > 1 { return none }
	if app.last_review_pr != '' { return app.last_review_pr }
	return none
}

fn (mut app App) begin_chatgpt_review(target string) ?ChatgptReview {
	reference := local_discussion_reference(target, app.repo)?
	if reference.kind != .prs { return none }
	key := target.to_lower()
	if app.chatgpt_review_pending[key] or { false } { return none }
	review := app.chatgpt_reviews[key] or { ChatgptReview{ key: key, pr_url: target } }
	app.chatgpt_reviews[key] = review
	app.chatgpt_review_pending[key] = true
	app.last_review_pr = target
	app.chatgpt_review_error = ''
	return review
}

fn (mut app App) apply_chatgpt_review_result(result ChatgptReviewResult) {
	app.chatgpt_review_pending.delete(result.review.key)
	app.chatgpt_reviews[result.review.key] = result.review
	app.chatgpt_review_error = result.error
	if result.storage_error != '' { app.storage_error = result.storage_error }
}

fn chatgpt_review_in_background(review ChatgptReview, results chan ChatgptReviewResult) {
	resolved := resolve_chatgpt_review(review, firefox_history_paths())
	mut storage_error := ''
	store_chatgpt_review(resolved) or { storage_error = err.msg() }
	target := if resolved.conversation_url != '' {
		resolved.conversation_url
	} else {
		chatgpt_review_url(resolved.pr_url)
	}
	mut launch_error := ''
	open_review_url_in_firefox(target) or { launch_error = err.msg() }
	results <- ChatgptReviewResult{ review: resolved, error: launch_error, storage_error: storage_error }
	wake_ui()
}

fn resolve_chatgpt_review(review ChatgptReview, history_paths []string) ChatgptReview {
	if review.conversation_url != '' { return review }
	if conversation := firefox_chatgpt_conversation_url(history_paths, chatgpt_review_prefill_urls(review.pr_url)) {
		return ChatgptReview{ ...review, conversation_url: conversation }
	}
	return review
}

fn load_chatgpt_reviews() !map[string]ChatgptReview {
	mut db := open_issue_database()!
	defer { db.close() or {} }
	rows := sql db { select from ChatgptReview }!
	mut reviews := map[string]ChatgptReview{}
	for review in rows { reviews[review.key] = review }
	return reviews
}

fn store_chatgpt_review(review ChatgptReview) ! {
	mut db := open_issue_database()!
	defer { db.close() or {} }
	sql db { upsert review into ChatgptReview }!
}

fn firefox_history_paths() []string {
	root := $if macos {
		os.join_path(os.home_dir(), 'Library', 'Application Support', 'Firefox', 'Profiles')
	} $else $if windows {
		os.join_path(os.getenv('APPDATA'), 'Mozilla', 'Firefox', 'Profiles')
	} $else {
		os.join_path(os.home_dir(), '.mozilla', 'firefox')
	}
	entries := os.ls(root) or { return []string{} }
	mut paths := []string{}
	for entry in entries {
		path := os.join_path(root, entry, 'places.sqlite')
		if os.is_file(path) { paths << path }
	}
	paths.sort_with_compare(fn (a &string, b &string) int {
		a_time := firefox_history_last_write(*a)
		b_time := firefox_history_last_write(*b)
		return if a_time > b_time {
			-1
		} else if a_time < b_time {
			1
		} else {
			0
		}
	})
	return paths
}

fn firefox_history_last_write(path string) i64 {
	wal_time := if os.exists(path + '-wal') { os.file_last_mod_unix(path + '-wal') } else { i64(0) }
	db_time := os.file_last_mod_unix(path)
	return if wal_time > db_time { wal_time } else { db_time }
}

// Ported from Fusecode: query a private snapshot, including uncheckpointed
// visits, so the running browser's history is never modified.
fn firefox_chatgpt_conversation_url(history_paths []string, prefill_urls []string) ?string {
	for history_path in history_paths {
		dir := os.join_path(os.temp_dir(), 'ghui-firefox-history-${os.getpid()}-${time.now().unix_nano()}')
		os.mkdir(dir, mode: 0o700) or { continue }
		snapshot := os.join_path(dir, 'places.sqlite')
		os.cp(history_path, snapshot) or {
			os.rmdir_all(dir) or {}
			continue
		}
		for suffix in ['-wal', '-journal'] {
			if os.exists(history_path + suffix) {
				os.cp(history_path + suffix, snapshot + suffix) or {}
			}
		}
		found := chatgpt_conversation_url_from_history(snapshot, prefill_urls)
		os.rmdir_all(dir) or {}
		if conversation := found { return conversation }
	}
	return none
}

// Require the temporary local-chatgpt visit before the server conversation.
// Opening an older chat from the sidebar must not assign an unrelated review.
fn chatgpt_conversation_url_from_history(history_path string, prefill_urls []string) ?string {
	if prefill_urls.len == 0 || !os.is_file(history_path) { return none }
	mut db := sqlite.connect(history_path) or { return none }
	defer { db.close() or {} }
	db.exec("create temp table site as
		select v.id as id, v.from_visit as parent, p.url as url, v.visit_date as visited
		from moz_places p join moz_historyvisits v on v.place_id = p.id
		where p.url like 'https://chatgpt.com/%';") or { return none }
	db.exec('create index temp.site_parent on site(parent);') or { return none }
	placeholders := prefill_urls.map('?').join(', ')
	rows := db.exec_param_many("with recursive chain(id, depth, url) as (
		select id, 0, url from site where url in (${placeholders})
		union all
		select s.id, c.depth + 1, s.url from chain c join site s on s.parent = c.id
		where c.depth < 4 and c.url not like '${chatgpt_conversation_url_prefix}%'
	)
	select s.url from chain c join site s on s.parent = c.id
	where c.url like '${chatgpt_local_conversation_url_prefix}%'
		and s.url like '${chatgpt_conversation_url_prefix}%'
		and s.url not like '${chatgpt_local_conversation_url_prefix}%'
	order by s.visited desc limit 1;", prefill_urls) or { return none }
	if rows.len == 0 || rows[0].vals.len == 0 { return none }
	return chatgpt_conversation_url(rows[0].vals[0])
}

fn chatgpt_conversation_url(raw_url string) ?string {
	if !raw_url.starts_with(chatgpt_conversation_url_prefix)
		|| raw_url.starts_with(chatgpt_local_conversation_url_prefix) {
		return none
	}
	id := raw_url[chatgpt_conversation_url_prefix.len..].all_before('?').all_before('#').all_before('/')
	if id == '' { return none }
	return chatgpt_conversation_url_prefix + id
}

fn open_review_url_in_firefox(url string) ! {
	opener := os.find_abs_path_of_executable($if macos { 'open' } $else { 'firefox' }) or {
		return error('Could not open ChatGPT in Firefox: ${err}')
	}
	mut process := os.new_process(opener)
	// Pass the URL directly as an argument so prompt text cannot become shell code.
	process.set_args($if macos { ['-a', 'Firefox', url] } $else { ['--new-tab', url] })
	process.run()
	$if macos {
		process.wait()
		defer { process.close() }
		if process.code != 0 {
			return error('Could not open ChatGPT in Firefox. Make sure Firefox is installed.')
		}
	} $else {
		if process.status != .running {
			process.close()
			return error('Could not start Firefox: ${process.err}')
		}
		// A newly launched Firefox may stay alive until the user closes it.
		spawn wait_for_review_browser(mut process)
	}
}

fn wait_for_review_browser(mut process os.Process) {
	process.wait()
	process.close()
}
