module main

import os
import time
import ui2

const pr_response = r'{"data":{"repository":{"open":{"totalCount":4},"closed":{"totalCount":120},"issues":{"pageInfo":{"hasNextPage":true,"endCursor":"pr-next"},"nodes":[{"__typename":"PullRequest","number":42,"title":"Add PR support","state":"OPEN","isDraft":true,"createdAt":"2026-10-02T00:00:00Z","updatedAt":"2026-10-03T00:00:00Z","baseRefName":"main","headRefName":"feature/prs","additions":80,"deletions":12,"changedFiles":3,"author":{"login":"alice"},"comments":{"totalCount":1}}]}}}}'

const pr_detail_response = r'{"data":{"repository":{"issue":{"__typename":"PullRequest","number":42,"title":"Add PR support","body":"## Summary\n\nPR description","state":"MERGED","isDraft":false,"mergedAt":"2026-10-03T12:00:00Z","mergedBy":{"login":"carol"},"author":{"login":"alice"},"baseRefName":"main","headRefName":"feature/prs","additions":80,"deletions":12,"changedFiles":3,"comments":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":"reply"},"nodes":[{"id":"reply","body":"Looks good","createdAt":"2026-10-02T00:00:00Z","author":{"login":"bob"}}]}}}}}'

fn test_pr_list_and_detail_decode_preserve_pr_states_and_metadata() {
	page := decode_page(pr_response) or { panic(err) }
	pr := page.issues[0]
	assert pr.kind == .prs && pr.status() == 'Draft'
	assert page.open_count == 4 && page.closed_count == 120
	assert page.has_next && page.cursor == 'pr-next'
	assert pr.base_ref == 'main' && pr.head_ref == 'feature/prs'
	assert pr.additions == 80 && pr.deletions == 12 && pr.changed_files == 3
	detail := decode_detail(pr_detail_response) or { panic(err) }
	assert detail.issue.kind == .prs && detail.issue.status() == 'Merged'
	assert detail.issue.list_state() == 'CLOSED'
	assert detail.issue.merged_by.login == 'carol' && detail.issue.author.login == 'alice'
	assert detail.issue.merged_at == '2026-10-03T12:00:00Z'
	assert detail.issue.body.contains('PR description')
	assert detail.comments[0].body == 'Looks good'
	assert detail.comments[0].author.login == 'bob'
	assert !detail.has_next
	assert (Issue{ kind: .prs, state: 'CLOSED' }).status() == 'Closed'
	assert pr.merged_by.login == '' && pr.merged_at == ''
	missing := decode_detail(pr_detail_response.replace('"mergedBy":{"login":"carol"}', '"mergedBy":null')
		.replace('"mergedAt":"2026-10-03T12:00:00Z"', '"mergedAt":null')) or { panic(err) }
	assert missing.issue.merged_by.login == '' && missing.issue.merged_at == ''
}

fn test_pr_queries_use_pull_request_endpoints_and_include_merged_in_closed() {
	request := FetchRequest{ kind: .prs, repo: Repository{ owner: 'vlang', name: 'v' }, state: 'CLOSED', cursor: 'next' }
	args := github_args(request)
	assert 'query=${pull_requests_query}' in args
	assert pull_requests_query.contains('mergedAt mergedBy { login }')
	assert pull_requests_query.contains('mergeable')
	assert 'states[]=CLOSED' in args && 'states[]=MERGED' in args
	assert 'state=CLOSED' !in args && 'cursor=next' in args
	assert 'states[]=MERGED' !in github_args(FetchRequest{ ...request, state: 'OPEN' })
	for sort in issue_sort_options {
		assert github_args(FetchRequest{ ...request, sort: sort }) == args
	}
	for part in [DetailPart.body, .comments, .complete] {
		detail_args := detail_query_args(DetailRequest{ kind: .prs, number: 42, cursor: 'after', limit: 10 }, part)
		query := detail_args.filter(it.starts_with('query='))[0]
		assert query.contains('issue: pullRequest(number: $number)')
		assert query.contains('__typename number')
		assert !query.contains('stateReason')
		if part != .comments {
			assert query.contains('mergedAt mergedBy { login }')
			assert query.contains('mergeable')
		}
		if part == .body {
			assert 'first=10' !in detail_args && 'cursor=after' !in detail_args
		} else {
			assert 'first=10' in detail_args && 'cursor=after' in detail_args
		}
	}
}

fn test_switching_modes_cancels_previous_requests_and_restores_separate_lists() {
	mut app := App{}
	issues := app.begin_fetch(false)
	app.apply_result(FetchResult{ request: issues, page: IssuePage{ issues: [Issue{ number: 1, title: 'Issue', state: 'OPEN' }], open_count: 9, closed_count: 20 } })
	app.open_issue(1)
	detail_request := app.begin_detail_fetch(false)
	app.change_kind(.prs)
	assert cancelled(issues.cancel) && cancelled(detail_request.cancel)
	assert app.active_issue == 0 && !app.detail_loading
	assert app.issues.len == 0 && app.open_count == 0 && app.loaded_state == ''
	prs := app.begin_fetch(false)
	assert prs.kind == .prs && prs.state == 'OPEN'
	app.apply_result(FetchResult{ request: issues, page: IssuePage{ issues: [Issue{ number: 99 }] } })
	app.apply_detail_result(DetailResult{ request: detail_request, detail: IssueDetail{ issue: Issue{ number: 1, body: 'Stale body' } } })
	assert app.loading && app.issues.len == 0 && !app.detail_loaded
	page := decode_page(pr_response) or { panic(err) }
	app.apply_result(FetchResult{ request: prs, page: page })
	app.change_sort('Oldest')
	assert app.generation == prs.generation && !cancelled(prs.cancel)
	app.change_kind(.issues)
	assert app.issues.map(it.number) == [1] && app.open_count == 9
	app.change_kind(.prs)
	assert app.issues.map(it.number) == [42] && app.open_count == 4
	assert app.cursor == 'pr-next' && app.has_next
	app.change_state('CLOSED')
	closed := app.begin_fetch(false)
	merged := (decode_detail(pr_detail_response) or { panic(err) }).issue
	app.apply_result(FetchResult{ request: closed, page: IssuePage{ issues: [merged] } })
	app.open_issue(42)
	request := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{ request: request, detail: decode_detail(pr_detail_response) or { panic(err) } })
	assert app.issues.len == 1 && app.issues[0].state == 'MERGED'
}

fn test_pr_lists_and_native_details_have_valid_element_trees() {
	mut app := App{ kind: .prs, issues: (decode_page(pr_response) or { panic(err) }).issues }
	for width in [800.0, 1440.0] {
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
	}
	app.open_issue(42)
	request := app.begin_detail_fetch(false)
	app.apply_detail_result(DetailResult{ request: request, detail: decode_detail(pr_detail_response) or { panic(err) } })
	for width in [800.0, 1440.0] {
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
	}
}

fn test_merged_pr_summary_shows_merger_branch_and_time_only_for_merged_prs() {
	detail := decode_detail(pr_detail_response) or { panic(err) }
	mut app := App{ kind: .prs, active_issue: 42, detail: detail, detail_loaded: true, detail_comments_loaded: true }
	for width in [800.0, 1440.0] {
		layout := detail_layout(&app, ui2.rect(0, 0, width, 860))
		summary := layout.content.children.filter(it.id == 'pr_merge_summary')[0]
		label := summary.children[0]
		assert label.text.starts_with('carol merged this pull request into main ')
		assert !label.text.contains('alice')
		assert label.tooltip == 'Merged at 2026-10-03T12:00:00Z'
		state := layout.content.children.filter(it.id == 'detail_state')[0]
		assert state.children[0].text == 'Merged' && state.box.bg == purple
		branches := layout.content.children.filter(it.id == 'pr_branches')[0]
		assert branches.frame.y >= summary.frame.y + summary.frame.height
		ui2.validate_element_tree(layout.content) or { panic(err) }
	}
	// Old cached PRs and deleted accounts must still show a useful merged status.
	app.detail = IssueDetail{ ...detail, issue: Issue{ ...detail.issue, merged_by: User{}, merged_at: '', base_ref: '' } }
	fallback := detail_layout(&app, ui2.rect(0, 0, 800, 860)).content.children.filter(it.id == 'pr_merge_summary')[0]
	assert fallback.children[0].text == 'This pull request was merged'
	// Long branch names wrap without overlapping the branch/diff controls.
	app.detail = IssueDetail{ ...detail, issue: Issue{ ...detail.issue, base_ref: 'release-'.repeat(20) } }
	wrapped := detail_layout(&app, ui2.rect(0, 0, 800, 860))
	summary := wrapped.content.children.filter(it.id == 'pr_merge_summary')[0]
	assert summary.children[0].text_style.lines > 1
	assert summary.children[0].frame.height + 20 == summary.frame.height
	ui2.validate_element_tree(wrapped.content) or { panic(err) }
	for issue in [Issue{ ...detail.issue, state: 'OPEN' }, Issue{ ...detail.issue, state: 'CLOSED' },
		Issue{ ...detail.issue, kind: .issues, state: 'CLOSED' }] {
		app.detail = IssueDetail{ issue: issue }
		layout := detail_layout(&app, ui2.rect(0, 0, 800, 860))
		assert !layout.content.children.any(it.id == 'pr_merge_summary')
	}
}

fn test_live_pr_lists_pagination_and_native_detail_queries_when_requested() {
	if os.getenv('GHGUI_LIVE_TESTS') != '1' { return }
	repo := Repository{ owner: 'vlang', name: 'v' }
	for state in ['OPEN', 'CLOSED'] {
		request := FetchRequest{ kind: .prs, repo: repo, state: state, limit: 15 }
		page := fetch_issues(request) or { panic(err) }
		assert page.open_count > 0 && page.closed_count > 0
		assert page.issues.len > 0 && page.issues.all(it.kind == .prs && it.list_state() == state)
		if page.has_next {
			next := fetch_issues(FetchRequest{ ...request, cursor: page.cursor }) or { panic(err) }
			assert next.issues.len > 0
			assert next.issues.all(it.number !in page.issues.map(it.number))
		}
		pr := page.issues.filter(it.comments.total > 0)[0] or { page.issues[0] }
		detail_request := DetailRequest{ kind: .prs, repo: repo, number: pr.number, limit: 10 }
		body := fetch_detail_part(detail_request, .body) or { panic(err) }
		assert body.issue.kind == .prs && body.issue.number == pr.number
		assert body.issue.base_ref != '' && body.issue.head_ref != ''
		comments := fetch_detail_part(detail_request, .comments) or { panic(err) }
		assert comments.issue.kind == .prs && comments.comments.all(it.id != '')
		complete := fetch_detail(detail_request) or { panic(err) }
		assert complete.issue.number == pr.number && complete.issue.kind == .prs
	}
}

fn test_pr_list_shows_opened_and_merged_times() {
	now := time.parse_iso8601('2026-10-10T12:00:00Z') or { panic(err) }
	merged := Issue{ kind: .prs, number: 42, title: 'Merged PR', state: 'MERGED', author: User{ login: 'alice' }, created_at: '2026-10-01T12:00:00Z', merged_at: '2026-10-10T10:00:00Z' }
	app := App{ kind: .prs }
	for width in [320.0, 1000.0] {
		row := render_issue(&app, merged, width, 0, now)
		ui2.validate_element_tree(row) or { panic(err) }
		meta := row.children.filter(it.id == 'issue_42_meta')[0]
		assert meta.text.contains('alice opened 9d ago · merged 2h ago')
		if width == 320 { assert meta.text_style.lines >= 2 && meta.frame.height == meta.text_style.lines * 16 }
	}
	for issue in [Issue{ ...merged, state: 'OPEN' }, Issue{ ...merged, state: 'CLOSED' },
		Issue{ ...merged, merged_at: '' }, Issue{ ...merged, kind: .issues }] {
		row := render_issue(&app, issue, 1000, 0, now)
		meta := row.children.filter(it.id == 'issue_42_meta')[0]
		assert meta.text.contains('opened 9d ago') && !meta.text.contains(' · merged ')
	}
}

fn test_pr_conflicts_decode_in_lists_and_details_without_treating_unknown_as_conflicting() {
	for value in ['"CONFLICTING"', '"MERGEABLE"', '"UNKNOWN"', 'null'] {
		page := decode_page(pr_response.replace('"isDraft":true', '"isDraft":true,"mergeable":${value}')) or { panic(err) }
		pr := page.issues[0]
		assert pr.has_merge_conflicts() == (value == '"CONFLICTING"')
		assert pr.status() == 'Draft'
		for part in [DetailPart.body, .complete] {
			detail := decode_detail_part(pr_detail_response.replace('"state":"MERGED"', '"state":"OPEN","mergeable":${value}'), part) or { panic(err) }
			assert detail.issue.mergeable == pr.mergeable
			assert detail.issue.has_merge_conflicts() == pr.has_merge_conflicts()
		}
	}
	assert !(decode_page(pr_response) or { panic(err) }).issues[0].has_merge_conflicts()
}

fn test_pr_list_conflict_badge_stays_visible_in_both_densities_and_narrow_rows() {
	now := time.now()
	pr := Issue{ kind: .prs, number: 42, title: 'A long pull request title '.repeat(5), state: 'OPEN', mergeable: 'CONFLICTING',
		labels: LabelConnection{ nodes: [IssueLabel{ name: 'A long label', color: 'abcdef' }] } }
	for compact in [false, true] {
		app := App{ kind: .prs, compact: compact }
		for width in [320.0, 800.0, 1440.0] {
			for draft in [false, true] {
				row := render_issue(&app, Issue{ ...pr, is_draft: draft }, width, 0, now)
				badge := row.children.filter(it.id == 'issue_42_conflicts')[0]
				assert badge.children[0].text == 'Conflicts' && badge.children[0].text_style.color == red
				assert badge.tooltip.contains('squash merging')
				assert badge.frame.x + badge.frame.width <= width
				meta := row.children.filter(it.id == 'issue_42_meta')[0]
				assert meta.frame.y >= badge.frame.y + badge.frame.height
				for element in row.children.filter(it.id == 'issue_42_title' || it.id.starts_with('issue_42_label_')) {
					assert element.frame.y + element.frame.height <= badge.frame.y
				}
				ui2.validate_element_tree(row) or { panic(err) }
			}
		}
		for issue in [Issue{ ...pr, mergeable: 'MERGEABLE' }, Issue{ ...pr, mergeable: 'UNKNOWN' },
			Issue{ ...pr, mergeable: '' }, Issue{ ...pr, state: 'CLOSED' },
			Issue{ ...pr, state: 'MERGED' }, Issue{ ...pr, kind: .issues }] {
			assert !render_issue(&app, issue, 800, 0, now).children.any(it.id == 'issue_42_conflicts')
		}
	}
}
