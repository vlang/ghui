module main

import json2
import os
import time
import ui2

fn merge_example_app() App {
	issue := Issue{
		kind:       .prs
		number:     42
		title:      'Add a feature'
		state:      'OPEN'
		head_oid:   '0123456789abcdef0123456789abcdef01234567'
		head_ref:   'topic'
		base_ref:   'main'
		body:       'Description'
		updated_at: '2026-10-02T00:00:00Z'
	}
	mut app := App{
		repo:         Repository{ owner: 'org', name: 'repo' }
		kind:         .prs
		issues:       [issue]
		open_count:   4
		closed_count: 100
		loaded_state: 'OPEN'
	}
	app.open_issue(42)
	request := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{ request: request, detail: IssueDetail{ issue: issue } })
	return app
}

fn test_squash_merge_requires_a_loaded_open_non_draft_pr_and_prevents_double_clicks() {
	mut app := merge_example_app()
	assert app.can_squash_merge()
	valid := app.detail.issue
	for issue in [Issue{ ...valid, kind: .issues }, Issue{ ...valid, state: 'CLOSED' },
		Issue{ ...valid, state: 'MERGED' }, Issue{ ...valid, is_draft: true },
		Issue{ ...valid, head_oid: '' }, Issue{ ...valid, mergeable: 'CONFLICTING' }] {
		app.detail = IssueDetail{ issue: issue }
		assert app.begin_squash_merge() == none
		squash_merge_args(MergeRequest{ repo: app.repo, issue: issue }) or { continue }
		assert false, 'Invalid PR should never reach GitHub.'
	}
	app.detail = IssueDetail{ issue: valid }
	app.detail_loaded = false
	assert app.begin_squash_merge() == none
	app.detail_loaded = true
	app.detail_body_loading = true
	assert app.begin_squash_merge() == none
	app.detail_body_loading = false
	request := app.begin_squash_merge() or { panic('Merge did not start.') }
	assert app.merging_current_pr()
	assert app.begin_squash_merge() == none
	args := squash_merge_args(request) or { panic(err) }
	assert 'PUT' in args && 'repos/org/repo/pulls/42/merge' in args
	assert 'merge_method=squash' in args && 'sha=${valid.head_oid}' in args
	assert !args.any(it.contains('admin') || it.contains('delete-branch'))
}

fn test_merge_success_updates_details_lists_counts_and_rejects_obsolete_reads() {
	mut app := merge_example_app()
	app.list_cache['prs_OPEN'] = IssuePage{ issues: app.issues, open_count: 4, closed_count: 100 }
	app.list_cache['prs_CLOSED'] = IssuePage{ open_count: 4, closed_count: 100 }
	old_list := app.begin_fetch(false)
	old_detail := app.begin_detail_fetch(true)
	app.toggle_selection(42)
	request := app.begin_squash_merge() or { panic('Merge did not start.') }
	merged := Issue{ ...request.issue, state: 'MERGED', merged_at: '2026-10-03T00:00:00Z', updated_at: '2026-10-03T00:00:00Z' }
	result := MergeResult{ request: request, issue: merged }
	assert app.apply_merge_result(result)
	assert !app.merge_loading && !app.can_squash_merge()
	assert app.detail.issue.state == 'MERGED' && app.detail.issue.body == 'Description'
	assert app.detail_cache[42].detail.issue.state == 'MERGED'
	assert app.detail.issue.merged_at == merged.merged_at
	assert app.detail_cache[42].detail.issue.merged_at == merged.merged_at
	assert app.issues.len == 0 && 42 !in app.selected
	assert app.open_count == 3 && app.closed_count == 101
	assert app.list_cache['prs_OPEN'].issues.len == 0
	assert app.list_cache['prs_CLOSED'].issues[0].state == 'MERGED'
	assert cancelled(old_list.cancel) && cancelled(old_detail.cancel)
	app.apply_result(FetchResult{ request: old_list, page: IssuePage{ issues: [request.issue] } })
	app.apply_detail_result(DetailResult{ request: old_detail, detail: IssueDetail{ issue: request.issue } })
	assert app.issues.len == 0 && app.detail.issue.state == 'MERGED'
	assert !app.apply_merge_result(result)
	assert app.open_count == 3 && app.closed_count == 101
	app.close_issue()
	app.open_issue(42)
	assert app.detail.issue.state == 'MERGED'
}

fn test_merge_errors_keep_the_pr_open_and_navigation_preserves_the_outcome() {
	mut app := merge_example_app()
	request := app.begin_squash_merge() or { panic('Merge did not start.') }
	assert !app.apply_merge_result(MergeResult{ request: request, error: 'Required checks have not passed.' })
	assert app.can_squash_merge() && app.detail.issue.state == 'OPEN'
	assert app.merge_errors[42].contains('Required checks')
	assert app.open_count == 4 && app.closed_count == 100
	next := app.begin_squash_merge() or { panic('Retry did not start.') }
	assert 42 !in app.merge_errors
	assert !app.apply_merge_result(MergeResult{ request: request, error: 'Old error' })
	assert app.merge_loading
	app.change_kind(.issues)
	app.issues = [Issue{ number: 42, title: 'Unrelated issue', state: 'OPEN' }]
	app.open_count = 9
	app.closed_count = 20
	app.open_issue(42)
	assert app.apply_merge_result(MergeResult{ request: next, issue: Issue{ ...next.issue, state: 'MERGED' } })
	assert app.detail.issue.kind == .issues && app.detail.issue.state == 'OPEN'
	assert app.issues[0].state == 'OPEN' && app.open_count == 9 && app.closed_count == 20
	app.change_kind(.prs)
	assert app.issues.len == 0 && app.open_count == 3 && app.closed_count == 101
}

fn test_merge_response_requires_explicit_success() {
	decode_squash_merge('{"merged":true,"sha":"commit","message":"Merged"}') or { panic(err) }
	for response in ['{"merged":false,"message":"Head branch was modified"}', '{}', 'invalid'] {
		decode_squash_merge(response) or { continue }
		assert false, response
	}
}

fn test_squash_commit_description_removes_all_coauthors_and_keeps_other_text() {
	message := '* Add feature\n\nCo-authored-by: Alice <alice@example.com>\nCO-AUTHORED-BY: Bot <bot@example.com>\n\tCo-Authored-By: Bob <bob@example.com>\n\nSigned-off-by: Maintainer <maintainer@example.com>'
	assert remove_commit_coauthors(message) == '* Add feature\n\n\nSigned-off-by: Maintainer <maintainer@example.com>'
	assert remove_commit_coauthors('Description\n\nCo-authored-by: Alice <alice@example.com>\n \n') == 'Description'
	assert remove_commit_coauthors('Co-authored-by: Alice <alice@example.com>\nCo-authored-by: Bot <bot@example.com>') == ''
	assert remove_commit_coauthors('Description\r\n\r\nCo-authored-by: Alice <alice@example.com>\r\n') == 'Description'
	for unchanged in ['', 'Description\n\nMore detail\n', 'Text mentioning Co-authored-by: is preserved.'] {
		assert remove_commit_coauthors(unchanged) == unchanged
	}
}

fn test_squash_commit_description_requires_a_matching_head_and_valid_message() {
	response := r'{"data":{"repository":{"pullRequest":{"headRefOid":"abc123","viewerMergeBodyText":"* Add feature\n\nCo-authored-by: Alice <alice@example.com>"}}}}'
	assert (decode_squash_merge_message(response, 'abc123') or { panic(err) }) == '* Add feature'
	for mergeable in ['MERGEABLE', 'UNKNOWN'] {
		assert (decode_squash_merge_message(response.replace('"headRefOid"', '"mergeable":"${mergeable}","headRefOid"'), 'abc123') or { panic(err) }) == '* Add feature'
	}
	for invalid in [response.replace('abc123', 'changed'), response.replace('viewerMergeBodyText', 'missing'),
		response.replace('"abc123"', 'null'), response.replace('"headRefOid"', '"mergeable":"CONFLICTING","headRefOid"'), '{}', 'invalid',
		r'{"errors":[{"message":"Permission denied"}]}',
		r'{"data":{"repository":{"pullRequest":{"headRefOid":"abc123","viewerMergeBodyText":null}}}}'] {
		decode_squash_merge_message(invalid, 'abc123') or { continue }
		assert false, 'Invalid or obsolete descriptions must prevent a merge.'
	}
}

fn test_pr_detail_queries_and_decoder_supply_the_head_commit_for_merging() {
	for part in [DetailPart.body, .complete] {
		args := detail_query_args(DetailRequest{ kind: .prs, number: 42 }, part)
		assert args.filter(it.starts_with('query='))[0].contains('headRefOid')
	}
	issue := decode_issue(json2.decode[json2.Any](r'{"__typename":"PullRequest","number":42,"title":"Feature","headRefOid":"abc123"}') or { panic(err) }) or { panic(err) }
	assert issue.head_oid == 'abc123'
}

fn test_squash_merge_button_loading_failure_and_merged_states() {
	mut app := merge_example_app()
	for width in [800.0, 1440.0] {
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
	}
	mut layout := detail_layout(&app, ui2.rect(0, 0, 800, 860))
	assert layout.content.children.filter(it.id == 'squash_merge')[0].enabled
	request := app.begin_squash_merge() or { panic('Merge did not start.') }
	layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
	button := layout.content.children.filter(it.id == 'squash_merge')[0]
	assert button.text == 'Merging…' && !button.enabled
	app.apply_merge_result(MergeResult{ request: request, error: 'Permission denied' })
	layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
	assert layout.content.children.any(it.id == 'merge_error')
	ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, 800, 860))) or { panic(err) }
	app.detail = IssueDetail{ ...app.detail, issue: Issue{ ...app.detail.issue, is_draft: true } }
	layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
	assert !layout.content.children.filter(it.id == 'squash_merge')[0].enabled
	app.detail = IssueDetail{ ...app.detail, issue: Issue{ ...app.detail.issue, state: 'MERGED' } }
	layout = detail_layout(&app, ui2.rect(0, 0, 800, 860))
	assert !layout.content.children.any(it.id == 'squash_merge')
}

fn test_conflicts_disable_squash_merge_and_refresh_restores_it() {
	mut app := merge_example_app()
	pr := app.detail.issue
	request := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{ request: request, part: .body, detail: IssueDetail{ issue: Issue{ ...pr, mergeable: 'CONFLICTING' } } })
	assert app.issues[0].has_merge_conflicts()
	assert app.detail_cache[42].detail.issue.has_merge_conflicts()
	assert app.begin_squash_merge() == none
	for width in [800.0, 1440.0] {
		layout := detail_layout(&app, ui2.rect(0, 0, width, 860))
		notice := layout.content.children.filter(it.id == 'pr_conflicts')[0]
		button := layout.content.children.filter(it.id == 'squash_merge')[0]
		assert !button.enabled && button.tooltip.contains('Resolve merge conflicts')
		assert button.frame.y >= notice.frame.y + notice.frame.height
		ui2.validate_element_tree(layout.content) or { panic(err) }
	}
	refreshed := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{ request: refreshed, part: .body, detail: IssueDetail{ issue: Issue{ ...pr, mergeable: 'MERGEABLE' } } })
	assert app.can_squash_merge() && !app.issues[0].has_merge_conflicts()
	layout := detail_layout(&app, ui2.rect(0, 0, 800, 860))
	assert !layout.content.children.any(it.id == 'pr_conflicts')
}

fn test_merge_worker_uses_gh_and_persists_success_only() {
	$if windows {
		return
	}
	root := os.join_path(os.temp_dir(), 'ghgui-merge-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(os.join_path(root, 'bin')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	mut previous := map[string]string{}
	for name in ['PATH', 'GHGUI_DB_PATH', 'GHGUI_NO_CACHE', 'FAKE_MERGE_ROOT'] {
		previous[name] = os.getenv(name)
	}
	defer {
		for name, value in previous { os.setenv(name, value, true) }
	}
	os.setenv('PATH', '${os.join_path(root, 'bin')}:${previous['PATH']}', true)
	os.setenv('GHGUI_DB_PATH', os.join_path(root, 'issues.sqlite3'), true)
	os.setenv('GHGUI_NO_CACHE', '0', true)
	os.setenv('FAKE_MERGE_ROOT', root, true)
script := r'#!/bin/sh
set -eu
case " $* " in
  *" graphql "*)
    printf "%s\n" "$@" > "$FAKE_MERGE_ROOT/message-args"
    if [ -f "$FAKE_MERGE_ROOT/message-fail" ]; then
      printf "Description unavailable\n" >&2
      exit 1
    fi
    cat "$FAKE_MERGE_ROOT/message-response"
    exit 0
    ;;
esac
printf "%s\n" "$@" > "$FAKE_MERGE_ROOT/args"
cat "$FAKE_MERGE_ROOT/response"
if [ -f "$FAKE_MERGE_ROOT/fail" ]; then
  printf "Required status checks are failing\n" >&2
  exit 1
fi
'
	os.write_file(os.join_path(root, 'bin', 'gh'), script) or { panic(err) }
	os.chmod(os.join_path(root, 'bin', 'gh'), 0o700) or { panic(err) }
	mut app := merge_example_app()
	pr := app.detail.issue
	message_response := '{"data":{"repository":{"pullRequest":{"headRefOid":"${pr.head_oid}","viewerMergeBodyText":"* Add feature\\n\\nCo-authored-by: Alice <alice@example.com>\\nCo-Authored-By: Bot <bot@example.com>"}}}}'
	os.write_file(os.join_path(root, 'message-response'), message_response) or { panic(err) }
	list_request := FetchRequest{ kind: .prs, repo: app.repo, state: 'OPEN' }
	store_issue_page(list_request, IssuePage{ issues: [pr], open_count: 4, closed_count: 100 }, true) or { panic(err) }
	store_issue_body(DetailRequest{ kind: .prs, repo: app.repo, number: 42 }, pr) or { panic(err) }
	os.write_file(os.join_path(root, 'response'), '{"merged":false,"message":"Cannot merge"}') or { panic(err) }
	request := app.begin_squash_merge() or { panic('Merge did not start.') }
	for failure in ['unavailable', 'changed', 'conflicting'] {
		if failure == 'unavailable' {
			os.write_file(os.join_path(root, 'message-fail'), '') or { panic(err) }
		} else {
			if os.exists(os.join_path(root, 'message-fail')) { os.rm(os.join_path(root, 'message-fail')) or { panic(err) } }
			response := if failure == 'changed' { message_response.replace(pr.head_oid, 'changed') } else {
				message_response.replace('"headRefOid"', '"mergeable":"CONFLICTING","headRefOid"')
			}
			os.write_file(os.join_path(root, 'message-response'), response) or { panic(err) }
		}
		worker := spawn squash_merge_in_background(request, app.merge_results)
		worker.wait()
		failed := <-app.merge_results
		assert failed.error.contains(match failure {
			'unavailable' { 'Description unavailable' }
			'changed' { 'head branch was modified' }
			else { 'Resolve merge conflicts' }
		})
		assert !os.exists(os.join_path(root, 'args'))
	}
	os.write_file(os.join_path(root, 'message-response'), message_response) or { panic(err) }
	for process_failure in [false, true] {
		if process_failure { os.write_file(os.join_path(root, 'fail'), '') or { panic(err) } }
		worker := spawn squash_merge_in_background(request, app.merge_results)
		worker.wait()
		failed := <-app.merge_results
		assert failed.error.contains(if process_failure {
			'Required status checks'
		} else {
			'Cannot merge'
		})
		assert (read_issue_cache(list_request) or { panic('Missing stored PR.') }).issues[0].state == 'OPEN'
	}
	os.rm(os.join_path(root, 'fail')) or { panic(err) }
	os.write_file(os.join_path(root, 'response'), '{"merged":true,"message":"Merged"}') or { panic(err) }
	worker := spawn squash_merge_in_background(request, app.merge_results)
	app.close_issue()
	worker.wait()
	result := <-app.merge_results
	assert result.error == '' && result.storage_error == '' && result.issue.state == 'MERGED'
	assert result.issue.merged_at != '' && result.issue.merged_at == result.issue.updated_at
	assert app.apply_merge_result(result)
	args := os.read_file(os.join_path(root, 'args')) or { panic(err) }
	assert args.contains('repos/org/repo/pulls/42/merge\n')
	assert args.contains('merge_method=squash\n') && args.contains('sha=${pr.head_oid}\n')
	assert args.contains('commit_message=* Add feature\n') && !args.to_lower().contains('co-authored-by:')
	assert !args.contains('commit_title=')
	message_args := os.read_file(os.join_path(root, 'message-args')) or { panic(err) }
	assert message_args.contains('viewerMergeBodyText(mergeType: SQUASH)')
	assert message_args.contains('owner=org\n') && message_args.contains('name=repo\n') && message_args.contains('number=42\n')
	// A co-author-only description must be sent as an explicit empty body.
	os.write_file(os.join_path(root, 'message-response'), message_response.replace('* Add feature\\n\\n', '')) or { panic(err) }
	empty_worker := spawn squash_merge_in_background(request, app.merge_results)
	empty_worker.wait()
	assert (<-app.merge_results).error == ''
	empty_args := os.read_file(os.join_path(root, 'args')) or { panic(err) }
	assert empty_args.contains('commit_message=\n') && !empty_args.to_lower().contains('co-authored-by:')
	// A response captured before the merge must not undo the stored outcome.
	store_issue_page(list_request, IssuePage{ issues: [Issue{ ...pr, updated_at: result.issue.updated_at }], open_count: 3, closed_count: 101 }, true) or { panic(err) }
	store_merged_pull_request(app.repo, result.issue) or { panic(err) }
	open := read_issue_cache(list_request) or { panic('Missing stored PR counts.') }
	assert open.issues.len == 0 && open.open_count == 3 && open.closed_count == 101
	closed := read_issue_cache(FetchRequest{ ...list_request, state: 'CLOSED' }) or { panic('Missing merged PR.') }
	assert closed.issues[0].state == 'MERGED' && closed.issues[0].head_oid == pr.head_oid
	assert (read_issue_body(DetailRequest{ kind: .prs, repo: app.repo, number: 42 }) or { panic('Missing body.') }).body == 'Description'
}
