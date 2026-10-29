module main

import ui2

fn test_review_badge_renders_nested_subscript_and_a_bold_title() {
	blocks := body_blocks('<sub><sub>![P2 Badge](https://img.shields.io/badge/P2-yellow)</sub></sub> **Invalidate cached links for native artifacts**\n\nFor cached builds using `#flag foo.o`, `.a`, or `.so`, include artifact contents in the key.')
	assert blocks.len == 2
	assert blocks[0].text == 'P2 Badge Invalidate cached links for native artifacts'
	assert !blocks[0].text.contains('<sub>') && !blocks[0].text.contains('[Image:')
	badge := blocks[0].runs[0]
	assert badge.text == 'P2 Badge'
	assert badge.image_path == 'https://img.shields.io/badge/P2-yellow'
	assert badge.style.link == badge.image_path
	assert badge.style.vertical_align == 'subscript'
	assert badge.style.size < body_style(.paragraph, 0).size
	title := blocks[0].runs.last()
	assert title.text == 'Invalidate cached links for native artifacts' && title.style.bold
	assert title.style.vertical_align == '' && title.style.size == 13
	assert blocks[1].runs.filter(it.style.font_family != '').map(it.text) == [
		'#flag foo.o',
		'.a',
		'.so',
	]
}

fn test_inline_html_styles_restore_across_markdown_nodes_and_discussions() {
	block := body_blocks('normal <SUB>lower **bold <sup>upper</sup> lower**</SUB> normal <i>italic</i><br />next <!-- hidden -->')[0]
	assert block.text == 'normal lower bold upper lower normal italic\nnext '
	upper := block.runs.filter(it.text == 'upper')[0]
	assert upper.style.bold && upper.style.vertical_align == 'superscript'
	lower := block.runs.filter(it.text == ' lower')[0]
	assert lower.style.bold && lower.style.vertical_align == 'subscript'
	assert block.runs.last().style.vertical_align == '' && !block.runs.last().style.bold
	assert block.runs.filter(it.text == 'italic')[0].style.italic
	assert body_blocks('unclosed <sub>small\n\nnormal')[1].runs[0].style.vertical_align == ''
	literal := body_blocks('`<sub>literal</sub>` and &lt;sub&gt;escaped&lt;/sub&gt;')[0]
	assert literal.text == '<sub>literal</sub> and <sub>escaped</sub>'
	assert literal.runs.all(it.style.vertical_align == '')
}

fn test_images_keep_alt_text_and_enclosing_link_destinations() {
	block := body_blocks('[![P2 Badge](https://img.shields.io/badge/P2-yellow)](https://example.com/review) ![other](https://example.com/other.png)')[0]
	images := block.runs.filter(it.image_path != '')
	assert images.len == 2
	assert images[0].text == 'P2 Badge' && images[0].style.link == 'https://example.com/review'
	assert images[1].text == 'other' && images[1].style.link == 'https://example.com/other.png'
	html_image := body_blocks('badge: <a href="https://example.com/review"><img src="https://example.com/badge.svg?a=1&amp;b=2" alt="P2 &amp; Badge"></a> after')[0]
	assert html_image.text == 'badge: P2 & Badge after'
	image := html_image.runs.filter(it.image_path != '')[0]
	assert image.image_path == 'https://example.com/badge.svg?a=1&b=2'
	assert image.style.link == 'https://example.com/review'
	assert html_image.runs.last().style.link == ''
	unsafe_images := body_blocks('![local](file:///etc/passwd) ![script](javascript:alert) ![mail](mailto:a@example.com)')[0]
	assert unsafe_images.runs.all(it.image_path == '' && it.style.link == '')
	assert discussion_image_url('data:image/svg+xml,test') == ''
}

fn test_inline_image_dimensions_are_reserved_when_text_wraps() {
	style := body_style(.paragraph, 0)
	image := ui2.TextRun{ text: '\uFFFC', style: style, image_path: 'badge.svg', image_width: 52, image_height: 20 }
	assert body_runs_height([image], 100, style, false) == 36
	assert body_runs_height([image, image], 100, style, false) == 60
	large := ui2.TextRun{ ...image, image_width: 100, image_height: 240 }
	assert body_runs_height([large, ui2.TextRun{ text: 'caption', style: style }], 100, style, false) == 273
}

fn test_discussion_markdown_renders_the_autofree_report() {
	blocks := body_blocks('The CI step `./v -autofree cmd/v` has been commented out.\n\n## Current status\n\n1. **Shared sub-buffers** — `params << params_t` double-frees.\n2. **Non-owning pointer locals** — a `&Scope` is shared.')
	assert blocks.len == 4
	assert blocks[0].text == 'The CI step ./v -autofree cmd/v has been commented out.'
	code := blocks[0].runs.filter(it.text == './v -autofree cmd/v')
	assert code.len == 1 && code[0].style.font_family == 'Courier New'
	assert code[0].style.background_color == subtle
	assert blocks[1].kind == .heading && blocks[1].text == 'Current status'
	assert blocks[2].marker == '1.' && blocks[3].marker == '2.'
	assert blocks[2].text == 'Shared sub-buffers — params << params_t double-frees.'
	strong := blocks[2].runs.filter(it.text == 'Shared sub-buffers')
	assert strong.len == 1 && strong[0].style.bold
}

fn test_nested_styles_unicode_and_literal_code_survive_rendering() {
	blocks := body_blocks('Привет 🙂 **bold *and italic*** with ~~removed~~ and `**literal**`.\n\n```v\nprintln("**literal**")\n```')
	assert blocks.len == 2
	assert blocks[0].text == 'Привет 🙂 bold and italic with removed and **literal**.'
	nested := blocks[0].runs.filter(it.text == 'and italic')
	assert nested.len == 1 && nested[0].style.bold && nested[0].style.italic
	removed := blocks[0].runs.filter(it.text == 'removed')
	assert removed.len == 1 && removed[0].style.strikethrough
	assert blocks[1].kind == .code
	assert blocks[1].text == 'println("**literal**")'
	assert blocks[1].runs.len == 1 && !blocks[1].runs[0].style.bold
	assert blocks[0].runs.map(it.text).join('') == blocks[0].text
}

fn test_reference_links_are_styled_and_scoped_to_each_discussion() {
	blocks := body_blocks('[**V docs**][docs] and <https://vlang.io>\n\n[docs]: https://docs.vlang.io/')
	assert blocks.len == 1
	assert blocks[0].text == 'V docs and https://vlang.io'
	link := blocks[0].runs.filter(it.text == 'V docs')
	assert link.len == 1 && link[0].style.bold && link[0].style.underline
	assert link[0].style.link == 'https://docs.vlang.io/'
	assert blocks[0].runs.last().style.link == 'https://vlang.io'
	assert body_blocks('[V docs][docs]')[0].text == '[V docs][docs]'
	assert discussion_link('javascript:alert(1)') == ''
	assert discussion_link('mailto:alex@example.com') == 'mailto:alex@example.com'
}

fn test_issue_and_pr_shorthand_uses_the_discussion_repository() {
	body := 'Fixed by #29407; also **#42** and vlang/ui#123.'
	for repo in [Repository{ owner: 'vlang', name: 'v' },
		Repository{ owner: 'alice', name: 'project' }] {
		block := body_blocks_for_repo(body, repo)[0]
		assert block.text == 'Fixed by #29407; also #42 and vlang/ui#123.'
		links := block.runs.filter(it.style.link != '')
		assert links.map(it.text) == ['#29407', '#42', 'vlang/ui#123']
		assert links.map(it.style.link) == ['https://github.com/${repo}/issues/29407',
			'https://github.com/${repo}/issues/42', 'https://github.com/vlang/ui/issues/123']
		assert links.all(it.style.underline && it.style.color == blue)
		assert links[1].style.bold
	}
}

fn test_reference_linking_preserves_code_explicit_links_and_literal_html() {
	repo := Repository{ owner: 'vlang', name: 'v' }
	blocks := body_blocks_for_repo('`#42` [#43](https://example.com) [#44](javascript:alert) <span data-id="#45">\n\n```\n#46\n```\n\n<div>#47</div>', repo)
	assert blocks[0].runs.filter(it.style.link != '').map(it.style.link) == ['https://example.com']
	assert blocks[0].runs.filter(it.text == '#42')[0].style.link == ''
	assert blocks[1].kind == .code && blocks[1].runs[0].style.link == ''
	assert blocks[2].runs[0].style.link == ''
}

fn test_reference_linking_respects_boundaries_and_works_in_quotes_lists_and_tables() {
	repo := Repository{ owner: 'vlang', name: 'v' }
	text := 'word#42 C#123 ##45 #0 #42suffix #42_thing #42.5 #999999999999 /#42 @#42 #42/#43 bad/path/name#42 Привет#42 (#7), #8.'
	block := body_blocks_for_repo(text, repo)[0]
	assert block.text == text
	assert block.runs.filter(it.style.link != '').map(it.text) == ['#7', '#8']
	blocks := body_blocks_for_repo('> Fixed by *#1*\n\n- See #2\n\n| PR |\n| --- |\n| #3 |', repo)
	assert blocks[0].runs.filter(it.style.link != '').map(it.text) == ['#1']
	assert blocks[0].runs.filter(it.style.link != '')[0].style.italic
	assert blocks[1].runs.filter(it.style.link != '').map(it.text) == ['#2']
	assert blocks[2].rows[1][0].runs[0].style.link == 'https://github.com/vlang/v/issues/3'
}

fn test_nested_lists_quotes_tasks_and_setext_headings() {
	blocks := body_blocks('Summary\n=======\n\n> A **quote**\n>\n> - [x] done\n> - [ ] pending\n\n3. First\n   - Nested\n4. Second\n\n---')
	assert blocks[0].kind == .heading && blocks[0].level == 1
	assert blocks[1].kind == .quote && blocks[1].text == 'A quote'
	assert blocks[2].marker == '☑' && blocks[2].quote_depth == 1
	assert blocks[3].marker == '☐' && blocks[3].text == 'pending'
	assert blocks[4].marker == '3.' && blocks[4].indent == 1
	assert blocks[5].marker == '•' && blocks[5].indent == 2
	assert blocks[6].marker == '4.'
	assert blocks.last().kind == .rule
}

fn test_gfm_tables_have_styled_aligned_selectable_cells() {
	blocks := body_blocks('| Feature | Status |\n| :--- | ---: |\n| **Markdown** | `done` |\n| Links | Working |')
	assert blocks.len == 1 && blocks[0].kind == .table
	rows := blocks[0].rows
	assert rows.len == 3 && rows[0].len == 2
	assert rows[0][0].text == 'Feature' && rows[0][0].runs[0].style.bold
	assert rows[0][1].align == .right
	assert rows[1][0].text == 'Markdown' && rows[1][0].runs[0].style.bold
	assert rows[1][1].text == 'done' && rows[1][1].runs[0].style.font_family == 'Courier New'
	for width in [240.0, 740.0, 1014.0] {
		table := render_body_block('table', blocks[0], width, 0)
		ui2.validate_element_tree(table) or { panic(err) }
		assert table.children.len == 6
		for cell in table.children {
			assert cell.children[0].readonly && cell.children[0].disable_scroll
			assert cell.children[0].text_runs.map(it.text).join('') == cell.children[0].text
		}
	}
}

fn test_description_and_comments_use_selectable_rich_text() {
	mut app := App{ repo: Repository{ owner: 'vlang', name: 'v' } }
	app.open_issue(1)
	app.detail_loaded = true
	app.detail_comments_loaded = true
	app.detail = IssueDetail{
		issue:    Issue{ number: 1, title: 'Markdown', body: '**Description** and `code`; see #2' }
		comments: [IssueComment{ id: 'reply', body: '*Comment* and ~~old~~; fixed by #29407' }]
	}
	for width in [320.0, 800.0, 1440.0] {
		layout := detail_layout(&app, ui2.rect(0, 0, width, 860))
		ui2.validate_element_tree(layout.content) or { panic(err) }
		for card in layout.content.children.filter(it.id in ['description', 'comment_reply']) {
			area := card.children[1].children[0]
			assert area.kind == .text_area && area.readonly && area.disable_scroll
			assert area.text_runs.len > 0
			assert area.text_runs.map(it.text).join('') == area.text
			assert !area.text.contains('**') && !area.text.contains('~~')
			links := area.text_runs.filter(it.style.link != '')
			assert links.len == 1
			assert links[0].style.link == if card.id == 'description' {
				'https://github.com/vlang/v/issues/2'
			} else {
				'https://github.com/vlang/v/issues/29407'
			}
		}
	}
}
