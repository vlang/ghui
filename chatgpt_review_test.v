module main

import db.sqlite
import os
import time
import ui2

struct ReviewTestEnvironment {
	root     string
	database string
}

fn prepare_review_test() ReviewTestEnvironment {
	root := os.join_path(os.temp_dir(), 'ghui-review-${os.getpid()}-${time.now().unix_nano()}')
	environment := ReviewTestEnvironment{ root: root, database: os.getenv('GHGUI_DB_PATH') }
	os.setenv('GHGUI_DB_PATH', os.join_path(root, 'issues.sqlite3'), true)
	return environment
}

fn (environment ReviewTestEnvironment) close() {
	os.setenv('GHGUI_DB_PATH', environment.database, true)
	os.rmdir_all(environment.root) or {}
}

struct ReviewHistoryVisit {
	id     int
	parent int
	url    string
}

fn write_review_history(path string, visits []ReviewHistoryVisit, wal bool) sqlite.DB {
	os.mkdir_all(os.dir(path)) or { panic(err) }
	mut db := sqlite.connect(path) or { panic(err) }
	if wal {
		db.exec('PRAGMA journal_mode = WAL;') or { panic(err) }
		db.exec('PRAGMA wal_autocheckpoint = 0;') or { panic(err) }
	}
	db.exec('create table moz_places (id integer primary key, url text);') or { panic(err) }
	db.exec('create table moz_historyvisits (id integer primary key, from_visit integer, place_id integer, visit_date integer);') or { panic(err) }
	for visit in visits {
		db.exec_param('insert into moz_places (id, url) values (${visit.id}, ?);', visit.url) or { panic(err) }
		db.exec('insert into moz_historyvisits values (${visit.id}, ${visit.parent}, ${visit.id}, ${visit.id});') or { panic(err) }
	}
	return db
}

fn review_example_app() App {
	return App{
		repo:   Repository{ owner: 'vlang', name: 'v' }
		kind:   .prs
		issues: [
			Issue{ kind: .prs, number: 42, title: 'Review this PR', state: 'OPEN' },
			Issue{ kind: .prs, number: 43, title: 'Another PR', state: 'OPEN' },
		]
	}
}

fn test_review_history_finds_the_newest_review_and_supports_earlier_links() {
	environment := prepare_review_test()
	defer { environment.close() }
	target := 'https://github.com/vlang/v/pull/42'
	prefills := chatgpt_review_prefill_urls(target)
	path := os.join_path(environment.root, 'firefox', 'places.sqlite')
	mut history := write_review_history(path, [
		ReviewHistoryVisit{1, 0, prefills[1]},
		ReviewHistoryVisit{2, 1, 'https://chatgpt.com/'},
		ReviewHistoryVisit{3, 2, 'https://chatgpt.com/c/local-chatgpt%3Aold'},
		ReviewHistoryVisit{4, 3, 'https://chatgpt.com/c/conv-old'},
		ReviewHistoryVisit{10, 0, prefills[0]},
		ReviewHistoryVisit{11, 10, 'https://chatgpt.com/'},
		ReviewHistoryVisit{12, 11, 'https://chatgpt.com/c/local-chatgpt%3Anew'},
		ReviewHistoryVisit{13, 12, 'https://chatgpt.com/c/conv-review?src=history_search#message'},
		// A new conversation opened later in this tab belongs to another task.
		ReviewHistoryVisit{14, 13, 'https://chatgpt.com/'},
		ReviewHistoryVisit{15, 14, 'https://chatgpt.com/c/local-chatgpt%3Aother'},
		ReviewHistoryVisit{16, 15, 'https://chatgpt.com/c/conv-unrelated'},
	], false)
	history.close() or { panic(err) }
	assert (firefox_chatgpt_conversation_url([path], prefills) or { '' }) == 'https://chatgpt.com/c/conv-review'
	assert (firefox_chatgpt_conversation_url([path], [prefills[1]]) or { '' }) == 'https://chatgpt.com/c/conv-old'
	if _ := firefox_chatgpt_conversation_url([path], chatgpt_review_prefill_urls(target.replace('42', '43'))) {
		assert false, 'Another PR inherited this review.'
	}
	assert (os.ls(os.dir(path)) or { panic(err) }) == ['places.sqlite']
}

fn test_unsent_review_does_not_capture_an_existing_or_unrelated_chat() {
	environment := prepare_review_test()
	defer { environment.close() }
	prefills := chatgpt_review_prefill_urls('https://github.com/vlang/v/pull/42')
	path := os.join_path(environment.root, 'firefox', 'places.sqlite')
	mut history := write_review_history(path, [
		ReviewHistoryVisit{1, 0, prefills[0]},
		ReviewHistoryVisit{2, 1, 'https://chatgpt.com/'},
		ReviewHistoryVisit{3, 2, 'https://chatgpt.com/c/conv-existing'},
		ReviewHistoryVisit{4, 2, 'https://example.com/'},
		ReviewHistoryVisit{5, 4, 'https://chatgpt.com/c/local-chatgpt%3Aelsewhere'},
		ReviewHistoryVisit{6, 5, 'https://chatgpt.com/c/conv-elsewhere'},
	], false)
	history.close() or { panic(err) }
	if _ := firefox_chatgpt_conversation_url([path], prefills) {
		assert false
	}
	if _ := chatgpt_conversation_url('https://chatgpt.com/c/local-chatgpt%3Atemporary') {
		assert false
	}
	if _ := chatgpt_conversation_url('https://chatgpt.com/c/') {
		assert false
	}
	if _ := chatgpt_conversation_url('https://example.com/c/other') {
		assert false
	}
	missing := os.join_path(environment.root, 'missing.sqlite')
	if _ := chatgpt_conversation_url_from_history(missing, prefills) {
		assert false
	}
	assert !os.exists(missing)
}

fn test_review_marker_and_chat_survive_restarts_and_history_removal() {
	environment := prepare_review_test()
	defer { environment.close() }
	mut app := review_example_app()
	target := app.issues[0].github_url(app.repo)
	first := app.begin_chatgpt_review(target) or { panic('Review did not start.') }
	assert app.chatgpt_review_marker(app.issues[0]) == ' · ChatGPT review'
	assert app.chatgpt_review_marker(app.issues[1]) == ''
	assert app.chatgpt_review_marker(Issue{ number: 42 }) == ''
	if _ := app.begin_chatgpt_review(target) {
		assert false, 'Pending review was launched twice.'
	}
	unsent := resolve_chatgpt_review(first, []string{})
	store_chatgpt_review(unsent) or { panic(err) }
	app.apply_chatgpt_review_result(ChatgptReviewResult{ review: unsent })
	mut restarted := review_example_app()
	restarted.chatgpt_reviews = load_chatgpt_reviews() or { panic(err) }
	assert restarted.chatgpt_review_marker(restarted.issues[0]) != ''
	second := restarted.begin_chatgpt_review(target) or { panic('Second review was ignored.') }
	path := os.join_path(environment.root, 'firefox', 'places.sqlite')
	// Keep Firefox's connection open: the conversation exists only in its WAL.
	mut history := write_review_history(path, [
		ReviewHistoryVisit{1, 0, chatgpt_review_url(target)},
		ReviewHistoryVisit{2, 1, 'https://chatgpt.com/c/local-chatgpt%3Anew'},
		ReviewHistoryVisit{3, 2, 'https://chatgpt.com/c/conv-42'},
	], true)
	defer { history.close() or {} }
	assert os.exists(path + '-wal')
	before := os.read_bytes(path) or { panic(err) }
	wal_before := os.read_bytes(path + '-wal') or { panic(err) }
	resolved := resolve_chatgpt_review(second, [path])
	assert resolved.conversation_url == 'https://chatgpt.com/c/conv-42'
	assert (os.read_bytes(path) or { panic(err) }) == before
	assert (os.read_bytes(path + '-wal') or { panic(err) }) == wal_before
	store_chatgpt_review(resolved) or { panic(err) }
	restarted.apply_chatgpt_review_result(ChatgptReviewResult{ review: resolved })
	restarted.chatgpt_reviews = load_chatgpt_reviews() or { panic(err) }
	third := restarted.begin_chatgpt_review(target) or { panic('Saved review could not be opened.') }
	assert resolve_chatgpt_review(third, []string{}).conversation_url == resolved.conversation_url
	other := restarted.begin_chatgpt_review(restarted.issues[1].github_url(restarted.repo)) or { panic('Other PR could not be reviewed.') }
	assert other.conversation_url == ''
	ui2.validate_element_tree(render_app(&restarted, ui2.rect(0, 0, 800, 860))) or { panic(err) }
	restarted.open_issue(42)
	ui2.validate_element_tree(render_app(&restarted, ui2.rect(0, 0, 800, 860))) or { panic(err) }
}

fn test_review_shortcut_targets_the_open_selected_or_last_reviewed_pr() {
	mut app := review_example_app()
	if _ := app.chatgpt_review_shortcut_target() {
		assert false
	}
	target := app.issues[0].github_url(app.repo)
	app.begin_chatgpt_review(target) or { panic('Review did not start.') }
	assert (app.chatgpt_review_shortcut_target() or { '' }) == target
	app.toggle_selection(43)
	assert (app.chatgpt_review_shortcut_target() or { '' }).ends_with('/43')
	app.toggle_selection(42)
	if _ := app.chatgpt_review_shortcut_target() {
		assert false
	}
	app.open_issue(42)
	assert (app.chatgpt_review_shortcut_target() or { '' }) == target
	app.change_kind(.issues)
	if _ := app.chatgpt_review_shortcut_target() {
		assert false
	}
	if _ := app.begin_chatgpt_review('https://github.com/vlang/v/issues/42') {
		assert false
	}
	if _ := app.begin_chatgpt_review('https://github.com/elsewhere/repo/pull/42') {
		assert false
	}
}

fn test_saved_review_launches_its_existing_conversation_in_firefox() {
	$if macos {
		environment := prepare_review_test()
		defer { environment.close() }
		bin := os.join_path(environment.root, 'bin')
		os.mkdir_all(bin) or { panic(err) }
		opener := os.join_path(bin, 'open')
		capture := os.join_path(environment.root, 'browser-arguments')
		os.write_file(opener, '#!/bin/sh\nprintf "%s\\n" "$@" > "$GHUI_REVIEW_CAPTURE"\n') or { panic(err) }
		os.chmod(opener, 0o700) or { panic(err) }
		old_path := os.getenv('PATH')
		old_capture := os.getenv('GHUI_REVIEW_CAPTURE')
		os.setenv('PATH', bin + ':' + old_path, true)
		os.setenv('GHUI_REVIEW_CAPTURE', capture, true)
		defer {
			os.setenv('PATH', old_path, true)
			os.setenv('GHUI_REVIEW_CAPTURE', old_capture, true)
		}
		mut app := review_example_app()
		target := app.issues[0].github_url(app.repo)
		saved := ChatgptReview{ key: target, pr_url: target, conversation_url: 'https://chatgpt.com/c/saved-review' }
		store_chatgpt_review(saved) or { panic(err) }
		app.chatgpt_reviews = load_chatgpt_reviews() or { panic(err) }
		request := app.begin_chatgpt_review(target) or { panic('Saved review was ignored.') }
		results := chan ChatgptReviewResult{cap: 1}
		chatgpt_review_in_background(request, results)
		result := <-results
		app.apply_chatgpt_review_result(result)
		assert result.error == '' && result.storage_error == ''
		assert (os.read_file(capture) or { panic(err) }).split_into_lines() == ['-a', 'Firefox',
			saved.conversation_url]
		assert !app.chatgpt_review_pending[target]
		assert app.chatgpt_review_marker(app.issues[0]) != ''
	}
}
