module main

import math
import time
import ui2

struct DetailLayout {
	content    ui2.Element
	comments_y f64
}

fn render_detail(app &App, bounds ui2.Rect) ui2.Element {
	margin := 18.0
	mut children := []ui2.Element{}
	children << render_mode_switch(app, margin)
	refresh := ui2.button('refresh', if app.detail_loading {
		'↻  Refreshing…'
	} else {
		'↻  Refresh'
	},
		ui2.rect(margin + 156, 12, 132, 30), bordered_box(subtle, 6), text_style(13, ink, false))
	children << ui2.Element{ ...refresh, enabled: !app.detail_loading && !app.merging_current_pr() && !app.marking_current_pr_ready() && !app.closing_current_issue() && !app.closing_current_pr(), tooltip: 'Refresh ${app.kind.singular().to_lower()} and comments' }
	children << ui2.with_tooltip(ui2.button('back', '←  Back to ${app.kind.label()}', ui2.rect(margin + 300, 12, 128, 30),
		bordered_box(subtle, 6), text_style(12, ink, false)), 'Back to the ${app.kind.label()} list (Esc)')
	if bounds.width > 900 {
		children << ui2.label('repository', app.repo.str(),
			ui2.rect(margin + 446, 12, math.max(1, bounds.width - 640), 30), text_style(16, ink, true))
	}
	comments_button := ui2.button('jump_comments', 'Comments (${app.detail.issue.comments.total})',
		ui2.rect(bounds.width - margin - 154, 12, 154, 30), bordered_box(subtle, 6), text_style(12, muted, false))
	children << ui2.Element{ ...comments_button, enabled: app.detail_loaded || app.detail_comments_loaded }
	layout := detail_layout(app, bounds)
	width := layout.content.frame.width
	children << ui2.scroll(app.detail_scroll_id(),
		ui2.rect((bounds.width - width) / 2, 56, width, math.max(1, bounds.height - 64)),
		0xffffff, [layout.content])
	return ui2.screen(0xffffff, children)
}

fn detail_layout(app &App, bounds ui2.Rect) DetailLayout {
	width := math.max(1, math.min(1040, bounds.width - 36))
	issue := app.detail.issue
	now := time.now()
	mut children := []ui2.Element{}
	mut y := 8.0
	if app.chatgpt_review_error != '' {
		notice := error_notice('chatgpt_review_error', app.chatgpt_review_error, width, y)
		children << notice
		y += notice.frame.height + 14
	}
	if app.reference_loading {
		children << ui2.label('reference_loading', 'Opening #${app.reference_request.number}…',
			ui2.rect(0, y, width, 24), text_style(13, muted, false))
		y += 32
	}
	if app.reference_error != '' {
		notice := error_notice('reference_error', app.reference_error, width, y)
		children << notice
		y += notice.frame.height + 14
	}
	if app.detail_error != '' {
		children << ui2.view('detail_error', ui2.rect(0, y, width, 76),
			ui2.BoxStyle{ bg: 0xffebe9, radius: 6, border_color: 0xff8182, border_left: 3 }, [
				ui2.label('detail_error_title', 'Some ${app.kind.singular().to_lower()} data could not be loaded. Refresh to try again.',
					ui2.rect(12, 8, math.max(1, width - 24), 20), text_style(13, 0x82071e, true)),
				ui2.label('detail_error_message', app.detail_error,
					ui2.rect(12, 30, math.max(1, width - 24), 38),
					ui2.TextStyle{ size: 12, color: 0x82071e, lines: 2, valign: .top }),
			])
		y += 88
	}
	title := if issue.title == '' {
		'${app.kind.singular()} #${app.active_issue}'
	} else {
		issue.title
	}
	title_lines := wrapped_line_count(title, width, 20, false)
	title_height := title_lines * 26.0
	children << with_github_url_menu(ui2.label('detail_title', title, ui2.rect(0, y, width, title_height),
		ui2.TextStyle{ size: 20, color: ink, bold: true, lines: title_lines, valign: .top }), issue, app.repo)
	y += title_height + 8
	state := issue.status()
	state_color := item_status_color(issue)
	children << ui2.view('detail_state', ui2.rect(0, y, 70, 24), box(state_color, 12), [
		ui2.label('detail_state_text', state, ui2.rect(8, 0, 54, 24),
			ui2.TextStyle{ size: 12, color: 0xffffff, bold: true, align: .center }),
	])
	children << ui2.label('detail_meta', '#${app.active_issue} · ${author_name(issue.author)} opened ${relative_time(issue.created_at, now)}${app.chatgpt_review_marker(issue)}',
		ui2.rect(82, y, math.max(1, width - 82), 24), text_style(12, muted, false))
	y += 38
	if issue.kind == .prs && issue.state == 'MERGED' {
		mut summary := if issue.merged_by.login != '' {
			'${issue.merged_by.login} merged this pull request'
		} else {
			'This pull request was merged'
		}
		if issue.base_ref != '' { summary += ' into ${issue.base_ref}' }
		if issue.merged_at != '' { summary += ' ${relative_time(issue.merged_at, now)}' }
		text_width := math.max(1, width - 28)
		lines := wrapped_line_count(summary, text_width, 13, false)
		height := lines * 20.0 + 20
		children << ui2.view('pr_merge_summary', ui2.rect(0, y, width, height),
			ui2.BoxStyle{ bg: 0xfbefff, radius: 6, border_color: purple, border_left: 3 }, [
				ui2.with_tooltip(ui2.label('pr_merge_text', summary, ui2.rect(14, 10, text_width, lines * 20),
					ui2.TextStyle{ size: 13, color: ink, lines: lines, valign: .top }),
					if issue.merged_at != '' { 'Merged at ${issue.merged_at}' } else { '' }),
			])
		y += height + 14
	}
	if issue.kind == .issues && issue.state == 'OPEN' {
		button := ui2.button('close_issue', if app.closing_current_issue() { 'Closing…' } else { 'Close issue' },
			ui2.rect(0, y, 130, 32), bordered_box(subtle, 6), text_style(13, ink, true))
		children << ui2.Element{ ...button, enabled: app.can_close_issue(),
			tooltip: 'Close this issue as completed on GitHub.',
			accessibility_label: 'Close issue #${issue.number}' }
		y += 46
	}
	close_error := app.close_errors[app.active_issue] or { '' }
	if app.kind == .issues && close_error != '' {
		notice := error_notice('close_issue_error', 'Issue could not be closed: ${close_error}', width, y)
		children << notice
		y += notice.frame.height + 14
	}
	if issue.kind == .prs && issue.base_ref != '' {
		branch_text := '${issue.head_ref} → ${issue.base_ref} · ${issue.changed_files} files changed · +${issue.additions} −${issue.deletions}'
		lines := wrapped_line_count(branch_text, width, 12, false)
		children << ui2.label('pr_branches', branch_text, ui2.rect(0, y, width, lines * 18),
			ui2.TextStyle{ size: 12, color: muted, lines: lines, valign: .top })
		y += lines * 18 + 14
	}
	if issue.has_merge_conflicts() {
		notice := error_notice('pr_conflicts', 'This pull request has merge conflicts. Resolve them and refresh before squash merging.', width, y)
		children << notice
		y += notice.frame.height + 14
	}
	if issue.kind == .prs {
		children << ui2.with_tooltip(ui2.button('view_diff', 'View diff',
			ui2.rect(0, y, 120, 32), bordered_box(subtle, 6), text_style(13, ink, true)),
			'View the changes in this pull request')
	}
	if issue.kind == .prs && issue.state == 'OPEN' {
		if issue.is_draft {
			ready_button := ui2.button('mark_ready', if app.marking_current_pr_ready() { 'Marking ready…' } else { 'Ready for review' },
				ui2.rect(132, y, 164, 32), box(green, 6), text_style(13, 0xffffff, true))
			children << ui2.Element{ ...ready_button, enabled: app.can_mark_ready(),
				tooltip: 'Mark this draft pull request ready for review on GitHub.',
				accessibility_label: 'Mark pull request #${issue.number} ready for review' }
		}
		button := ui2.button('squash_merge', if app.merging_current_pr() { 'Merging…' } else { 'Squash merge' },
			ui2.rect(if issue.is_draft { 308.0 } else { 132.0 }, y, 150, 32), box(green, 6), text_style(13, 0xffffff, true))
		children << ui2.Element{ ...button, enabled: app.can_squash_merge(),
			tooltip: if issue.has_merge_conflicts() { 'Resolve merge conflicts and refresh before squash merging.' } else if issue.is_draft { 'Draft pull requests must be marked ready before merging.' } else { 'Squash this pull request into its base branch.' },
			accessibility_label: 'Squash merge pull request #${issue.number}' }
		close_button := ui2.button('close_pr', if app.closing_current_pr() { 'Closing…' } else { 'Close PR' },
			ui2.rect(if issue.is_draft { 470.0 } else { 294.0 }, y, 130, 32), bordered_box(subtle, 6), text_style(13, red, true))
		children << ui2.Element{ ...close_button, enabled: app.can_close_pr(),
			tooltip: 'Close this pull request without merging on GitHub.',
			accessibility_label: 'Close pull request #${issue.number} without merging' }
	}
	if issue.kind == .prs { y += 46 }
	close_pr_error := app.close_pr_errors[app.active_issue] or { '' }
	if app.kind == .prs && close_pr_error != '' {
		notice := error_notice('close_pr_error', 'Pull request could not be closed: ${close_pr_error}', width, y)
		children << notice
		y += notice.frame.height + 14
	}
	ready_error := app.ready_errors[app.active_issue] or { '' }
	if app.kind == .prs && ready_error != '' {
		notice := error_notice('ready_error', 'Pull request could not be marked ready: ${ready_error}', width, y)
		children << notice
		y += notice.frame.height + 14
	}
	merge_error := app.merge_errors[app.active_issue] or { '' }
	if app.kind == .prs && merge_error != '' {
		notice := error_notice('merge_error', 'Squash merge failed: ${merge_error}', width, y)
		children << notice
		y += notice.frame.height + 14
	}
	body := if !app.detail_loaded {
		if app.detail_body_loading {
			'Loading ${app.kind.singular().to_lower()} description…'
		} else {
			'Description could not be loaded.'
		}
	} else if issue.body.trim_space() == '' {
		'No description provided.'
	} else {
		issue.body
	}
	card := discussion_card('description', author_name(issue.author), 'opened ${relative_time(issue.created_at, now)}',
		body, issue.reaction_groups, app.repo, width, y)
	children << card
	y += card.frame.height + 16
	comments_y := y
	children << ui2.label('comments_heading', 'Comments (${issue.comments.total})', ui2.rect(0, y, width, 26),
		text_style(15, ink, true))
	y += 34
	for comment in app.detail.comments {
		comment_card := discussion_card('comment_${comment.id}', author_name(comment.author),
			comment.action(now), comment.display_body(), comment.reaction_groups, app.repo, width, y)
		children << comment_card
		y += comment_card.frame.height + 12
	}
	if app.detail.comments.len == 0 {
		message := if app.detail_comments_loading {
			'Loading comments…'
		} else if !app.detail_comments_loaded {
			'Comments could not be loaded.'
		} else {
			'No comments yet.'
		}
		children << ui2.label('comments_empty', message, ui2.rect(0, y, width, 24), text_style(13, muted, false))
		y += 36
	}
	if app.detail.has_next {
		button := ui2.button('load_more_comments', if app.detail_loading {
			'Loading…'
		} else {
			'Load more comments'
		},
			ui2.rect(0, y, 170, 30), bordered_box(subtle, 6), text_style(12, ink, false))
		children << ui2.Element{ ...button, enabled: !app.detail_loading }
		children << ui2.label('comments_loaded', '${app.detail.comments.len} of ${issue.comments.total} comments loaded',
			ui2.rect(184, y, math.max(1, width - 184), 30), text_style(12, muted, false))
		y += 42
	} else if app.detail_loading && (app.detail_loaded || app.detail_comments_loaded) {
		children << ui2.label('detail_refreshing', if app.detail_comments_loading {
			'Loading comments…'
		} else {
			'Loading description…'
		},
			ui2.rect(0, y, width, 24), text_style(12, muted, false))
		y += 36
	}
	form := comment_form(app, width, y + 4)
	children << form
	y += form.frame.height + 4
	return DetailLayout{
		content:    ui2.view('detail_content', ui2.rect(0, 0, width, y + 24), box(0xffffff, 0), children)
		comments_y: comments_y
	}
}

fn comment_form(app &App, width f64, y f64) ui2.Element {
	posting := app.posting_current_comment()
	area := ui2.text_area('new_comment_text', app.comment_draft(), ui2.rect(6, 6, math.max(1, width - 12), 112),
		box(0xffffff, 0), text_style(13, ink, false))
	button := ui2.button('add_comment', if posting { 'Commenting…' } else { 'Comment' },
		ui2.rect(0, 170, 120, 32), box(green, 6), text_style(13, 0xffffff, true))
	mut children := [
		ui2.label('new_comment_heading', 'Add a comment', ui2.rect(0, 0, width, 26), text_style(15, ink, true)),
		ui2.view('new_comment_box', ui2.rect(0, 34, width, 124), bordered_box(0xffffff, 6), [
			ui2.Element{ ...area, enabled: !posting, emit_change: true, accessibility_label: 'Comment' },
		]),
		ui2.Element{ ...button, enabled: app.can_add_comment(),
			tooltip: if app.comment_loading && !posting { 'Another comment is still being posted.' } else { 'Post this comment to GitHub (⌘↩ / Ctrl+Enter)' },
			accessibility_label: 'Comment on ${app.kind.singular().to_lower()} #${app.active_issue}' },
		ui2.label('new_comment_hint', 'Markdown is supported.', ui2.rect(134, 170, math.max(1, width - 134), 32),
			text_style(12, muted, false)),
	]
	mut height := 202.0
	comment_error := app.comment_errors[app.active_issue] or { '' }
	if comment_error != '' {
		notice := error_notice('new_comment_error', 'Comment was not posted: ${comment_error}', width, height + 12)
		children << notice
		height += notice.frame.height + 12
	}
	// A stable key keeps the editor and its focus while comments load above it.
	return ui2.Element{
		...ui2.view('new_comment', ui2.rect(0, y, width, height), box(0xffffff, 0), children)
		key: 'new_comment_${app.active_issue}'
	}
}

fn error_notice(id string, message string, width f64, y f64) ui2.Element {
	lines := wrapped_line_count(message, width - 24, 12, false)
	return ui2.view(id, ui2.rect(0, y, width, lines * 18.0 + 20),
		ui2.BoxStyle{ bg: 0xffebe9, radius: 6, border_color: 0xff8182, border_left: 3 }, [
			ui2.label('${id}_message', message, ui2.rect(12, 10, math.max(1, width - 24), lines * 18),
				ui2.TextStyle{ size: 12, color: 0x82071e, lines: lines, valign: .top }),
		])
}

fn author_name(author User) string {
	return if author.login == '' { 'ghost' } else { author.login }
}

fn discussion_card(id string, author string, action string, body string, reactions []ReactionGroup, repo Repository, width f64, y f64) ui2.Element {
	mut children := [ui2.view('${id}_header', ui2.rect(1, 1, width - 2, 30),
		ui2.BoxStyle{ bg: subtle, border_color: border, border_bottom: 1 }, [
			ui2.label('${id}_author', author, ui2.rect(12, 4, math.min(180, width / 3), 22), text_style(12, ink, true)),
			ui2.label('${id}_time', action, ui2.rect(math.min(196, width / 3 + 16), 4, math.max(1, width - math.min(212, width / 3 + 32)), 22),
				text_style(11, muted, false)),
		])]
	mut offset := 40.0
	for i, block in body_blocks_for_repo(body, repo) {
		content := render_body_block('${id}_body_${i}', block, math.max(1, width - 26), offset)
		children << content
		offset += content.frame.height + if block.kind == .table { 12 } else { 4 }
	}
	row := reaction_row('${id}_reactions', reactions, math.max(1, width - 26), offset + 4)
	if row.frame.height > 0 {
		children << row
		offset += row.frame.height + 8
	}
	return ui2.view(id, ui2.rect(0, y, width, offset + 8), bordered_box(0xffffff, 6), children)
}

fn wrapped_line_count(text string, width f64, font f64, code bool) int {
	available := math.max(1, width)
	mut count := 0
	for line in text.split('\n') {
		if code {
			count += int(math.max(1, math.ceil(line.replace('\t', '    ').runes().len * font * 0.66 / available)))
			continue
		}
		mut used := 0.0
		count++
		for word in line.split(' ') {
			size := estimated_text_width(word, font) * 1.1
			if used > 0 && used + size > available {
				count++
				used = 0
			}
			// Long URLs and identifiers can wrap in the middle of a word.
			if size > available {
				count += int(size / available)
				used = math.fmod(size, available)
			} else {
				used += size + font * 0.35
			}
		}
	}
	return math.max(1, count)
}
