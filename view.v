module main

import math
import strconv
import time
import ui2

const ink = u32(0x25292e)
const muted = u32(0x59636e)
const border = u32(0xd1d9e0)
const subtle = u32(0xf6f8fa)
const green = u32(0x1a7f37)
const purple = u32(0x8250df)
const blue = u32(0x0969da)
const red = u32(0xcf222e)

fn with_github_url_menu(title ui2.Element, issue Issue, repo Repository) ui2.Element {
	target := issue.github_url(repo)
	mut menu := [ui2.MenuEntry{ id: 'copy_github_url:${target}', title: 'Copy GitHub URL' }]
	if issue.kind == .prs {
		menu << ui2.MenuEntry{ id: 'review_on_chatgpt:${target}', title: 'Review on ChatGPT.com' }
	}
	return ui2.Element{
		...title
		menu: menu
	}
}

fn render_mode_switch(app &App, x f64) ui2.Element {
	return ui2.view('mode_switch', ui2.rect(x, 12, 144, 30), bordered_box(0xe8ecf0, 6), [
		ui2.button('mode_issues', 'Issues', ui2.rect(1, 1, 78, 28),
			box(if app.kind == .issues { u32(0xffffff) } else { u32(0xe8ecf0) }, 5),
			ui2.TextStyle{ size: 13, color: ink, bold: app.kind == .issues, align: .center }),
		ui2.button('mode_prs', 'PRs', ui2.rect(79, 1, 64, 28),
			box(if app.kind == .prs { u32(0xffffff) } else { u32(0xe8ecf0) }, 5),
			ui2.TextStyle{ size: 13, color: ink, bold: app.kind == .prs, align: .center }),
	])
}

fn item_status_color(issue Issue) u32 {
	return if issue.kind == .prs && issue.state == 'MERGED' {
		purple
	} else if issue.kind == .prs && issue.state == 'CLOSED' {
		red
	} else if issue.state == 'OPEN' && !issue.is_draft {
		green
	} else if issue.kind == .issues && issue.state == 'CLOSED' && issue.state_reason != 'NOT_PLANNED' {
		purple
	} else {
		muted
	}
}

fn text_style(size f64, color u32, bold bool) ui2.TextStyle {
	return ui2.TextStyle{ size: size, color: color, bold: bold }
}

fn box(bg u32, radius f64) ui2.BoxStyle {
	return ui2.BoxStyle{ bg: bg, radius: radius }
}

fn bordered_box(bg u32, radius f64) ui2.BoxStyle {
	return ui2.BoxStyle{
		bg:            bg
		radius:        radius
		border_color:  border
		border_left:   1
		border_top:    1
		border_right:  1
		border_bottom: 1
	}
}

fn render_app(app &App, bounds ui2.Rect) ui2.Element {
	content := render_app_content(app, bounds)
	if !app.open_pr_visible { return content }
	mut children := content.children.clone()
	children << render_open_pr_dialog(app, bounds)
	return ui2.Element{ ...content, children: children }
}

fn render_app_content(app &App, bounds ui2.Rect) ui2.Element {
	if app.active_issue > 0 && app.diff_visible { return render_pr_diff(app, bounds) }
	if app.active_issue > 0 { return render_detail(app, bounds) }
	w := bounds.width
	h := bounds.height
	margin := if w >= 800 { 18.0 } else { 12.0 }
	width := math.max(1, w - margin * 2)
	visible := app.visible_issues()
	items := if app.kind == .prs { 'pull requests' } else { 'issues' }
	mut children := []ui2.Element{}
	children << render_mode_switch(app, margin)
	refresh := ui2.button('refresh', if app.loading { '↻  Refreshing…' } else { '↻  Refresh' },
		ui2.rect(margin + 156, 12, 132, 30), bordered_box(subtle, 6),
		ui2.TextStyle{ size: 13, color: ink, align: .center })
	children << ui2.Element{
		...refresh
		enabled:             !app.loading
		tooltip:             'Refresh ${items} (⌘R / Ctrl+R / F5)'
		accessibility_label: 'Refresh ${items}'
	}
	children << ui2.view('toolbar_separator', ui2.rect(margin + 306, 16, 1, 22), box(border, 0), [])
	children << ui2.label('repository', app.repo.str(), ui2.rect(margin + 326, 12, math.max(1, width - 432), 30),
		text_style(17, ink, true))
	if width > 700 {
		children << ui2.label('page_title', app.kind.label(), ui2.rect(w - margin - 80, 12, 80, 30),
			ui2.TextStyle{ size: 13, color: muted, align: .right })
	}
	filtered := app.search_text() != '' || app.author != 'Author' || app.label != 'Labels'
		|| app.assignee != 'Assignees' || app.milestone != 'Milestones'
	search_width := math.max(1, width - if filtered { 130.0 } else { 0.0 })
	search := ui2.text_field_with_change('search',
		'Filter loaded ${items} by title, #number or author…', app.search_text(),
		ui2.rect(margin, 54, search_width, 32), bordered_box(0xffffff, 6),
		text_style(13, ink, false), 0)
	children << ui2.Element{
		...search
		autocorrect:         false
		tooltip:             'Filter loaded ${items} locally after a 100 ms typing pause. Load more to include older ${items}. ⌘F / Ctrl+F'
		accessibility_label: 'Filter loaded ${items}'
	}
	if filtered {
		children << ui2.button('clear_filters', 'Clear filters', ui2.rect(w - margin - 120, 54, 120, 32),
			bordered_box(subtle, 6), text_style(12, muted, false))
	}
	mut top := 100.0
	if app.chatgpt_review_error != '' {
		notice := error_notice('chatgpt_review_error', app.chatgpt_review_error, width, top)
		children << ui2.Element{ ...notice, frame: ui2.rect(margin, top, width, notice.frame.height) }
		top += notice.frame.height + 14
	}
	if app.error != '' {
		children << ui2.view('error_banner', ui2.rect(margin, top, width, 90),
			ui2.BoxStyle{ bg: 0xffebe9, radius: 7, border_color: 0xff8182, border_left: 3 }, [
				ui2.label('error_heading', 'Could not load ${items}. Refresh to try again.',
					ui2.rect(16, 10, math.max(1, width - 32), 22), text_style(14, 0x82071e, true)),
				ui2.label('error_detail', app.error, ui2.rect(16, 36, math.max(1, width - 32), 44),
					ui2.TextStyle{ size: 12, color: 0x82071e, lines: 2, valign: .top }),
			])
		top += 106
	}
	header_height := if width >= 1180 { 48.0 } else { 86.0 }
	list_height := math.max(header_height + 60, h - top - 44)
	children << ui2.view('issue_list', ui2.rect(margin, top, width, list_height),
		bordered_box(0xffffff, 8), [
			render_header(app, width, header_height, visible),
			render_issues(app, visible, width, list_height - header_height - 2, header_height),
		])
	mut status := if app.error != '' {
		if app.issues.len > 0 {
			'Refresh failed · ${app.issues.len} previously loaded ${items} retained'
		} else {
			'Could not load ${items}'
		}
	} else if app.loading {
		if app.issues.len == 0 {
			'Loading ${items} from GitHub…'
		} else if app.list_received {
			'${visible.len} shown · loading more ${items}…'
		} else if app.list_cached {
			'${visible.len} stored ${items} shown · refreshing…'
		} else {
			'Refreshing ${items}…'
		}
	} else if app.loaded_state == '' {
		'Waiting for GitHub'
	} else {
		total := if app.state == 'OPEN' { app.open_count } else { app.closed_count }
		'${visible.len} shown · ${app.issues.len} of ${format_count(total)} ${app.state.to_lower()} loaded'
	}
	if app.selected.len > 0 { status += ' · ${app.selected.len} selected' }
	if app.storage_error != '' { status += ' · Could not save ${items} locally' }
	children << ui2.with_tooltip(ui2.label('status', status, ui2.rect(margin, top + list_height + 6, math.max(1, width - 320), 22),
		text_style(11, muted, false)), app.storage_error)
	if app.has_next {
		load_more := ui2.button('load_more', if app.loading {
			'Loading…'
		} else {
			'Load more ${app.kind.label().to_lower()}'
		},
			ui2.rect(w - margin - 152, top + list_height + 6, 152, 28), bordered_box(subtle, 6),
			text_style(12, ink, false))
		children << ui2.Element{ ...load_more, enabled: !app.loading }
	} else if app.updated != '' && !app.loading {
		children << ui2.label('updated', 'Updated at ${app.updated}',
			ui2.rect(w - margin - 180, top + list_height + 6, 180, 22),
			ui2.TextStyle{ size: 11, color: muted, align: .right })
	}
	return ui2.screen(0xffffff, children)
}

fn render_header(app &App, width f64, height f64, visible []Issue) ui2.Element {
	mut children := [
		ui2.checkbox('select_all', '', app.all_visible_selected(visible), ui2.rect(12, 12, 22, 24),
			text_style(12, muted, false)),
		ui2.button('open', 'Open', ui2.rect(40, 9, 64, 30), box(subtle, 0),
			text_style(14, if app.state == 'OPEN' { ink } else { muted }, app.state == 'OPEN')),
		ui2.with_action(ui2.button('open_count', if app.loaded_state == '' {
			'…'
		} else {
			format_count(app.open_count)
		},
			ui2.rect(100, 14, 48, 20), box(0xe8ecf0, 10), text_style(12, ink, true)), 'open'),
		ui2.button('closed', 'Closed', ui2.rect(164, 9, 74, 30), box(subtle, 0),
			text_style(14, if app.state == 'CLOSED' { ink } else { muted }, app.state == 'CLOSED')),
		ui2.with_action(ui2.button('closed_count', if app.loaded_state == '' {
			'…'
		} else {
			format_count(app.closed_count)
		},
			ui2.rect(234, 14, 72, 20), box(0xe8ecf0, 10), text_style(12, ink, true)), 'closed'),
	]
	if width > 430 {
		children << ui2.view('density', ui2.rect(width - 94, 8, 76, 32), bordered_box(0xe8ecf0, 6), [
			ui2.with_tooltip(ui2.button('comfortable', '▤', ui2.rect(1, 1, 37, 30),
				box(if app.compact { u32(0xe8ecf0) } else { u32(0xffffff) }, 5),
				text_style(21, muted, false)), 'Comfortable rows'),
			ui2.with_tooltip(ui2.button('compact', '☰', ui2.rect(38, 1, 37, 30),
				box(if app.compact { u32(0xffffff) } else { u32(0xe8ecf0) }, 5),
				text_style(18, muted, false)), 'Compact rows'),
		])
	}
	names := ['Author', 'Labels', 'Milestones', 'Assignees']
	ids := ['author', 'label', 'milestone', 'assignee']
	values := [app.author, app.label, app.milestone, app.assignee]
	wide := width >= 1180
	controls_width := if wide { 728.0 } else { width - 36 }
	sort_width := math.min(224, controls_width * 0.36)
	filter_width := (controls_width - sort_width) / 4 - 2
	start := if wide { width - 854 } else { 18.0 }
	y := if wide { 9.0 } else { 48.0 }
	for i, name in names {
		children << ui2.with_tooltip(ui2.dropdown(ids[i], values[i], app.filter_options(name),
			ui2.rect(start + i * (filter_width + 2), y, filter_width, 28),
			box(subtle, 5), text_style(12, muted, false)),
			'Filter the loaded ${app.kind.label()} by ${name.to_lower()}')
	}
	sort_x := start + 4 * (filter_width + 2)
	children << ui2.label('sort_label', 'Sort:', ui2.rect(sort_x, y, 34, 28),
		text_style(12, muted, false))
	sort_menu := ui2.dropdown('sort', app.sort, issue_sort_options,
		ui2.rect(sort_x + 34, y, sort_width - 34, 28), box(subtle, 5), text_style(12, muted, false))
	children << ui2.Element{
		...sort_menu
		tooltip: 'Sort loaded ${app.kind.label()} by creation date, latest activity (Recently updated), or comment count. Load more to include older ${app.kind.label()}.'
		accessibility_label: 'Sort ${app.kind.label()}'
	}
	return ui2.view('list_header', ui2.rect(1, 1, width - 2, height - 1),
		ui2.BoxStyle{ bg: subtle, border_color: border, border_bottom: 1 }, children)
}

fn render_issues(app &App, visible []Issue, width f64, height f64, top f64) ui2.Element {
	items := if app.kind == .prs { 'pull requests' } else { 'issues' }
	mut rows := []ui2.Element{}
	if visible.len == 0 && app.loading && app.issues.len == 0 {
		for i in 0 .. 10 {
			rows << ui2.view('skeleton_${i}', ui2.rect(0, i * 52, width - 2, 52),
				ui2.BoxStyle{ bg: 0xffffff, border_color: border, border_bottom: 1 }, [
					ui2.view('skeleton_icon_${i}', ui2.rect(40, 10, 18, 18), box(0xeaeef2, 9), []),
					ui2.view('skeleton_title_${i}', ui2.rect(64, 10, math.max(1, width * (0.65 - i % 3 * 0.09)), 14),
						box(0xeaeef2, 4), []),
					ui2.view('skeleton_meta_${i}', ui2.rect(64, 32, math.max(1, width * 0.28), 10), box(subtle, 3), []),
				])
		}
	} else if visible.len == 0 {
		title := if app.error != '' {
			'${app.kind.label()} could not be loaded'
		} else if app.issues.len > 0 {
			'No ${items} match your filters'
		} else {
			'No ${app.state.to_lower()} ${items}'
		}
		message := if app.error != '' {
			'Check the message above and use Refresh to try again.'
		} else if app.issues.len > 0 {
			'Try another search or clear the filters.'
		} else {
			'You’re all caught up.'
		}
		rows << ui2.label('empty_title', title, ui2.rect(24, 72, math.max(1, width - 48), 32),
			ui2.TextStyle{ size: 20, bold: true, color: ink, align: .center })
		rows << ui2.label('empty_description', message, ui2.rect(24, 114, math.max(1, width - 48), 28),
			ui2.TextStyle{ size: 14, color: muted, align: .center })
	} else {
		mut y := 0.0
		now := time.now()
		for issue in visible {
			row := render_issue(app, issue, width - 2, y, now)
			y += row.frame.height
			rows << row
		}
	}
	return ui2.scroll(app.list_scroll_id(), ui2.rect(1, top, width - 2, height), 0xffffff, rows)
}

// This estimate only chooses row height and where badges fit. UI2 performs
// the actual text layout; titles are kept intact and available as tooltips.
fn estimated_text_width(text string, size f64) f64 {
	mut width := 0.0
	for ch in text.runes() {
		width += size * if ch in [`i`, `l`, `I`, `!`, `.`, `,`, `:`, `;`, ` `, `'`] {
			0.3
		} else if ch in [`m`, `w`, `M`, `W`, `@`] {
			0.86
		} else if ch > 127 {
			0.85
		} else {
			0.56
		}
	}
	return width
}

fn render_issue(app &App, issue Issue, width f64, y f64, now time.Time) ui2.Element {
	id := 'issue_${issue.number}'
	selected := app.selected[issue.number] or { false }
	bg := if selected { u32(0xf0f7ff) } else { u32(0xffffff) }
	font := if app.compact { 13.0 } else { 14.0 }
	padding := if app.compact { 5.0 } else { 8.0 }
	available := math.max(60, width - 160)
	title_width := estimated_text_width(issue.title, font)
	lines := if title_width > available { 2 } else { 1 }
	title_height := lines * (font + 3)
	mut badge_width := 0.0
	for label in issue.labels.nodes { badge_width += estimated_text_width(label.name, 12) + 33 }
	inline_badges := title_width + badge_width + 16 < available
	badge_line := issue.labels.nodes.len > 0 && !inline_badges && !app.compact
	heading_height := if inline_badges && issue.labels.nodes.len > 0 { math.max(title_height, 22) } else { title_height }
	meta_y := padding + heading_height + 3 + if badge_line { 27.0 } else { 0.0 }
		+ if issue.has_merge_conflicts() { 22.0 } else { 0.0 }
	additions := '+${issue.additions}'
	deletions := '−${issue.deletions}'
	// Reserve room for bold digits and native label insets so counts stay complete.
	additions_width := additions.len * 8.4 + 8
	deletions_width := deletions.runes().len * 8.4 + 8
	diff_width := additions_width + 6 + deletions_width
	meta_width := width - 160 - if issue.kind == .prs { diff_width + 12 } else { 0.0 }
	meta_text := '#${issue.number}${if issue.kind == .prs && (issue.is_draft || issue.state == 'MERGED') {
		' · ${issue.status()}'
	} else {
		''
	}} · ${if issue.author.login == '' { 'ghost' } else { issue.author.login }} opened ${relative_time(issue.created_at, now)}${if issue.kind == .prs && issue.state == 'MERGED' && issue.merged_at != '' {
		' · merged ${relative_time(issue.merged_at, now)}'
	} else {
		''
	}}${app.chatgpt_review_marker(issue)}'
	// Allow the additional merge timestamp to wrap on narrow windows.
	meta_lines := if issue.kind == .prs && issue.state == 'MERGED' && issue.merged_at != ''
		&& estimated_text_width(meta_text, 11) > meta_width {
		int(math.min(6, math.max(2, math.ceil(estimated_text_width(meta_text, 11) / (math.max(1, meta_width) * 0.8)))))
	} else {
		1
	}
	meta_height := meta_lines * 16
	row_height := meta_y + meta_height + padding
	mut children := [
		ui2.checkbox('select_${issue.number}', '', selected, ui2.rect(12, padding, 22, 24),
			text_style(12, muted, false)),
		item_icon('${id}_status', issue, ui2.rect(40, padding, 18, 18), bg),
		with_github_url_menu(ui2.with_tooltip(ui2.label('${id}_title', issue.title,
			ui2.rect(64, padding, available, title_height),
			ui2.TextStyle{ size: font, color: ink, bold: true, lines: lines, valign: .top }), issue.title), issue, app.repo),
		ui2.label('${id}_meta', meta_text,
			ui2.rect(64, meta_y, math.max(1, meta_width), meta_height),
			ui2.TextStyle{ size: 11, color: muted, lines: meta_lines, valign: .top }),
	]
	if issue.has_merge_conflicts() {
		children << ui2.with_tooltip(ui2.view('${id}_conflicts', ui2.rect(64, meta_y - 22, 76, 18),
			box(0xffebe9, 9), [
				ui2.label('${id}_conflicts_text', 'Conflicts', ui2.rect(6, 0, 64, 18),
					ui2.TextStyle{ size: 11, color: red, bold: true, align: .center }),
			]), 'Resolve merge conflicts before squash merging.')
	}
	if issue.kind == .prs {
		children << ui2.with_tooltip(ui2.view('${id}_diff', ui2.rect(width - 96 - diff_width, meta_y, diff_width, 16),
			ui2.BoxStyle{ transparent: true }, [
				ui2.label('${id}_additions', additions, ui2.rect(0, 0, additions_width, 16),
					text_style(12, green, true)),
				ui2.label('${id}_deletions', deletions, ui2.rect(additions_width + 6, 0, deletions_width, 16),
					text_style(12, red, true)),
			]), '${issue.additions} lines added, ${issue.deletions} lines removed')
	}
	if selected {
		children << ui2.view('${id}_selected', ui2.rect(0, 0, 3, row_height), box(blue, 0), [])
	}
	if issue.labels.nodes.len > 0 && (inline_badges || badge_line) {
		mut x := if inline_badges { 64 + title_width + 12 } else { 64.0 }
		badge_y := if inline_badges { padding } else { padding + title_height + 5 }
		for i, label in issue.labels.nodes {
			label_width := estimated_text_width(label.name, 12) + 26
			if x + label_width > width - 106 {
				children << ui2.with_tooltip(ui2.label('${id}_extra_labels', '+${issue.labels.nodes.len - i}',
					ui2.rect(x, badge_y, 40, 22), text_style(12, muted, false)),
					issue.labels.nodes[i..].map(it.name).join(', '))
				break
			}
			color := strconv.parse_uint(label.color, 16, 32) or { u64(0x59636e) }
			children << ui2.view('${id}_label_${i}', ui2.rect(x, badge_y, label_width, 22), box(u32(color), 11), [
				ui2.label('${id}_label_text_${i}', label.name, ui2.rect(6, 0, label_width - 12, 22),
					ui2.TextStyle{ size: 12, bold: true, color: contrasting_text(u32(color)), align: .center }),
			])
			x += label_width + 6
		}
	}
	if issue.comments.total > 0 {
		children << ui2.with_tooltip(ui2.view('${id}_comments', ui2.rect(width - 78, row_height / 2 - 11, 60, 22),
			ui2.BoxStyle{ transparent: true }, [
				ui2.view('${id}_comment_icon', ui2.rect(0, 2, 15, 13),
					ui2.BoxStyle{
						bg:            bg
						radius:        2
						border_color:  muted
						border_left:   1.5
						border_top:    1.5
						border_right:  1.5
						border_bottom: 1.5
					}, []),
				ui2.label('${id}_comment_count', '${issue.comments.total}', ui2.rect(22, 0, 38, 22),
					text_style(13, muted, false)),
			]), '${issue.comments.total} comments')
	}
	return ui2.Element{
		...ui2.clickable_view(id, ui2.rect(0, y, width, row_height),
			ui2.BoxStyle{ bg: bg, border_color: border, border_bottom: 1 }, children)
		key:                 id
		cursor:              'pointer'
		accessibility_label: '${issue.kind.singular()} #${issue.number}: ${issue.title}. Open description and comments.'
	}
}

fn item_icon(id string, issue Issue, frame ui2.Rect, bg u32) ui2.Element {
	if issue.kind == .issues { return issue_icon(id, issue.state, issue.state_reason, frame, bg) }
	color := item_status_color(issue)
	mut children := [
		ui2.view('${id}_left', ui2.rect(3, 4, 2, 10), box(color, 0), []),
		ui2.view('${id}_branch', ui2.rect(10, 4, 5, 2), box(color, 0), []),
		ui2.view('${id}_right', ui2.rect(13, 4, 2, 10), box(color, 0), []),
	]
	for i, pos in [ui2.rect(1, 0, 6, 6), ui2.rect(1, 12, 6, 6), ui2.rect(11, 12, 6, 6)] {
		children << ui2.view('${id}_node_${i}', pos, box(color, 3), [
			ui2.view('${id}_node_inner_${i}', ui2.rect(1.5, 1.5, 3, 3), box(bg, 1.5), []),
		])
	}
	return ui2.with_tooltip(ui2.view(id, frame, ui2.BoxStyle{ transparent: true }, children), issue.status())
}

fn issue_icon(id string, state string, reason string, frame ui2.Rect, bg u32) ui2.Element {
	color := if state == 'OPEN' {
		green
	} else if reason == 'NOT_PLANNED' {
		muted
	} else {
		purple
	}
	return ui2.view(id, frame, box(color, 9), [
		ui2.view('${id}_inside', ui2.rect(2, 2, 14, 14), box(bg, 7), [
			if state == 'OPEN' {
				ui2.view('${id}_dot', ui2.rect(5, 5, 4, 4), box(color, 2), [])
			} else {
				ui2.label('${id}_check', if reason == 'NOT_PLANNED' { '−' } else { '✓' },
					ui2.rect(0, -1, 14, 15), ui2.TextStyle{ size: 12, color: color, bold: true, align: .center })
			},
		]),
	])
}

fn contrasting_text(color u32) u32 {
	r := f64((color >> 16) & 255)
	g := f64((color >> 8) & 255)
	b := f64(color & 255)
	return if r * 0.299 + g * 0.587 + b * 0.114 > 150 { u32(0x25292e) } else { u32(0xffffff) }
}
