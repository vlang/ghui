module main

import os
import time

fn test_closed_pr_recent_activity_is_included_without_changing_creation_pagination() {
	$if windows { return }
	root := os.join_path(os.temp_dir(), 'ghgui-recent-pr-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(os.join_path(root, 'bin')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	old_path := os.getenv('PATH')
	old_root := os.getenv('RECENT_PR_TEST_ROOT')
	old_db := os.getenv('GHGUI_DB_PATH')
	old_no_cache := os.getenv('GHGUI_NO_CACHE')
	defer {
		os.setenv('PATH', old_path, true)
		os.setenv('RECENT_PR_TEST_ROOT', old_root, true)
		os.setenv('GHGUI_DB_PATH', old_db, true)
		os.setenv('GHGUI_NO_CACHE', old_no_cache, true)
	}
	os.setenv('PATH', '${os.join_path(root, 'bin')}:${old_path}', true)
	os.setenv('RECENT_PR_TEST_ROOT', root, true)
	os.setenv('GHGUI_DB_PATH', os.join_path(root, 'db.sqlite'), true)
	os.setenv('GHGUI_NO_CACHE', '0', true)
	os.write_file(os.join_path(root, 'bin', 'gh'), r'#!/bin/sh
set -eu
for arg in "$@"; do
 case "$arg" in
  *"field: UPDATED_AT"*) cat "$RECENT_PR_TEST_ROOT/recent.json"; exit ;;
  cursor=creation15) cat "$RECENT_PR_TEST_ROOT/next.json"; exit ;;
 esac
done
cat "$RECENT_PR_TEST_ROOT/first.json"
') or { panic(err) }
	os.chmod(os.join_path(root, 'bin', 'gh'), 0o700) or { panic(err) }
	old_pr := Issue{ kind: .prs, number: 1, title: 'Old merged PR', state: 'MERGED', created_at: '2020-01-01T00:00:00Z', updated_at: '2026-10-28T00:00:00Z' }
	new_pr := Issue{ kind: .prs, number: 2, title: 'New closed PR', state: 'CLOSED', created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-01T00:00:00Z' }
	older_pr := Issue{ kind: .prs, number: 3, title: 'Next closed PR', state: 'CLOSED', created_at: '2025-01-01T00:00:00Z', updated_at: '2025-01-01T00:00:00Z' }
	os.write_file(os.join_path(root, 'recent.json'), recent_pr_fixture([old_pr], 'activity-cursor', true)) or { panic(err) }
	mut first_page := [new_pr]
	for number in 4 .. 53 {
		first_page << Issue{ kind: .prs, number: number, title: 'Closed PR', state: 'CLOSED', created_at: '2026-01-01T00:00:00Z', updated_at: '2026-01-01T00:00:00Z' }
	}
	os.write_file(os.join_path(root, 'first.json'), recent_pr_fixture(first_page, 'creation15', true)) or { panic(err) }
	os.write_file(os.join_path(root, 'next.json'), recent_pr_fixture([older_pr], 'creation-end', false)) or { panic(err) }
	mut app := App{ kind: .prs, state: 'CLOSED', repo: Repository{ owner: 'test', name: 'repo' } }
	request := app.begin_fetch(false)
	fetch_in_background(request, app.results)
	for app.results.len > 0 { app.apply_result(<-app.results) }
	app.change_sort('Recently updated')
	assert app.issues[0].number == 1 && app.issues.len == 51
	assert app.cursor == 'creation15' && app.has_next
	assert app.supplemental.map(it.number) == [1]
	append := app.begin_fetch(true)
	fetch_in_background(append, app.results)
	for app.results.len > 0 { app.apply_result(<-app.results) }
	assert app.issues[0].number == 1 && app.issues.len == 52
	assert app.cursor == 'creation-end' && !app.has_next
	assert app.supplemental.map(it.number) == [1]
	refresh := app.begin_fetch(false)
	assert refresh.refresh_through.number == 3
	app.change_state('OPEN')
	app.change_state('CLOSED')
	assert app.issues[0].number == 1 && app.issues.len == 52
	assert app.supplemental.map(it.number) == [1]
}

fn recent_pr_fixture(issues []Issue, cursor string, has_next bool) string {
	imported := issues.map(recent_pr_json(it)).join(',')
	return '{"data":{"repository":{"open":{"totalCount":1},"closed":{"totalCount":100},"issues":{"nodes":[${imported}],"pageInfo":{"hasNextPage":${has_next},"endCursor":"${cursor}"}}}}}'
}

fn recent_pr_json(issue Issue) string {
	return '{"__typename":"PullRequest","number":${issue.number},"title":"${issue.title}","state":"${issue.state}","createdAt":"${issue.created_at}","updatedAt":"${issue.updated_at}"}'
}

fn test_recent_pr_metadata_overlays_older_cached_rows() {
	old := Issue{ kind: .prs, number: 10, state: 'CLOSED', updated_at: '2026-01-01T00:00:00Z' }
	merged := Issue{ ...old, state: 'MERGED', updated_at: '2026-10-28T00:00:00Z' }
	assert merge_recent_prs([old], [merged])[0].state == 'MERGED'
	assert merge_recent_prs([merged], [old])[0].state == 'MERGED'
	assert merge_recent_prs([old], [Issue{ ...merged, updated_at: old.updated_at }])[0].state == 'MERGED'
	args := recent_closed_pr_args(FetchRequest{ kind: .prs, state: 'CLOSED', cursor: 'creation-cursor' })
	assert args.any(it.contains('field: UPDATED_AT'))
	assert 'states[]=MERGED' in args && 'first=50' in args && 'cursor=creation-cursor' !in args
}
