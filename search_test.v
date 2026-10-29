module main

import time
import ui2

fn search_example_app() App {
	return App{
		repo:   Repository{ owner: 'vlang', name: 'v' }
		issues: [
			Issue{ number: 1, title: 'Compiler regression', state: 'OPEN' },
			Issue{ number: 2, title: 'Add widgets', state: 'OPEN' },
		]
	}
}

fn test_search_keeps_pending_text_separate_from_the_visible_rows() {
	for kind in [ItemKind.issues, .prs] {
		mut app := search_example_app()
		app.kind = kind
		app.issues = app.issues.map(Issue{ ...it, kind: kind })
		app.cursor = 'next-page'
		app.has_next = true
		fetch := app.begin_fetch(true)
		first := app.begin_search('Compiler') or { panic('Search did not start.') }
		assert app.search_text() == 'Compiler' && app.search == ''
		assert app.visible_issues().len == 2
		field := render_app(&app, ui2.rect(0, 0, 800, 860)).children.filter(it.id == 'search')[0]
		assert field.text == 'Compiler' && field.emit_change
		assert app.begin_search('Compiler') == none
		latest := app.begin_search('#2') or { panic('Search did not restart.') }
		assert cancelled(first.cancel) && !app.apply_search_result(first)
		assert app.visible_issues().len == 2
		assert app.apply_search_result(latest)
		assert app.search == '#2' && app.visible_issues().map(it.number) == [2]
		assert !app.apply_search_result(latest)
		assert app.loading && app.generation == fetch.generation && !cancelled(fetch.cancel)
		assert app.cursor == 'next-page' && app.has_next
	}
}

fn test_pending_search_cannot_restore_filters_after_clear_or_navigation() {
	mut app := search_example_app()
	cleared := app.begin_search('Compiler') or { panic('Search did not start.') }
	app.clear_filters()
	assert cancelled(cleared.cancel) && !app.apply_search_result(cleared)
	assert app.search_text() == '' && app.visible_issues().len == 2
	state_change := app.begin_search('Compiler') or { panic('Search did not start.') }
	app.change_state('CLOSED')
	assert cancelled(state_change.cancel) && !app.apply_search_result(state_change)
	kind_change := app.begin_search('Compiler') or { panic('Search did not start.') }
	app.change_kind(.prs)
	assert cancelled(kind_change.cancel) && !app.apply_search_result(kind_change)
	repo_change := app.begin_search('Compiler') or { panic('Search did not start.') }
	app.change_repository(Repository{ owner: 'other', name: 'repo' })
	assert cancelled(repo_change.cancel) && !app.apply_search_result(repo_change)
	assert app.search_text() == '' && !app.search_pending
}

fn test_returning_to_the_applied_query_cancels_pending_search() {
	mut app := search_example_app()
	app.search = 'Compiler'
	pending := app.begin_search('Add') or { panic('Search did not start.') }
	assert app.begin_search('Compiler') == none
	assert cancelled(pending.cancel) && !app.apply_search_result(pending)
	assert app.search_text() == 'Compiler' && !app.search_pending
	assert app.visible_issues().map(it.number) == [1]
}

fn test_search_timer_waits_100_ms_and_only_delivers_the_latest_edit() {
	mut app := search_example_app()
	first := app.begin_search('C') or { panic('Search did not start.') }
	spawn search_in_background(first, app.search_results)
	latest := app.begin_search('Compiler') or { panic('Search did not restart.') }
	started := time.sys_mono_now()
	spawn search_in_background(latest, app.search_results)
	select {
		result := <-app.search_results {
			assert time.sys_mono_now() - started >= search_delay
			assert result.generation == latest.generation && result.text == 'Compiler'
			assert app.apply_search_result(result)
			visible := app.visible_issues()
			assert visible.len == 1 && visible[0].number == 1
		}
		2 * time.second {
			panic('The debounced search did not finish.')
		}
	}
	select {
		_ := <-app.search_results {
			assert false, 'A cancelled search was delivered.'
		}
		else {
		}
	}
}
