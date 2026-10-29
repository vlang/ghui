module main

import db.sqlite
import json2
import os
import time

struct StoreTestEnvironment {
	root     string
	database string
	cache    string
	disabled string
}

fn prepare_store_test() StoreTestEnvironment {
	root := os.join_path(os.temp_dir(), 'ghgui-orm-${os.getpid()}-${time.now().unix_nano()}')
	environment := StoreTestEnvironment{
		root:     root
		database: os.getenv('GHGUI_DB_PATH')
		cache:    os.getenv('GHGUI_CACHE_DIR')
		disabled: os.getenv('GHGUI_NO_CACHE')
	}
	os.setenv('GHGUI_DB_PATH', os.join_path(root, 'issues.sqlite3'), true)
	os.setenv('GHGUI_CACHE_DIR', os.join_path(root, 'legacy'), true)
	os.setenv('GHGUI_NO_CACHE', '0', true)
	return environment
}

fn (environment StoreTestEnvironment) close() {
	os.setenv('GHGUI_DB_PATH', environment.database, true)
	os.setenv('GHGUI_CACHE_DIR', environment.cache, true)
	os.setenv('GHGUI_NO_CACHE', environment.disabled, true)
	os.rmdir_all(environment.root) or {}
}

fn stored_example_issue(number int, created string, updated string) Issue {
	return Issue{
		number:     number
		title:      'Issue ${number}: O\'Brien "quoted" 🐛'
		state:      'OPEN'
		created_at: '2026-10-${created}T00:00:00Z'
		updated_at: '2026-10-${updated}T00:00:00Z'
		author:     User{ login: 'alice' }
		labels:     LabelConnection{ nodes: [IssueLabel{ name: 'Bug', color: 'd73a4a' }] }
		assignees:  UserConnection{ nodes: [User{ login: 'bob' }] }
		milestone:  Milestone{ title: 'Next release' }
		comments:   Count{ total: 2 }
	}
}

fn test_orm_storage_survives_reopening_and_sorts_offline() {
	environment := prepare_store_test()
	defer { environment.close() }
	repo := Repository{ owner: 'org', name: 'repo' }
	request := FetchRequest{ repo: repo, state: 'OPEN', sort: 'Newest' }
	first := stored_example_issue(1, '01', '04')
	second := Issue{ ...stored_example_issue(2, '02', '02'), comments: Count{} }
	third := Issue{ ...stored_example_issue(3, '03', '03'), comments: Count{ total: 5 } }
	page := IssuePage{ issues: [third, second, first], open_count: 90, closed_count: 120, has_next: true, cursor: 'third-page' }
	store_issue_page(request, page, true) or { panic(err) }
	store_issue_page(request, page, true) or { panic(err) }
	detail_request := DetailRequest{ repo: repo, number: 1 }
	store_issue_body(detail_request, Issue{ ...first, body: '# Description\n\n```v\nprintln("hello")\n```' }) or { panic(err) }
	// A summary refresh preserves both older stored rows and downloaded bodies.
	refreshed := Issue{ ...third, title: 'Updated title', updated_at: '2026-10-05T00:00:00Z' }
	store_issue_page(request, IssuePage{ ...page, issues: [refreshed], cursor: 'top-page' }, true) or { panic(err) }
	store_issue_page(request, page, true) or { panic(err) }
	other := Repository{ owner: 'elsewhere', name: 'repo' }
	store_issue_page(FetchRequest{ repo: other, state: 'OPEN' }, IssuePage{ issues: [Issue{ ...first, title: 'Another repository' }], open_count: 1 }, true) or { panic(err) }
	closed := Issue{ ...second, number: 10, state: 'CLOSED', state_reason: 'COMPLETED' }
	store_issue_page(FetchRequest{ ...request, state: 'CLOSED' }, IssuePage{ issues: [closed], open_count: 90, closed_count: 120 }, true) or { panic(err) }

	// No executable can run here. Reads and ORDER BY operate entirely in SQLite.
	previous_path := os.getenv('PATH')
	os.setenv('PATH', os.join_path(environment.root, 'no-executables'), true)
	defer { os.setenv('PATH', previous_path, true) }
	newest := read_issue_cache(request) or { panic('Stored issues did not survive reopening.') }
	oldest := read_issue_cache(FetchRequest{ ...request, sort: 'Oldest' }) or { panic('Oldest sorting failed.') }
	updated := read_issue_cache(FetchRequest{ ...request, sort: 'Recently updated' }) or { panic('Updated sorting failed.') }
	assert newest.issues.map(it.number) == [3, 2, 1]
	assert oldest.issues.map(it.number) == [1, 2, 3]
	assert updated.issues.map(it.number) == [3, 1, 2]
	for sort, expected in {
		'Least recently updated': [2, 1, 3]
		'Most commented': [3, 1, 2]
		'Least commented': [2, 1, 3]
	} {
		page_for_sort := read_issue_cache(FetchRequest{ ...request, sort: sort }) or { panic('Offline ${sort} sorting failed.') }
		assert page_for_sort.issues.map(it.number) == expected
		assert page_for_sort.cursor == newest.cursor && page_for_sort.has_next
	}
	assert newest.cursor == 'third-page' && oldest.cursor == newest.cursor
	assert newest.open_count == 90 && newest.closed_count == 120
	assert newest.issues[0].title == 'Updated title'
	assert newest.issues[2].title == first.title
	assert newest.issues[2].author.login == 'alice'
	assert newest.issues[2].labels.nodes[0].name == 'Bug'
	assert newest.issues[2].assignees.nodes[0].login == 'bob'
	assert newest.issues[2].comments.total == 2
	assert newest.issues[2].milestone.title == 'Next release'
	body := read_issue_body(detail_request) or { panic('A list refresh lost the stored description.') }
	assert body.body.contains('println("hello")')
	closed_page := read_issue_cache(FetchRequest{ ...request, state: 'CLOSED' }) or { panic('Missing closed issues.') }
	assert closed_page.issues.map(it.number) == [10]
	assert closed_page.issues[0].state_reason == 'COMPLETED'

	// The file is a real SQLite database populated through V ORM models.
	mut db := sqlite.connect(issue_database_path()) or { panic(err) }
	defer { db.close() or {} }
	rows := sql db { select from StoredIssue } or { panic(err) }
	assert rows.len == 5
}

fn test_reactions_survive_storage_and_list_refresh() {
	environment := prepare_store_test()
	defer { environment.close() }
	repo := Repository{ owner: 'org', name: 'repo' }
	groups := [ReactionGroup{ content: 'THUMBS_UP', reactors: ReactorConnection{ total: 12, nodes: [User{ login: 'alice' }, User{ login: 'bob' }] }, viewer_has_reacted: true }]
	for kind in [ItemKind.issues, .prs] {
		issue := Issue{ ...stored_example_issue(42, '01', '01'), kind: kind, body: 'Description', reaction_groups: groups }
		request := DetailRequest{ repo: repo, kind: kind, number: 42 }
		store_issue_body(request, issue) or { panic(err) }
		// List metadata carries the counts so it can update without losing the body.
		store_issue_page(FetchRequest{ repo: repo, kind: kind, state: 'OPEN' },
			IssuePage{ issues: [Issue{ ...issue, body: '' }] }, true) or { panic(err) }
		stored := read_issue_body(request) or { panic('Stored description was lost.') }
		assert stored.body == issue.body
		assert stored.reaction_groups == issue.reaction_groups
	}
}

fn test_complete_refresh_hides_missing_issues_but_preserves_their_descriptions() {
	environment := prepare_store_test()
	defer { environment.close() }
	repo := Repository{ owner: 'org', name: 'repo' }
	request := FetchRequest{ repo: repo, state: 'OPEN' }
	first := stored_example_issue(1, '01', '01')
	second := stored_example_issue(2, '02', '02')
	store_issue_page(request, IssuePage{ issues: [second, first], open_count: 2 }, true) or { panic(err) }
	detail := DetailRequest{ repo: repo, number: 1 }
	store_issue_body(detail, Issue{ ...first, body: 'Saved description' }) or { panic(err) }
	store_issue_page(request, IssuePage{ issues: [second], open_count: 1 }, true) or { panic(err) }
	page := read_issue_cache(request) or { panic('Could not read the refreshed list.') }
	assert page.issues.map(it.number) == [2]
	assert (read_issue_body(detail) or { panic('Stored description was lost.') }).body == 'Saved description'
}

fn test_paginated_refresh_hides_missing_rows_only_in_the_refreshed_range() {
	for kind in [ItemKind.issues, .prs] {
		environment := prepare_store_test()
		defer { environment.close() }
		repo := Repository{ owner: 'org', name: 'repo' }
		request := FetchRequest{ repo: repo, kind: kind, state: 'OPEN' }
		older := Issue{ ...stored_example_issue(1, '01', '01'), kind: kind }
		tied := Issue{ ...older, number: 2, created_at: '2026-10-03T00:00:00Z' }
		boundary := Issue{ ...tied, number: 3 }
		missing := Issue{ ...older, number: 4, created_at: '2026-10-04T00:00:00Z' }
		newest := Issue{ ...older, number: 5, created_at: '2026-10-05T00:00:00Z' }
		initial := IssuePage{ issues: [newest, missing, boundary, tied, older], open_count: 20, has_next: true, cursor: 'older-page' }
		store_issue_page(request, initial, true) or { panic(err) }
		detail := DetailRequest{ repo: repo, kind: kind, number: missing.number }
		store_issue_body(detail, Issue{ ...missing, body: 'Saved description' }) or { panic(err) }
		page := IssuePage{ ...initial, issues: [newest, boundary], open_count: 19, cursor: 'refreshed-page' }
		partial := store_issue_page(request, page, false) or { panic(err) }
		assert partial.issues.map(it.number) == [5, 4, 3, 2, 1]
		refreshed := store_issue_page(request, page, true) or { panic(err) }
		assert refreshed.issues.map(it.number) == [5, 3, 2, 1]
		assert refreshed.has_next && refreshed.cursor == 'older-page'
		appended := store_issue_page(FetchRequest{ ...request, append: true }, IssuePage{ ...page, issues: [older] }, true) or { panic(err) }
		assert appended.issues.map(it.number) == [5, 3, 2, 1]
		assert (read_issue_body(detail) or { panic('Stored description was lost.') }).body == 'Saved description'
	}
}

fn test_pr_refresh_revalidates_cached_rows_beyond_the_first_fifty() {
	$if windows { return } // The fake GitHub CLI uses a POSIX shell.
	// Exercise both an explicit Refresh and the cached list shown on launch.
	for use_cache in [false, true] {
		environment := prepare_store_test()
		old_path := os.getenv('PATH')
		old_root := os.getenv('FAKE_GH_ROOT')
		defer {
			os.setenv('PATH', old_path, true)
			os.setenv('FAKE_GH_ROOT', old_root, true)
			environment.close()
		}
		bin := os.join_path(environment.root, 'bin')
		os.mkdir_all(bin) or { panic(err) }
		os.write_file(os.join_path(bin, 'gh'), r'#!/bin/sh
set -eu
printf "call\n" >> "$FAKE_GH_ROOT/calls"
for arg in "$@"; do
  case "$arg" in
    first=15) cat "$FAKE_GH_ROOT/first.json"; exit ;;
    first=35) cat "$FAKE_GH_ROOT/second.json"; exit ;;
    first=50) cat "$FAKE_GH_ROOT/third.json"; exit ;;
  esac
done
exit 1
') or { panic(err) }
		os.chmod(os.join_path(bin, 'gh'), 0o700) or { panic(err) }
		os.setenv('PATH', '${bin}:${old_path}', true)
		os.setenv('FAKE_GH_ROOT', environment.root, true)
		mut all := []Issue{}
		for number in 1 .. 126 {
			all << Issue{
				kind:       .prs
				number:     number
				title:      'PR ${number}'
				state:      'OPEN'
				created_at: '2026-10-${number / 24 + 1:02}T${number % 24:02}:00:00Z'
				updated_at: '2026-10-10T00:00:00Z'
			}
		}
		cached := sort_issues(all.filter(it.number >= 41 && it.number <= 120), 'Newest')
		// PR #110 merged in the first page; #50 merged in an older loaded page.
		live := sort_issues(all.filter(it.number !in [110, 50]), 'Newest')
		for i, batch in [live[..15], live[15..50], live[50..100]] {
			nodes := batch.map(json2.encode(it)).join(',')
			response := '{"data":{"repository":{"open":{"totalCount":123},"closed":{"totalCount":2},"issues":{"nodes":[${nodes}],"pageInfo":{"hasNextPage":true,"endCursor":"fresh-${i}"}}}}}'
			name := ['first', 'second', 'third'][i]
			os.write_file(os.join_path(environment.root, '${name}.json'), response) or { panic(err) }
		}
		repo := Repository{ owner: 'org', name: 'repo' }
		stored_request := FetchRequest{ repo: repo, kind: .prs, state: 'OPEN' }
		store_issue_page(stored_request, IssuePage{ issues: cached, open_count: 125, has_next: true, cursor: 'cached-page' }, true) or { panic(err) }
		detail := DetailRequest{ repo: repo, kind: .prs, number: 50 }
		store_issue_body(detail, Issue{ ...all[49], body: 'Saved PR description' }) or { panic(err) }
		mut app := App{
			repo:   repo
			kind:   .prs
			sort:   'Oldest'
			issues: if use_cache { []Issue{} } else { cached }
		}
		request := app.begin_fetch(false)
		assert request.use_cache == use_cache
		fetch_in_background(request, app.results)
		mut received := 0
		for app.results.len > 0 {
			result := <-app.results
			assert result.error == '' && result.storage_error == ''
			app.apply_result(result)
			received++
		}
		assert received == if use_cache { 4 } else { 3 }
		assert !app.loading && !app.list_cached
		assert app.issues.map(it.number) == sort_issues(live[..100], 'Oldest').map(it.number)
		assert app.open_count == 123 && app.closed_count == 2
		assert app.has_next && app.cursor == 'fresh-2'
		app.change_state('CLOSED')
		app.change_state('OPEN')
		assert !app.issues.any(it.number in [110, 50])
		stored := read_issue_cache(request) or { panic('Missing refreshed PR list.') }
		assert stored.issues.map(it.number) == app.issues.map(it.number)
		assert stored.cursor == app.cursor
		assert (read_issue_body(detail) or { panic('Stored PR description was lost.') }).body == 'Saved PR description'
		assert (os.read_file(os.join_path(environment.root, 'calls')) or { panic(err) }).split_into_lines().len == 3
	}
}

fn test_pr_orm_storage_is_separate_and_merged_prs_belong_to_closed() {
	environment := prepare_store_test()
	defer { environment.close() }
	repo := Repository{ owner: 'org', name: 'repo' }
	issue_request := FetchRequest{ repo: repo, state: 'OPEN' }
	issue := stored_example_issue(1, '01', '02')
	store_issue_page(issue_request, IssuePage{ issues: [issue], open_count: 1, closed_count: 2, has_next: true, cursor: 'issue-cursor' }, true) or { panic(err) }
	pr_request := FetchRequest{ ...issue_request, kind: .prs }
	pr := Issue{ ...issue, kind: .prs, title: 'Draft PR', is_draft: true, mergeable: 'CONFLICTING', base_ref: 'main', head_ref: 'topic', additions: 3, deletions: 1, changed_files: 2 }
	store_issue_page(pr_request, IssuePage{ issues: [pr], open_count: 4, closed_count: 100, has_next: true, cursor: 'pr-cursor' }, true) or { panic(err) }
	detail_request := DetailRequest{ kind: .prs, repo: repo, number: 1 }
	store_issue_body(detail_request, Issue{ ...pr, body: 'PR description' }) or { panic(err) }
	loaded := read_issue_cache(pr_request) or { panic('Missing stored PRs.') }
	assert loaded.issues[0].kind == .prs && loaded.issues[0].is_draft
	assert loaded.issues[0].head_ref == 'topic' && loaded.issues[0].additions == 3
	assert loaded.issues[0].has_merge_conflicts()
	assert (read_issue_body(detail_request) or { panic('Missing PR description.') }).has_merge_conflicts()
	assert loaded.open_count == 4 && loaded.closed_count == 100 && loaded.cursor == 'pr-cursor'
	assert (read_issue_body(detail_request) or { panic('Missing PR description.') }).body == 'PR description'
	assert read_issue_body(DetailRequest{ repo: repo, number: 1 }) == none
	merged := Issue{ ...pr, state: 'MERGED', is_draft: false, updated_at: '2026-10-05T00:00:00Z',
		merged_at: '2026-10-05T00:00:00Z', merged_by: User{ login: 'maintainer' } }
	closed_request := FetchRequest{ ...pr_request, state: 'CLOSED' }
	store_issue_page(closed_request, IssuePage{ issues: [merged], open_count: 3, closed_count: 101 }, true) or { panic(err) }
	closed := read_issue_cache(closed_request) or { panic('Missing merged PR.') }
	assert closed.issues.len == 1 && closed.issues[0].state == 'MERGED'
	assert closed.issues[0].merged_by.login == 'maintainer' && closed.issues[0].merged_at == merged.merged_at
	stored_detail := read_issue_body(detail_request) or { panic('Description was lost after merging.') }
	assert stored_detail.body == 'PR description'
	assert stored_detail.merged_by.login == 'maintainer' && stored_detail.merged_at == merged.merged_at
	store_issue_page(pr_request, IssuePage{ open_count: 3, closed_count: 101 }, true) or { panic(err) }
	assert (read_issue_cache(pr_request) or { panic('Missing open PR counts.') }).issues.len == 0
	retained := read_issue_cache(issue_request) or { panic('PR refresh changed issues.') }
	assert retained.issues[0].title == issue.title && retained.issues[0].kind == .issues
	assert retained.open_count == 1 && retained.closed_count == 2 && retained.cursor == 'issue-cursor'
}

fn test_legacy_json_cache_is_imported_once_into_the_orm_database() {
	environment := prepare_store_test()
	defer { environment.close() }
	repo := Repository{ owner: 'org', name: 'repo' }
	path := os.join_path(legacy_cache_root(), repo.owner, repo.name, 'OPEN_Oldest.json')
	os.mkdir_all(os.dir(path)) or { panic(err) }
	source := '{"data":{"repository":{"open":{"totalCount":1},"closed":{"totalCount":8},"issues":{"pageInfo":{"hasNextPage":false,"endCursor":"wrong-order-cursor"},"nodes":[{"number":1,"title":"Imported issue","state":"OPEN","createdAt":"2020-01-01T00:00:00Z"}]}}}}'
	os.write_file(path, json2.encode(IssueCache{ saved_at: 1, pages: [source] })) or { panic(err) }
	request := FetchRequest{ repo: repo, state: 'OPEN', sort: 'Newest' }
	page := read_issue_cache(request) or { panic('Legacy data was not imported.') }
	assert page.issues[0].title == 'Imported issue'
	assert page.open_count == 1 && page.closed_count == 8
	assert page.cursor == '' // Oldest's GitHub cursor cannot be reused for Newest.
	os.write_file(path, 'broken json') or { panic(err) }
	assert (read_issue_cache(request) or { panic('Imported data did not survive reopening.') }).issues[0].title == 'Imported issue'
	os.setenv('GHGUI_NO_CACHE', '1', true)
	if _ := read_issue_cache(request) {
		assert false, 'Persistence bypass should be respected.'
	}
}

fn test_database_errors_are_reported_without_destroying_live_data() {
	environment := prepare_store_test()
	defer { environment.close() }
	os.mkdir_all(environment.root) or { panic(err) }
	os.write_file(issue_database_path(), 'not a SQLite database') or { panic(err) }
	mut app := App{}
	request := app.begin_fetch(false)
	page := IssuePage{ issues: [stored_example_issue(1, '01', '01')] }
	mut storage_error := ''
	store_issue_page(request, page, true) or { storage_error = err.msg() }
	assert storage_error != ''
	app.apply_result(FetchResult{ request: request, page: page, storage_error: storage_error })
	assert app.issues.len == 1 && app.error == '' && !app.loading
	assert app.storage_error != ''
}
