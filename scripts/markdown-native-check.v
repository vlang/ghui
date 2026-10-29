module main

import ui2
import os

$if macos {
	#include "@VMODROOT/scripts/markdown-native-check.h"
}

fn C.ghui_probe_has_badge() bool

@[heap]
struct MarkdownProbe {
mut:
	phase        int
	image_path   string
	image_source string
}

const probe = &MarkdownProbe{}

fn main() {
	$if macos {
		mut state := unsafe { probe }
		state.image_path = os.join_path(os.temp_dir(), 'ghui-markdown-badge-${os.getpid()}.svg')
		state.image_source = os.getenv_opt('GHUI_MARKDOWN_PROBE_IMAGE') or { state.image_path }
		os.write_file(state.image_path, '<svg xmlns="http://www.w3.org/2000/svg" width="52" height="20"><rect width="52" height="20" fill="#dfb317"/><text x="8" y="14" font-size="11">P2</text></svg>') or { panic(err) }
		defer { os.rm(state.image_path) or {} }
		ui2.run_window('Markdown rendering check', 500, 120, build_probe, probe_event)
	} $else {
		eprintln('This check requires the native macOS backend.')
		exit(1)
	}
}

fn probe_event(_ string) {}

fn require_probe(condition bool, message string) {
	if !condition {
		eprintln(message)
		exit(1)
	}
}

fn build_probe() ui2.Element {
	mut state := unsafe { probe }
	style := ui2.TextStyle{ size: 13 }
	image := ui2.inline_image_run(ui2.TextRun{
		text:       'P2 Badge'
		image_path: state.image_source
		style:      ui2.TextStyle{ ...style, link: 'https://example.com/review' }
	}, 100, 20)
	if image.text != '\uFFFC' {
		require_probe(state.phase == 0 && image.text == 'P2 Badge'
			&& image.style.link == 'https://example.com/review', 'Image loading did not preserve the alt text and link.')
		area := ui2.rich_text_area_without_scroll('markdown', image.text, [image],
			ui2.rect(12, 12, 476, 80), ui2.BoxStyle{}, style)
		return ui2.screen(0xffffff, [ui2.Element{ ...area, readonly: true }])
	}
	require_probe(image.image_width == 52 && image.image_height == 20,
		'The SVG badge did not decode to the expected size.')
	if state.phase > 0 {
		runs := ui2.text_area_runs('markdown')
		require_probe(runs.filter(it.style.bold).map(it.text).join('') == 'bold',
			'Bold formatting was lost during native rendering.')
		require_probe(runs.filter(it.style.font_family.contains('Courier')).map(it.text).join('') == 'code',
			'Inline code formatting was lost during native rendering.')
		require_probe(runs.filter(it.text == '#29407').len == 1
			&& runs.filter(it.text == '#29407')[0].style.link == 'https://github.com/vlang/v/issues/29407',
			'Issue and PR links were lost during native rendering.')
		require_probe(runs.filter(it.style.vertical_align == 'subscript').map(it.text).join('') == 'sub',
			'Subscript formatting was lost during native rendering.')
		require_probe(runs.filter(it.style.vertical_align == 'superscript').map(it.text).join('') == 'sup',
			'Superscript formatting was lost during native rendering.')
		require_probe(C.ghui_probe_has_badge(), 'The SVG badge attachment or its link was lost during native rendering.')
		if state.phase == 1 {
			require_probe(ui2.text_area_selection_length('markdown') == 0,
				'Applying Markdown styles selected the text.')
			ui2.text_area_set_selection('markdown', 6, 4)
		} else {
			require_probe(ui2.text_area_caret('markdown') == 6
				&& ui2.text_area_selection_length('markdown') == 4,
				'Refreshing Markdown changed the user selection.')
		}
		if state.phase == 3 {
			require_probe(ui2.text('markdown').ends_with(' refreshed'), 'The updated content was not rendered.')
			println('Native Markdown styles, SVG images, links and selection survive unchanged and changed refreshes.')
			ui2.quit()
		}
	}
	text := 'plain bold and code #29407 sub sup \uFFFC' + if state.phase >= 2 {
		' refreshed'
	} else {
		''
	}
	mut runs := [ui2.TextRun{ text: 'plain ', style: style },
		ui2.TextRun{ text: 'bold', style: ui2.TextStyle{ ...style, bold: true } },
		ui2.TextRun{ text: ' and ', style: style },
		ui2.TextRun{ text: 'code', style: ui2.TextStyle{ ...style, font_family: 'Courier New' } },
		ui2.TextRun{ text: ' ', style: style }, ui2.TextRun{
			text:  '#29407'
			style: ui2.TextStyle{
				...style
				color:     0x0969da
				underline: true
				link:      'https://github.com/vlang/v/issues/29407'
			}
		}]
	runs << ui2.TextRun{ text: ' ', style: style }
	runs << ui2.TextRun{ text: 'sub', style: ui2.TextStyle{ ...style, size: 10, vertical_align: 'subscript' } }
	runs << ui2.TextRun{ text: ' ', style: style }
	runs << ui2.TextRun{ text: 'sup', style: ui2.TextStyle{ ...style, size: 10, vertical_align: 'superscript' } }
	runs << ui2.TextRun{ text: ' ', style: style }
	runs << image
	if state.phase >= 2 { runs << ui2.TextRun{ text: ' refreshed', style: style } }
	area := ui2.rich_text_area_without_scroll('markdown', text, runs, ui2.rect(12, 12, 476, 80), ui2.BoxStyle{}, style)
	state.phase++
	ui2.request_refresh()
	return ui2.screen(0xffffff, [ui2.Element{ ...area, readonly: true }])
}
