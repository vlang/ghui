module main

fn test_github_urls_select_repository_list_discussion_and_diff() {
	for target in ['https://github.com/vlang/v', 'http://github.com/vlang/v/',
		'ghui://github.com/vlang/v', 'https://WWW.GITHUB.COM/vlang/v'] {
		actual := parse_github_destination(target) or { panic(err) }
		assert actual.repo.str() == 'vlang/v'
		assert actual.kind == .issues && actual.number == 0
	}
	for path in ['pulls', 'pull'] {
		actual := parse_github_destination('https://github.com/vlang/v/${path}') or { panic(err) }
		assert actual.kind == .prs && actual.number == 0
	}
	issue := parse_github_destination('https://github.com/alex/repo/issues/42?utm_source=slack') or { panic(err) }
	assert issue.repo.str() == 'alex/repo' && issue.number == 42 && issue.needs_lookup
	pr := parse_github_destination('https://github.com/vlang/v/pull/42') or { panic(err) }
	assert pr.kind == .prs && pr.number == 42 && !pr.needs_lookup && !pr.diff
	diff := parse_github_destination('https://github.com/vlang/v/pull/42/files') or { panic(err) }
	assert diff.kind == .prs && diff.number == 42 && diff.diff
}

fn test_unsupported_urls_are_forwarded_without_losing_the_destination() {
	for target in ['https://github.com', 'https://github.com/alex',
		'https://github.com/vlang/v#readme', 'https://github.com/vlang/v/issues?q=is%3Aclosed',
		'https://github.com/vlang/v/blob/master/main.v', 'https://github.com/vlang/v/actions',
		'https://github.com/vlang/v/issues/new', 'https://github.com/vlang/v/issues/0',
		'https://github.com/vlang/v/issues/-42', 'https://github.com/vlang/v/issues/2147483648',
		'https://github.com/vlang/v/issues/42abc', 'https://github.com/vlang/v/pulls/42',
		'https://github.com/vlang/v/pull/42/commits', 'https://github.com/vlang/v/issues/42/files',
		'https://github.com/vlang/v/pull/42/files/other',
		'https://github.com/vlang/v/issues/42#issuecomment-123',
		'https://github.com/vlang/v/pull/42/files#diff-abc',
		'https://github.com.evil.example/vlang/v/issues/42', 'https://example.com/vlang/v/issues/42',
		'https://github.com@evil.example/vlang/v', 'https://user@github.com/vlang/v',
		'file://github.com/vlang/v', 'https://github.com/vlang/../issues/42', 'invalid URL'] {
		parse_github_destination(target) or { continue }
		assert false, target
	}
}

fn test_repository_switch_cancels_old_reads_and_keeps_drafts_separate() {
	mut app := App{
		repo:   Repository{ owner: 'vlang', name: 'v' }
		issues: [Issue{ number: 1, title: 'Issue', state: 'OPEN' }]
	}
	app.comment_drafts[1] = 'Unsent reply'
	old_page := app.begin_fetch(false)
	app.open_issue(1)
	old_detail := app.begin_detail_fetch(false)
	old_reference := app.begin_reference(42)
	app.detail_cache[42] = CachedDetail{ detail: IssueDetail{ issue: Issue{ kind: .prs, number: 42 } } }
	app.list_cache['issues_OPEN'] = IssuePage{ issues: app.issues }
	app.selected[1] = true
	app.search = 'old search'
	app.comment_loading = true
	app.close_loading = true
	app.merge_loading = true
	assert app.change_repository(Repository{ owner: 'vlang', name: 'ui2' })
	assert cancelled(old_page.cancel) && cancelled(old_detail.cancel) && cancelled(old_reference.cancel)
	assert app.active_issue == 0 && app.issues.len == 0
	assert app.detail_cache.len == 0 && app.list_cache.len == 0 && app.selected.len == 0
	assert app.search == '' && app.comment_drafts.len == 0
	assert !app.comment_loading && !app.close_loading && !app.merge_loading
	app.apply_result(FetchResult{ request: old_page, page: IssuePage{ issues: [Issue{ number: 42 }] }, done: true })
	app.apply_detail_result(DetailResult{ request: old_detail, detail: IssueDetail{ issue: Issue{ number: 1 } } })
	if _ := app.apply_reference_result(ReferenceResult{ request: old_reference, kind: .prs }) {
		assert false
	}
	assert app.issues.len == 0 && !app.detail_loaded
	app.comment_drafts[1] = 'Reply in other repository'
	assert app.change_repository(Repository{ owner: 'vlang', name: 'v' })
	assert app.comment_drafts[1] == 'Unsent reply'
	assert !app.change_repository(Repository{ owner: 'VLANG', name: 'V' })
	assert app.comment_drafts[1] == 'Unsent reply'
}
