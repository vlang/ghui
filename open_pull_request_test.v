module main

import ui2

fn test_pr_number_accepts_numbers_and_rejects_invalid_or_overflowing_input() {
	for text in ['42', ' 42 ', '#42', ' #42 ', '00042'] {
		assert (parse_pr_number(text) or { panic(err) }) == 42
	}
	assert (parse_pr_number('2147483647') or { panic(err) }) == 2147483647
	for text in ['', ' ', '#', '0', '#0', '-1', '+42', '42abc', '4 2', '##42', '2147483648',
		'99999999999999999999999999999'] {
		if _ := parse_pr_number(text) {
			assert false, text
		}
	}
}

fn test_open_pr_validation_retains_input_and_opens_an_unloaded_pr_in_current_repository() {
	mut app := App{ repo: Repository{ owner: 'alice', name: 'project' } }
	app.open_issue(7)
	app.show_open_pr_dialog('new_comment_text')
	assert app.submit_open_pr('not a number') == none
	assert app.open_pr_visible && app.open_pr_text == 'not a number'
	assert app.open_pr_error != '' && app.active_issue == 7 && app.kind == .issues
	destination := app.submit_open_pr(' #42 ') or { panic('The PR was not accepted.') }
	assert destination.repo == app.repo && destination.kind == .prs && destination.number == 42
	assert !app.open_pr_visible && app.open_pr_error == ''
	app.change_kind(destination.kind)
	app.open_issue(destination.number)
	request := app.begin_detail_fetch(false)
	assert request.kind == .prs && request.number == 42 && request.repo == destination.repo
	assert app.active_issue == 42 && app.detail_loading
	assert app.submit_open_pr('43') == none
}

fn test_open_pr_dialog_is_available_on_list_detail_and_diff_and_cancel_preserves_navigation() {
	for view in ['list', 'detail', 'diff'] {
		mut app := App{
			repo:        Repository{ owner: 'alice', name: 'project' }
			kind:        .prs
			search:      'existing filter'
			list_scroll: 240
		}
		if view != 'list' { app.open_issue(7) }
		if view == 'diff' { app.begin_diff_fetch() or { panic('Diff did not open.') } }
		active_issue := app.active_issue
		app.show_open_pr_dialog('search')
		app.open_pr_text = '42'
		app.show_open_pr_dialog('open_pr_number')
		assert app.open_pr_text == '42' && app.open_pr_previous_focus == 'search'
		for width in [480.0, 800.0, 1440.0] {
			screen := render_app(&app, ui2.rect(0, 0, width, 860))
			ui2.validate_element_tree(screen) or { panic(err) }
			dialog := screen.children.last()
			assert dialog.id == 'open_pr_dialog' && dialog.accessibility_role == 'dialog'
			field := dialog.children[2].children.filter(it.id == 'open_pr_number')[0]
			assert field.submit_id == 'submit_open_pr' && field.text == '42'
		}
		app.close_open_pr_dialog()
		assert !app.open_pr_visible && app.active_issue == active_issue
		assert app.diff_visible == (view == 'diff')
		assert app.search == 'existing filter' && app.list_scroll == 240
		assert !render_app(&app, ui2.rect(0, 0, 800, 860)).children.any(it.id == 'open_pr_dialog')
	}
}
