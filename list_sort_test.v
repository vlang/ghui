module main

import ui2

fn sortable_prs() []Issue {
	return [
		Issue{ kind: .prs, number: 2, title: 'Pull request 2', state: 'OPEN', created_at: '2026-10-02T00:00:00Z', updated_at: '2026-10-03T00:00:00Z' },
		Issue{ kind: .prs, number: 1, title: 'Pull request 1', state: 'OPEN', created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-05T00:00:00Z', comments: Count{ total: 3 } },
		Issue{ kind: .prs, number: 4, title: 'Pull request 4', state: 'OPEN', created_at: '2026-10-03T00:00:00Z', comments: Count{ total: 1 } },
		Issue{ kind: .prs, number: 3, title: 'Pull request 3', state: 'OPEN', created_at: '2026-10-03T00:00:00Z', updated_at: '2026-10-04T00:00:00Z', comments: Count{ total: 3 } },
		Issue{ kind: .prs, number: 5, title: 'Pull request 5', state: 'OPEN', created_at: '2026-10-03T00:00:00Z', updated_at: '2026-10-04T00:00:00Z', comments: Count{ total: 3 } },
	]
}

fn test_pr_sort_uses_creation_activity_and_comments_with_deterministic_ties() {
	source := sortable_prs()
	expected := {
		'Newest':                 [5, 4, 3, 2, 1]
		'Oldest':                 [1, 2, 3, 4, 5]
		'Recently updated':       [1, 5, 3, 4, 2]
		'Least recently updated': [2, 4, 3, 5, 1]
		'Most commented':         [5, 3, 1, 4, 2]
		'Least commented':        [2, 4, 5, 3, 1]
	}
	for sort, numbers in expected {
		assert sort_issues(source, sort).map(it.number) == numbers
		assert source.map(it.number) == [2, 1, 4, 3, 5]
		assert sort_issues([]Issue{}, sort).len == 0
		assert sort_issues(source[..1], sort) == source[..1]
	}
}

fn test_pr_sort_changes_preserve_filters_selection_and_incoming_pages() {
	expected := {
		'Newest':                 [5, 4, 3, 2, 1, 6]
		'Oldest':                 [6, 1, 2, 3, 4, 5]
		'Recently updated':       [6, 1, 5, 3, 4, 2]
		'Least recently updated': [2, 4, 3, 5, 1, 6]
		'Most commented':         [6, 5, 3, 1, 4, 2]
		'Least commented':        [2, 4, 5, 3, 1, 6]
	}
	for sort, numbers in expected {
		mut app := App{ kind: .prs, issues: sortable_prs(), search: 'Pull', cursor: 'next', has_next: true }
		app.toggle_selection(3)
		request := app.begin_fetch(true)
		app.change_sort(sort)
		assert app.sort == sort
		assert app.generation == request.generation && !cancelled(request.cancel)
		assert app.cursor == 'next' && app.has_next && app.loading
		assert app.search == 'Pull' && app.selected[3]
		app.apply_result(FetchResult{
			request: request
			page:    IssuePage{
				issues:   [Issue{ kind: .prs, number: 6, title: 'Pull request 6', state: 'OPEN', created_at: '2026-09-30T00:00:00Z', updated_at: '2026-10-06T00:00:00Z', comments: Count{ total: 8 } }]
				cursor:   'older'
				has_next: true
			}
		})
		assert app.visible_issues().map(it.number) == numbers
		assert app.cursor == 'older' && !app.loading && app.selected[3]
		app.change_state('CLOSED')
		app.change_state('OPEN')
		assert app.issues.map(it.number) == numbers
		app.change_sort('Unknown')
		assert app.sort == sort && app.issues.map(it.number) == numbers
	}
}

fn test_sort_menu_exposes_all_orders_in_narrow_and_wide_headers() {
	for kind in [ItemKind.issues, .prs] {
		for width in [764.0, 1404.0] {
			mut app := App{ kind: kind }
			for sort in issue_sort_options {
				app.change_sort(sort)
				header := render_header(&app, width, if width >= 1180 { 48.0 } else { 86.0 }, []Issue{})
				ui2.validate_element_tree(header) or { panic(err) }
				menu := header.children.filter(it.id == 'sort')[0]
				assert menu.text == sort
				assert menu.menu.map(it.title) == ['Newest', 'Oldest', 'Most commented',
					'Least commented', 'Recently updated', 'Least recently updated']
				assert menu.accessibility_label == 'Sort ${kind.label()}'
				assignee := header.children.filter(it.id == 'assignee')[0]
				label := header.children.filter(it.id == 'sort_label')[0]
				assert assignee.frame.x + assignee.frame.width <= label.frame.x
				assert label.frame.x + label.frame.width <= menu.frame.x
				assert menu.frame.x + menu.frame.width < width
			}
		}
	}
}
