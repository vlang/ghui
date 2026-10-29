module main

import math
import encoding.html as ehtml
import net.html
import ui2
import x.markdown

enum BodyKind {
	paragraph
	heading
	code
	quote
	table
	rule
}

struct BodyCell {
	text  string
	runs  []ui2.TextRun
	align ui2.Align
}

struct BodyBlock {
	text        string
	kind        BodyKind
	level       int
	runs        []ui2.TextRun
	indent      int
	quote_depth int
	marker      string
	rows        [][]BodyCell
}

struct BodyContext {
	indent      int
	quote_depth int
	repo        Repository
}

struct InlineHtmlFrame {
	name string
	link string
}

struct InlineHtmlState {
mut:
	frames []InlineHtmlFrame
}

// Parse each discussion independently so reference links cannot leak between
// comments. The same AST supplies selectable text and its native style runs.
fn body_blocks(body string) []BodyBlock {
	return body_blocks_for_repo(body, Repository{})
}

fn body_blocks_for_repo(body string, repo Repository) []BodyBlock {
	mut md := markdown.Markdown.new(markdown.Options{ extensions: markdown.gfm() })
	doc := md.parse(body)
	return markdown_blocks(doc, md, BodyContext{ repo: repo })
}

fn body_style(kind BodyKind, level int) ui2.TextStyle {
	return ui2.TextStyle{
		size:        match kind {
			.heading {
				if level <= 2 { 16.0 } else { 14.0 }
			}
			.code { 12.0 }
			else { 13.0 }
		}
		color:       ink
		bold:        kind == .heading
		font_family: if kind == .code { 'Courier New' } else { '' }
	}
}

fn markdown_blocks(node &markdown.Node, md markdown.Markdown, context BodyContext) []BodyBlock {
	mut blocks := []BodyBlock{}
	match node.kind {
		.heading, .paragraph, .code_block, .fenced_code, .html_block, .thematic_break {
			kind := match node.kind {
				.heading { BodyKind.heading }
				.code_block, .fenced_code { BodyKind.code }
				.thematic_break { BodyKind.rule }
				else {
					if context.quote_depth > 0 { BodyKind.quote } else { BodyKind.paragraph }
				}
			}
			style := body_style(kind, node.level)
			// Code and HTML blocks are literal text, never reparsed as Markdown.
			runs := if node.kind in [.code_block, .fenced_code, .html_block] {
				[ui2.TextRun{ text: node.literal.trim_right('\n'), style: style }]
			} else if kind == .rule {
				[]ui2.TextRun{}
			} else {
				markdown_inline_runs(node, md, style, context.repo)
			}
			blocks << BodyBlock{
				text:        runs.map(it.text).join('')
				kind:        kind
				level:       node.level
				runs:        runs
				indent:      context.indent
				quote_depth: context.quote_depth
			}
		}
		.blockquote {
			for child in node.children {
				blocks << markdown_blocks(child, md, BodyContext{ ...context, quote_depth: context.quote_depth + 1 })
			}
		}
		.list {
			for i, item in node.children {
				mut items := markdown_blocks(item, md, BodyContext{ ...context, indent: context.indent + 1 })
				marker := if item.children.len > 0 && item.children[0].kind == .task_checkbox {
					if item.children[0].checked { '☑' } else { '☐' }
				} else if node.is_ordered {
					'${node.list_start + i}.'
				} else {
					'•'
				}
				if items.len == 0 {
					items << BodyBlock{ indent: context.indent + 1, quote_depth: context.quote_depth }
				}
				items[0] = BodyBlock{ ...items[0], marker: marker }
				blocks << items
			}
		}
		.table {
			mut rows := [][]BodyCell{}
			for section in node.children {
				for row in section.children {
					mut cells := []BodyCell{}
					for cell in row.children {
						style := ui2.TextStyle{ ...body_style(.paragraph, 0), bold: section.kind == .table_head }
						runs := markdown_inline_runs(cell, md, style, context.repo)
						cells << BodyCell{
							text:  runs.map(it.text).join('')
							runs:  runs
							align: match cell.align {
								.center { ui2.Align.center }
								.right { ui2.Align.right }
								else { ui2.Align.left }
							}
						}
					}
					rows << cells
				}
			}
			blocks << BodyBlock{ kind: .table, rows: rows, indent: context.indent, quote_depth: context.quote_depth }
		}
		.link_ref_def, .task_checkbox {}
		else {
			for child in node.children {
				blocks << markdown_blocks(child, md, context)
			}
		}
	}
	return blocks
}

fn markdown_inline_runs(node &markdown.Node, md markdown.Markdown, style ui2.TextStyle, repo Repository) []ui2.TextRun {
	nodes := if node.children.len > 0 {
		node.children
	} else {
		markdown.parse_inline(node.literal, md.opts, md.ref_map)
	}
	mut runs := []ui2.TextRun{}
	mut html_state := InlineHtmlState{}
	append_inline_children(nodes, style, repo, true, mut html_state, mut runs)
	// Emphasis nodes can contain one text node per character. Coalesce them
	// before handing native controls hundreds of identical style ranges.
	mut merged := []ui2.TextRun{}
	for run in runs {
		if run.text == '' { continue }
		if merged.len > 0 && merged.last().style == run.style
			&& !body_run_has_image(merged.last()) && !body_run_has_image(run) {
			last := merged.last()
			merged[merged.len - 1] = ui2.TextRun{ text: last.text + run.text, style: run.style }
		} else {
			merged << run
		}
	}
	return merged
}

fn append_inline_children(nodes []&markdown.Node, style ui2.TextStyle, repo Repository, linkify bool, mut html_state InlineHtmlState, mut runs []ui2.TextRun) {
	mut i := 0
	for i < nodes.len {
		node := nodes[i]
		if node.kind != .text {
			append_inline_runs(node, style, repo, linkify, mut html_state, mut runs)
			i++
			continue
		}
		// Some emphasis nodes contain one text node per character. References
		// must be recognized across those nodes, while code and links stay separate.
		mut text := node.literal
		i++
		for i < nodes.len && nodes[i].kind == .text {
			text += nodes[i].literal
			i++
		}
		scoped_style := inline_html_style(style, html_state)
		if linkify && scoped_style.link == '' {
			append_issue_reference_runs(text, scoped_style, repo, mut runs)
		} else {
			runs << ui2.TextRun{ text: text, style: scoped_style }
		}
	}
}

fn append_inline_runs(node &markdown.Node, inherited ui2.TextStyle, repo Repository, linkify bool, mut html_state InlineHtmlState, mut runs []ui2.TextRun) {
	mut style := inherited
	match node.kind {
		.strong { style = ui2.TextStyle{ ...style, bold: true } }
		.emphasis { style = ui2.TextStyle{ ...style, italic: true } }
		.strikethrough { style = ui2.TextStyle{ ...style, strikethrough: true } }
		.link, .autolink {
			style = ui2.TextStyle{ ...style, color: blue, underline: true, link: discussion_link(node.dest) }
		}
		.code_span {
			style = ui2.TextStyle{ ...style, font_family: 'Courier New', background_color: subtle }
		}
		else {}
	}
	scoped_style := inline_html_style(style, html_state)
	match node.kind {
		.text, .code_span, .autolink {
			runs << ui2.TextRun{ text: node.literal, style: scoped_style }
		}
		.hard_break, .soft_break { runs << ui2.TextRun{ text: '\n', style: scoped_style } }
		.image {
			append_image_run(node.dest, node.text_content(), scoped_style, mut runs)
		}
		.raw_html {
			append_inline_html(node.literal, style, mut html_state, mut runs)
		}
		else {
			append_inline_children(node.children, style, repo, linkify && node.kind != .link, mut html_state, mut runs)
		}
	}
}

fn inline_html_style(inherited ui2.TextStyle, state InlineHtmlState) ui2.TextStyle {
	mut style := inherited
	for frame in state.frames {
		style = match frame.name {
			'sub', 'sup' {
				ui2.TextStyle{
					...style
					size:           math.max(8, style.size * 0.8)
					vertical_align: if frame.name == 'sub' { 'subscript' } else { 'superscript' }
				}
			}
			'b', 'strong' { ui2.TextStyle{ ...style, bold: true } }
			'i', 'em' { ui2.TextStyle{ ...style, italic: true } }
			's', 'del', 'strike' { ui2.TextStyle{ ...style, strikethrough: true } }
			'u', 'ins' { ui2.TextStyle{ ...style, underline: true } }
			'code', 'kbd', 'samp' {
				ui2.TextStyle{ ...style, font_family: 'Courier New', background_color: subtle }
			}
			'a' {
				if style.link == '' && frame.link != '' {
					ui2.TextStyle{ ...style, link: frame.link, color: blue, underline: true }
				} else {
					style
				}
			}
			else { style }
		}
	}
	return style
}

fn append_inline_html(literal string, inherited ui2.TextStyle, mut state InlineHtmlState, mut runs []ui2.TextRun) {
	if literal.starts_with('<!--') { return }
	inner := literal.trim_space().trim('<>').trim_space()
	closing := inner.starts_with('/')
	name := inner.trim_left('/').split_any(' \t\r\n/')[0].to_lower()
	style := inline_html_style(inherited, state)
	if name == 'br' && !closing {
		runs << ui2.TextRun{ text: '\n', style: style }
		return
	}
	if name == 'img' && !closing {
		tag := html.parse(literal).get_root()
		append_image_run(ehtml.unescape(tag.attributes['src'], all: true),
			ehtml.unescape(tag.attributes['alt'], all: true), style, mut runs)
		return
	}
	if name !in ['sub', 'sup', 'b', 'strong', 'i', 'em', 's', 'del', 'strike', 'u', 'ins', 'code',
		'kbd', 'samp', 'a'] {
		// Unknown HTML stays inert, and escaped tags and code never enter here.
		runs << ui2.TextRun{ text: literal, style: style }
		return
	}
	if closing {
		for i := state.frames.len - 1; i >= 0; i-- {
			if state.frames[i].name == name {
				state.frames.trim(i)
				break
			}
		}
	} else if !inner.ends_with('/') {
		mut link := ''
		if name == 'a' {
			tag := html.parse(literal).get_root()
			link = discussion_link(ehtml.unescape(tag.attributes['href'], all: true))
		}
		state.frames << InlineHtmlFrame{ name: name, link: link }
	}
}

fn append_image_run(destination string, alt string, inherited ui2.TextStyle, mut runs []ui2.TextRun) {
	url := discussion_image_url(destination)
	run := ui2.TextRun{
		text:  if alt == '' { 'Image' } else { alt }
		style: if inherited.link == '' && url != '' {
			ui2.TextStyle{ ...inherited, link: url, color: blue, underline: true }
		} else {
			inherited
		}
	}
	$for field in ui2.TextRun.fields {
		$if field.name == 'image_path' {
			runs << ui2.TextRun{ ...run, image_path: url }
			return
		}
	}
	// Older ui2 modules display the image's alt text and link.
	runs << run
}

fn body_run_has_image(run ui2.TextRun) bool {
	$for field in ui2.TextRun.fields {
		$if field.name == 'image_path' {
			return run.image_path != ''
		}
	}
	return false
}

fn discussion_image_url(destination string) string {
	url := destination.trim_space()
	return if url.to_lower().starts_with('https://') || url.to_lower().starts_with('http://') {
		url
	} else {
		''
	}
}

// Image loading starts only when a block is displayed, never during parsing.
// Unavailable images retain their alt text and destination as a normal link.
fn body_display_runs(runs []ui2.TextRun, width f64) []ui2.TextRun {
	$for field in ui2.TextRun.fields {
		$if field.name == 'image_path' {
			return runs.map(if it.image_path == '' {
				it
			} else {
				ui2.inline_image_run(it, math.max(1, width), if it.style.vertical_align == '' {
					240.0
				} else {
					20.0
				})
			})
		}
	}
	return runs
}

fn reference_name_char(ch u8) bool {
	return ch.is_alnum() || ch in [`-`, `_`, `.`, `/`]
}

fn append_issue_reference_runs(text string, style ui2.TextStyle, repo Repository, mut runs []ui2.TextRun) {
	mut offset := 0
	for hash, ch in text.bytes() {
		if ch != `#` { continue }
		mut start := hash
		for start > offset && reference_name_char(text[start - 1]) { start-- }
		mut target_repo := repo
		if start < hash {
			target_repo = parse_repository(text[start..hash]) or { continue }
		}
		if target_repo.owner == '' || target_repo.name == '' { continue }
		if start > 0 && (text[start - 1] >= 128 || text[start - 1].is_alnum()
			|| text[start - 1] in [`#`, `@`, `/`, `:`, `_`]) {
			continue
		}
		mut end := hash + 1
		for end < text.len && text[end].is_digit() { end++ }
		number := text[hash + 1..end]
		if number == '' || number.len > 10 || (number.len == 10 && number > '2147483647')
			|| number.int() <= 0 {
			continue
		}
		if end < text.len && (text[end] >= 128 || text[end].is_alnum()
			|| text[end] in [`_`, `#`, `/`]) {
			continue
		}
		if end + 1 < text.len && text[end] == `.` && text[end + 1].is_digit() { continue }
		if start > offset { runs << ui2.TextRun{ text: text[offset..start], style: style } }
		// Issues and PRs share a number space. GitHub resolves /issues/N to
		// the matching PR when needed, without guessing from the current tab.
		runs << ui2.TextRun{
			text:  text[start..end]
			style: ui2.TextStyle{
				...style
				color:     blue
				underline: true
				link:      'https://github.com/${target_repo}/issues/${number}'
			}
		}
		offset = end
	}
	if offset < text.len { runs << ui2.TextRun{ text: text[offset..], style: style } }
}

fn discussion_link(destination string) string {
	url := destination.trim_space()
	lower := url.to_lower()
	return if lower.starts_with('https://') || lower.starts_with('http://') || lower.starts_with('mailto:') {
		url
	} else {
		''
	}
}

fn render_body_block(id string, block BodyBlock, width f64, y f64) ui2.Element {
	indent := math.min(math.max(0, width - 40), block.indent * 24.0 + block.quote_depth * 12.0)
	block_width := math.max(1, width - indent)
	if block.kind == .table { return render_body_table(id, block, block_width, indent + 13, y) }
	if block.kind == .rule {
		return ui2.view(id, ui2.rect(13 + indent, y, block_width, 12), box(0xffffff, 0), [
			ui2.view('${id}_line', ui2.rect(0, 5, block_width, 1), box(border, 0), []),
		])
	}
	style := body_style(block.kind, block.level)
	runs := body_display_runs(block.runs, block_width - 20)
	text := runs.map(it.text).join('')
	height := body_runs_height(runs, math.max(1, block_width - 20), style, block.kind == .code)
	area := ui2.rich_text_area_without_scroll('${id}_text', text, runs,
		ui2.rect(indent, 0, block_width, height),
		ui2.BoxStyle{
			bg:           if block.kind == .code || block.quote_depth > 0 {
				subtle
			} else {
				u32(0xffffff)
			}
			radius:       4
			border_color: border
			border_left:  if block.quote_depth > 0 { 3.0 } else { 0.0 }
		}, style)
	mut children := [ui2.Element{ ...area, readonly: true, accessibility_label: block.text }]
	if block.marker != '' {
		children << ui2.label('${id}_marker', block.marker, ui2.rect(math.max(0, indent - 24), 0, 24, style.size + 4),
			ui2.TextStyle{ ...style, align: .right, valign: .top })
	}
	return ui2.view(id, ui2.rect(13, y, width, height), box(0xffffff, 0), children)
}

fn render_body_table(id string, block BodyBlock, width f64, x f64, y f64) ui2.Element {
	columns := if block.rows.len > 0 { block.rows[0].len } else { 1 }
	cell_width := width / math.max(1, columns)
	mut children := []ui2.Element{}
	mut offset := 0.0
	for row_index, row in block.rows {
		mut height := 30.0
		mut display_runs := [][]ui2.TextRun{}
		for cell in row {
			runs := body_display_runs(cell.runs, cell_width - 20)
			display_runs << runs
			height = math.max(height, body_runs_height(runs, math.max(1, cell_width - 20), body_style(.paragraph, 0), false))
		}
		for column, cell in row {
			cell_id := '${id}_${row_index}_${column}'
			runs := display_runs[column]
			area := ui2.rich_text_area_without_scroll('${cell_id}_text', runs.map(it.text).join(''), runs,
				ui2.rect(1, 1, math.max(1, cell_width - 2), height - 2),
				box(if row_index == 0 { subtle } else { u32(0xffffff) }, 0),
				ui2.TextStyle{ ...body_style(.paragraph, 0), bold: row_index == 0, align: cell.align })
			children << ui2.view(cell_id, ui2.rect(column * cell_width, offset, cell_width, height), bordered_box(border, 0), [
				ui2.Element{ ...area, readonly: true, accessibility_label: cell.text },
			])
		}
		offset += height
	}
	return ui2.view(id, ui2.rect(x, y, width, offset), box(0xffffff, 0), children)
}

fn body_runs_height(runs []ui2.TextRun, width f64, style ui2.TextStyle, code bool) f64 {
	mut height := 12.0
	mut line_height := style.size + 4
	mut used := 0.0
	for run in runs {
		mut image_handled := false
		$for field in ui2.TextRun.fields {
			$if field.name == 'image_path' {
				if run.text == '\uFFFC' && run.image_path != '' {
					if used > 0 && used + run.image_width > width {
						height += line_height
						line_height = style.size + 4
						used = 0
					}
					line_height = math.max(line_height, run.image_height + 4)
					used += run.image_width
					image_handled = true
				}
			}
		}
		if image_handled { continue }
		for line_index, line in run.text.replace('\t', '    ').split('\n') {
			if line_index > 0 {
				height += line_height
				line_height = style.size + 4
				used = 0
			}
			for word_index, word in line.split(' ') {
				if word_index > 0 { used += run.style.size * 0.35 }
				word_width := if code || run.style.font_family != '' {
					word.runes().len * run.style.size * 0.66
				} else {
					estimated_text_width(word, run.style.size) * 1.1
				}
				if used > 0 && used + word_width > width {
					height += line_height
					line_height = style.size + 4
					used = 0
				}
				line_height = math.max(line_height, run.style.size + 4)
				if word_width > width {
					height += math.floor(word_width / width) * line_height
					used = math.fmod(word_width, width)
				} else {
					used += word_width
				}
			}
		}
	}
	return height + line_height
}
