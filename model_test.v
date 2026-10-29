module main

import ui2

fn example_app() App {
	return App{
		repo:   Repository{ owner: 'vlang', name: 'v' }
		issues: [
			Issue{
				number:     1
				title:      'Compiler regression'
				state:      'OPEN'
				created_at: '2026-10-02T00:00:00Z'
				author:     User{ login: 'alice' }
				labels:     LabelConnection{ nodes: [IssueLabel{ name: 'Bug', color: 'd73a4a' }] }
				assignees:  UserConnection{ nodes: [User{ login: 'bob' }] }
				milestone:  Milestone{ title: '0.6' }
			},
			Issue{ number: 2, title: 'Add widgets', state: 'OPEN', author: User{ login: 'bob' }, created_at: '2026-10-01T00:00:00Z' },
		]
	}
}

fn test_filters_combine_and_search_accepts_issue_numbers() {
	mut app := example_app()
	app.search = 'REGRESSION'
	assert app.visible_issues().map(it.number) == [1]
	app.search = '#2'
	assert app.visible_issues().map(it.number) == [2]
	app.search = ''
	app.author = 'alice'
	app.label = 'Bug'
	app.assignee = 'bob'
	app.milestone = '0.6'
	assert app.visible_issues().map(it.number) == [1]
	app.label = 'Enhancement'
	assert app.visible_issues().len == 0
	app.clear_filters()
	assert app.visible_issues().len == 2
	assert app.filter_options('Author') == ['Author', 'alice', 'bob']
}

fn test_text_filter_updates_loaded_issue_and_pr_rows_while_loading() {
	for kind in [ItemKind.issues, .prs] {
		mut app := example_app()
		app.kind = kind
		app.issues = app.issues.map(Issue{ ...it, kind: kind })
		app.cursor = 'next-page'
		app.has_next = true
		request := app.begin_fetch(true)
		for query in ['  REGRESSION  ', 'ALICE', '#1', '1'] {
			app.search = query
			assert app.visible_issues().map(it.number) == [1]
		}
		app.search = 'no matching title'
		assert app.visible_issues().len == 0
		rows := render_issues(&app, app.visible_issues(), 800, 600, 48).children
		assert rows.any(it.id == 'empty_title' && it.text.contains('match your filters'))
		assert !rows.any(it.id.starts_with('skeleton_'))
		app.clear_filters()
		assert app.visible_issues().map(it.number) == [1, 2]
		assert app.issues.len == 2 && app.cursor == 'next-page' && app.has_next
		assert app.loading && app.generation == request.generation && !cancelled(request.cancel)
	}
}

fn test_stale_fetch_cannot_replace_the_active_tab() {
	mut app := example_app()
	old_request := app.begin_fetch(false)
	app.change_state('CLOSED')
	new_request := app.begin_fetch(false)
	app.apply_result(FetchResult{ request: old_request, page: IssuePage{ issues: [Issue{ number: 99 }] } })
	assert app.loading
	assert app.issues.len == 0
	app.apply_result(FetchResult{ request: new_request, page: IssuePage{ issues: [Issue{ number: 3, state: 'CLOSED' }] } })
	assert !app.loading
	assert app.loaded_state == 'CLOSED'
	assert app.issues[0].number == 3
}

fn test_failed_refresh_keeps_the_last_successful_data() {
	mut app := example_app()
	app.search = 'Compiler'
	request := app.begin_fetch(false)
	app.apply_result(FetchResult{ request: request, error: 'Network unavailable' })
	assert !app.loading
	assert app.error == 'Network unavailable'
	assert app.issues.len == 2
	assert app.search == 'Compiler'
}

fn test_pagination_deduplicates_issues() {
	mut app := example_app()
	app.cursor = 'next'
	request := app.begin_fetch(true)
	assert request.cursor == 'next'
	app.apply_result(FetchResult{
		request: request
		page:    IssuePage{
			issues:       [Issue{ number: 2 }, Issue{ number: 3 }, Issue{ number: 3 }]
			closed_count: 10941
			has_next:     true
			cursor:       'third'
		}
	})
	assert app.issues.map(it.number) == [1, 2, 3]
	assert app.closed_count == 10941
	assert app.cursor == 'third'
}

fn test_partial_issue_batches_are_visible_before_fetch_finishes() {
	mut app := App{}
	request := app.begin_fetch(false)
	app.apply_result(FetchResult{
		request: request
		page:    IssuePage{ issues: [Issue{ number: 1, created_at: '2026-10-02T00:00:00Z' }], open_count: 80, has_next: true, cursor: 'first' }
		done:    false
	})
	assert app.loading
	assert app.list_received
	assert app.visible_issues().map(it.number) == [1]
	app.toggle_selection(1)
	app.apply_result(FetchResult{
		request: request
		page:    IssuePage{
			issues:     [
				Issue{ number: 1, created_at: '2026-10-02T00:00:00Z' },
				Issue{ number: 2, created_at: '2026-10-01T00:00:00Z' },
			]
			open_count: 80
			has_next:   true
			cursor:     'second'
		}
	})
	assert !app.loading
	assert app.issues.map(it.number) == [1, 2]
	assert app.cursor == 'second'
	assert app.selected[1]
}

fn test_refresh_keeps_cached_rows_until_new_batches_finish() {
	mut app := example_app()
	request := app.begin_fetch(false)
	app.apply_result(FetchResult{
		request: request
		page:    IssuePage{
			issues: [
				Issue{ number: 3, state: 'OPEN', created_at: '2026-10-03T00:00:00Z' },
				Issue{ number: 1, state: 'OPEN', created_at: '2026-10-02T00:00:00Z' },
			]
		}
		done:    false
	})
	assert app.issues.map(it.number) == [3, 1, 2]
	app.apply_result(FetchResult{
		request: request
		page:    IssuePage{
			issues: [
				Issue{ number: 3, state: 'OPEN', created_at: '2026-10-03T00:00:00Z' },
				Issue{ number: 1, state: 'OPEN', created_at: '2026-10-02T00:00:00Z' },
			]
		}
	})
	assert app.issues.map(it.number) == [3, 1]
	app.change_state('CLOSED')
	app.change_state('OPEN')
	assert app.issues.map(it.number) == [3, 1]
	app.change_sort('Oldest')
	assert app.issues.map(it.number) == [1, 3]
	app.change_sort('Newest')
	assert app.issues.map(it.number) == [3, 1]
}

fn test_local_sort_preserves_filters_selection_and_in_flight_pagination() {
	mut app := App{
		issues:   [
			Issue{ number: 1, title: 'First', created_at: '2026-01-01T00:00:00Z', updated_at: '2026-10-03T00:00:00Z' },
			Issue{ number: 2, title: 'Second', created_at: '2026-01-02T00:00:00Z', updated_at: '2026-10-01T00:00:00Z' },
		]
		cursor:   'next-newest-page'
		has_next: true
	}
	app.search = 'First'
	app.toggle_selection(1)
	request := app.begin_fetch(true)
	app.change_sort('Oldest')
	assert app.issues.map(it.number) == [1, 2]
	app.change_sort('Recently updated')
	assert app.issues.map(it.number) == [1, 2]
	app.change_sort('Newest')
	assert app.issues.map(it.number) == [2, 1]
	assert app.generation == request.generation
	assert !cancelled(request.cancel)
	assert app.cursor == 'next-newest-page' && app.has_next && app.loading
	assert app.search == 'First' && app.selected[1]
	app.change_sort('Oldest')
	app.apply_result(FetchResult{
		request: request
		page:    IssuePage{ issues: [Issue{ number: 3, created_at: '2025-12-01T00:00:00Z' }], cursor: 'older', has_next: true }
	})
	assert app.issues.map(it.number) == [3, 1, 2]
	assert app.sort == 'Oldest' && app.cursor == 'older'
}

fn test_changing_list_query_cancels_previous_work() {
	mut app := App{}
	first := app.begin_fetch(false)
	second := app.begin_fetch(false)
	assert cancelled(first.cancel)
	assert !cancelled(second.cancel)
}

fn test_select_all_only_toggles_visible_rows() {
	mut app := example_app()
	app.search = 'Compiler'
	app.toggle_all()
	assert app.selected.len == 1
	assert app.selected[1]
	app.search = ''
	assert !app.all_visible_selected(app.visible_issues())
	app.toggle_all()
	assert app.selected.len == 2
	app.toggle_all()
	assert app.selected.len == 0
}

fn test_all_ui_states_have_valid_identity() {
	mut app := example_app()
	for width in [800.0, 1440.0] {
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
		app.loading = true
		app.issues = []Issue{}
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
		app.loading = false
		app.error = 'Network unavailable'
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
		app = example_app()
	}
}
