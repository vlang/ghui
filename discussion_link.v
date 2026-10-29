module main

import encoding.base64
import json2
import net.urllib
import os as _

const reference_query = r'query DiscussionReference($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issueOrPullRequest(number: $number) { __typename }
  }
}'

struct DiscussionReference {
	number       int
	kind         ItemKind
	needs_lookup bool
}

struct ReferenceRequest {
	generation        int
	detail_generation int
	repo              Repository
	number            int
	cancel            &FetchCancellation = unsafe { nil }
}

struct ReferenceResult {
	request ReferenceRequest
	kind    ItemKind
	error   string
}

fn discussion_event_link(event string) ?string {
	parts := event.split(':')
	if parts.len < 3 || parts[0] != 'link' || parts[1] == '' { return none }
	target := discussion_link(base64.decode_str(parts.last()))
	if target == '' { return none }
	return target
}

fn local_discussion_reference(target string, repo Repository) ?DiscussionReference {
	url := urllib.parse(target) or { return none }
	if url.scheme !in ['http', 'https'] || url.host.to_lower() != 'github.com'
		|| url.fragment != '' || url.raw_query != '' { return none }
	parts := url.path.trim('/').split('/')
	if parts.len != 4 || parts[0].to_lower() != repo.owner.to_lower()
		|| parts[1].to_lower() != repo.name.to_lower() || parts[2] !in ['issues', 'pull'] { return none }
	number := parts[3]
	if number == '' || !number.bytes().all(it.is_digit()) || number.len > 10
		|| (number.len == 10 && number > '2147483647') || number.int() <= 0 { return none }
	return DiscussionReference{
		number:       number.int()
		kind:         if parts[2] == 'pull' { .prs } else { .issues }
		needs_lookup: parts[2] == 'issues'
	}
}

fn (app &App) known_reference_kind(number int) ?ItemKind {
	if cached := app.detail_cache[number] { return cached.detail.issue.kind }
	for issue in app.issues {
		if issue.number == number { return issue.kind }
	}
	for _, page in app.list_cache {
		for issue in page.issues {
			if issue.number == number { return issue.kind }
		}
	}
	return none
}

fn (mut app App) cancel_reference() {
	if !isnil(app.reference_request.cancel) { app.reference_request.cancel.stop() }
	app.reference_generation++
	app.reference_loading = false
	app.reference_error = ''
}

fn (mut app App) begin_reference(number int) ReferenceRequest {
	app.cancel_reference()
	app.reference_loading = true
	app.reference_request = ReferenceRequest{
		generation:        app.reference_generation
		detail_generation: app.detail_generation
		repo:              app.repo
		number:            number
		cancel:            &FetchCancellation{}
	}
	return app.reference_request
}

fn (mut app App) apply_reference_result(result ReferenceResult) ?Issue {
	if !app.reference_loading || result.request.generation != app.reference_generation
		|| result.request.detail_generation != app.detail_generation || cancelled(result.request.cancel) { return none }
	app.reference_loading = false
	if result.error != '' {
		app.reference_error = 'Could not open #${result.request.number}: ${result.error}'
		return none
	}
	return Issue{ kind: result.kind, number: result.request.number }
}

fn reference_args(request ReferenceRequest) []string {
	return ['api', '--hostname', 'github.com', 'graphql', '-f', 'query=${reference_query}',
		'-f', 'owner=${request.repo.owner}', '-f', 'name=${request.repo.name}', '-F', 'number=${request.number}']
}

fn decode_reference_kind(source string) !ItemKind {
	response := json2.decode[json2.Any](source) or { return error('Could not read GitHub’s response.') }
	mut messages := []string{}
	for item in json_array(json_field(response, 'errors')) {
		messages << json_text(json_field(item, 'message'))
	}
	if messages.len > 0 { return error(messages.join('\n')) }
	item := json_field(json_field(json_field(response, 'data'), 'repository'), 'issueOrPullRequest')
	return match json_text(json_field(item, '__typename')) {
		'Issue' { ItemKind.issues }
		'PullRequest' { ItemKind.prs }
		else { error('Issue or pull request was not found, or your gh account does not have access.') }
	}
}

fn resolve_reference_in_background(request ReferenceRequest, results chan ReferenceResult) {
	source := run_gh_with_cancel(reference_args(request), request.cancel) or {
		if cancelled(request.cancel) { return }
		results <- ReferenceResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	kind := decode_reference_kind(source) or {
		if cancelled(request.cancel) { return }
		results <- ReferenceResult{ request: request, error: err.msg() }
		wake_ui()
		return
	}
	if cancelled(request.cancel) { return }
	results <- ReferenceResult{ request: request, kind: kind }
	wake_ui()
}

fn open_discussion_url(target string) ! {
	$if windows {
		os.open_uri(target)!
	} $else $if macos {
		open_browser_url(target)!
	} $else {
		opener := os.find_abs_path_of_executable($if macos { 'open' } $else { 'xdg-open' })!
		mut process := os.new_process(opener)
		// Discussion URLs are untrusted text. Pass them as an argument directly,
		// rather than interpolating them into a shell command.
		process.set_args([target])
		process.run()
		process.wait()
		defer { process.close() }
		if process.code != 0 { return error('Could not open the link in your browser.') }
	}
}
