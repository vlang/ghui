module main

import math
import strconv
import ui2

fn (mut app App) show_open_pr_dialog(previous_focus string) {
	if app.open_pr_visible { return }
	app.open_pr_visible = true
	app.open_pr_text = ''
	app.open_pr_error = ''
	app.open_pr_previous_focus = previous_focus
}

fn (mut app App) close_open_pr_dialog() {
	app.open_pr_visible = false
	app.open_pr_text = ''
	app.open_pr_error = ''
	app.open_pr_previous_focus = ''
}

fn parse_pr_number(text string) !int {
	number := text.trim_space().trim_string_left('#')
	if number == '' || !number.bytes().all(it.is_digit()) {
		return error('Enter a valid PR number greater than zero.')
	}
	value := strconv.atoi(number) or {
		return error('Enter a valid PR number greater than zero.')
	}
	if value <= 0 { return error('Enter a valid PR number greater than zero.') }
	return value
}

fn (mut app App) submit_open_pr(text string) ?GithubDestination {
	if !app.open_pr_visible { return none }
	app.open_pr_text = text
	number := parse_pr_number(text) or {
		app.open_pr_error = err.msg()
		return none
	}
	app.close_open_pr_dialog()
	return GithubDestination{ repo: app.repo, kind: .prs, number: number }
}

fn handle_open_pr_key(key ui2.KeyEvent) {
	if !app_state.open_pr_visible { return }
	match key.code {
		.escape {
			ui2.consume_key()
			handle_event('cancel_open_pr')
		}
		.tab {
			ui2.consume_key()
			ids := ['open_pr_number', 'cancel_open_pr', 'submit_open_pr']
			index := ids.index(ui2.focused_id())
			start := if index >= 0 { index } else { 0 }
			for offset in 1 .. ids.len + 1 {
				next := (start + ids.len + offset * if key.shift { -1 } else { 1 }) % ids.len
				ui2.focus(ids[next])
				// macOS may skip buttons when Full Keyboard Access is disabled.
				if ui2.focused_id() == ids[next] { return }
			}
		}
		else {}
	}
}

fn render_open_pr_dialog(app &App, bounds ui2.Rect) ui2.Element {
	width := math.max(1, math.min(420, bounds.width - 24))
	field := ui2.text_field_with_change_and_submit('open_pr_number', 'submit_open_pr',
		'PR number, e.g. 42', app.open_pr_text, ui2.rect(20, 78, width - 40, 36),
		bordered_box(0xffffff, 6), text_style(15, ink, false), 0)
	content := ui2.view('open_pr_content', ui2.rect(0, 0, width, 204),
		ui2.BoxStyle{ transparent: true }, [
			ui2.label('open_pr_title', 'Open pull request', ui2.rect(20, 16, width - 40, 26),
				text_style(18, ink, true)),
			ui2.label('open_pr_repository', app.repo.str(), ui2.rect(20, 46, width - 40, 20),
				text_style(13, muted, false)),
			ui2.Element{ ...field, autocorrect: false, accessibility_label: 'Pull request number' },
			ui2.label('open_pr_error', app.open_pr_error, ui2.rect(20, 118, width - 40, 22),
				text_style(12, red, false)),
			ui2.button('cancel_open_pr', 'Cancel', ui2.rect(width - 200, 154, 82, 30),
				bordered_box(subtle, 6), ui2.TextStyle{ size: 13, color: ink, align: .center }),
			ui2.button('submit_open_pr', 'Open PR', ui2.rect(width - 106, 154, 86, 30),
				box(blue, 6), ui2.TextStyle{ size: 13, color: 0xffffff, bold: true, align: .center }),
		])
	return ui2.modal_view(
		id:                'open_pr_dialog'
		frame:             bounds
		open:              app.open_pr_visible
		dismiss_action_id: 'cancel_open_pr'
		content_width:     width
		content_height:    204
		overlay_box:       ui2.BoxStyle{ transparent: true }
		content_box:       bordered_box(0xffffff, 10)
		content:           content
	) or { content }
}
