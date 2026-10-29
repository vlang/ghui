module main

import encoding.base64
import os
import ui2

fn reference_example_app() App {
	return App{
		repo:   Repository{ owner: 'vlang', name: 'v' }
		issues: [Issue{ number: 1, title: 'Issue', state: 'OPEN' },
			Issue{ number: 2, title: 'Another issue', state: 'OPEN' }]
	}
}

fn test_native_discussion_link_events_preserve_the_destination() {
	for target in ['https://github.com/vlang/v/issues/29407', 'mailto:alex@example.com',
		'https://example.com/page?q=a:b#section'] {
		assert (discussion_event_link('link:comment_1_body_0_text:${base64.encode_str(target)}') or { panic('Link was ignored.') }) == target
	}
	for event in ['pointer:up:issue_42', 'link:text', 'link::abcd',
		'link:text:${base64.encode_str('javascript:alert(1)')}'] {
		if _ := discussion_event_link(event) { assert false, event }
	}
}

fn test_local_references_resolve_prs_and_preserve_external_destinations() {
	repo := Repository{ owner: 'vlang', name: 'v' }
	issue := local_discussion_reference('https://github.com/vlang/v/issues/29407', repo) or { panic('Missing reference.') }
	assert issue.number == 29407 && issue.needs_lookup
	pr := local_discussion_reference('https://github.com/VLANG/V/pull/42', repo) or { panic('Missing PR.') }
	assert pr.kind == .prs && pr.number == 42 && !pr.needs_lookup
	for target in ['https://github.com/vlang/ui/issues/42', 'https://example.com/vlang/v/issues/42',
		'https://github.com/vlang/v/issues/42#issuecomment-123', 'https://github.com/vlang/v/issues/42?query=test',
		'https://github.com/vlang/v/pull/42/files', 'https://github.com/vlang/v/issues/0',
		'https://github.com/vlang/v/issues/999999999999', 'https://github.com/vlang/v/issues/42abc',
		'https://github.com/vlang/v/issues/-42'] {
		if _ := local_discussion_reference(target, repo) { assert false, target }
	}
}

fn test_reference_resolution_distinguishes_issues_from_prs_and_surfaces_errors() {
	for kind in ['Issue', 'PullRequest'] {
		actual := decode_reference_kind('{"data":{"repository":{"issueOrPullRequest":{"__typename":"${kind}"}}}}') or { panic(err) }
		assert actual == if kind == 'Issue' { ItemKind.issues } else { ItemKind.prs }
	}
	for source in ['{"data":{"repository":{"issueOrPullRequest":null}}}',
		'{"errors":[{"message":"Access denied"}]}', 'invalid json'] {
		decode_reference_kind(source) or { continue }
		assert false, source
	}
	mut app := reference_example_app()
	app.open_issue(1)
	request := app.begin_reference(29407)
	args := reference_args(request)
	assert 'number=29407' in args && args[args.index('number=29407') - 1] == '-F'
	assert 'query=${reference_query}' in args
	assert 'owner=vlang' in args && 'name=v' in args
	app.apply_reference_result(ReferenceResult{ request: request, error: 'Access denied' })
	assert !app.reference_loading && app.reference_error.contains('Access denied')
	assert app.active_issue == 1
	ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, 800, 860))) or { panic(err) }
	second := app.begin_reference(29407)
	assert app.reference_error == ''
	ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, 800, 860))) or { panic(err) }
	issue := app.apply_reference_result(ReferenceResult{ request: second, kind: .prs }) or { panic('Reference was ignored.') }
	assert issue.number == 29407 && issue.kind == .prs && !app.reference_loading
}

fn test_reference_resolution_cannot_navigate_after_a_later_click_or_leaving() {
	mut app := reference_example_app()
	app.open_issue(1)
	first := app.begin_reference(42)
	second := app.begin_reference(43)
	assert cancelled(first.cancel)
	if _ := app.apply_reference_result(ReferenceResult{ request: first, kind: .prs }) { assert false }
	assert app.reference_loading
	app.open_issue(2)
	assert cancelled(second.cancel) && !app.reference_loading
	if _ := app.apply_reference_result(ReferenceResult{ request: second, kind: .prs }) { assert false }
	assert app.active_issue == 2
	third := app.begin_reference(44)
	app.close_issue()
	assert cancelled(third.cancel)
	if _ := app.apply_reference_result(ReferenceResult{ request: third, error: 'Stale error' }) { assert false }
	assert app.active_issue == 0 && app.reference_error == ''
}

fn test_known_references_use_loaded_issues_and_cached_prs() {
	mut app := reference_example_app()
	assert (app.known_reference_kind(1) or { panic('Issue was not found.') }) == .issues
	app.detail_cache[42] = CachedDetail{ detail: IssueDetail{ issue: Issue{ kind: .prs, number: 42 } } }
	assert (app.known_reference_kind(42) or { panic('PR was not found.') }) == .prs
	app.list_cache['prs_OPEN'] = IssuePage{ issues: [Issue{ kind: .prs, number: 43 }] }
	assert (app.known_reference_kind(43) or { panic('PR list was ignored.') }) == .prs
	if _ := app.known_reference_kind(44) { assert false }
}

fn test_live_reference_resolution_when_requested() {
	if os.getenv('GHGUI_LIVE_TESTS') != '1' { return }
	request := ReferenceRequest{ repo: Repository{ owner: 'vlang', name: 'v' }, number: 29407 }
	source := run_gh_with_cancel(reference_args(request), request.cancel) or { panic(err) }
	assert (decode_reference_kind(source) or { panic(err) }) == .prs
}
