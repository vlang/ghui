module main

import time
import os

const sample_response = '{"data":{"repository":{"open":{"totalCount":50},"closed":{"totalCount":10941},"issues":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor-two"},"nodes":[{"number":29260,"title":"Parser silently zeroes arrays","url":"https://github.com/vlang/v/issues/29260","state":"OPEN","stateReason":null,"createdAt":"2026-10-01T17:17:32Z","updatedAt":"2026-10-01T17:17:32Z","author":{"login":"bare-metal-eng"},"labels":{"nodes":[{"name":"Bug","color":"d73a4a"}]},"assignees":{"nodes":[]},"milestone":null,"comments":{"totalCount":2},"closedByPullRequestsReferences":{"totalCount":0}}]}}}}'

fn test_decode_live_response_shape() {
	page := decode_page(sample_response) or { panic(err) }
	assert page.open_count == 50
	assert page.closed_count == 10941
	assert page.has_next
	assert page.cursor == 'cursor-two'
	assert page.issues.len == 1
	issue := page.issues[0]
	assert issue.number == 29260
	assert issue.author.login == 'bare-metal-eng'
	assert issue.comments.total == 2
	assert issue.labels.nodes[0].color == 'd73a4a'
	assert issue.milestone.title == ''
	assert issue.state_reason == ''
	assert issue.created_at == '2026-10-01T17:17:32Z'
}

fn test_missing_author_and_closed_state() {
	source := sample_response.replace('"author":{"login":"bare-metal-eng"}', '"author":null')
		.replace('"state":"OPEN"', '"state":"CLOSED"')
		.replace('"stateReason":null', '"stateReason":"NOT_PLANNED"')
	page := decode_page(source) or { panic(err) }
	assert page.issues[0].author.login == ''
	assert page.issues[0].state == 'CLOSED'
	assert page.issues[0].state_reason == 'NOT_PLANNED'
}

fn test_api_errors_are_shown_even_with_partial_data() {
	decode_page('{"data":{"repository":null},"errors":[{"message":"Could not resolve repository"}]}') or {
		assert err.msg() == 'Could not resolve repository'
		return
	}
	assert false
}

fn test_missing_repository_is_an_error() {
	decode_page('{"data":{"repository":null}}') or {
		assert err.msg().contains('not found')
		return
	}
	assert false
}

fn test_invalid_json_is_an_error() {
	decode_page('not json') or {
		assert err.msg().contains('Could not read')
		return
	}
	assert false
}

fn test_repository_validation() {
	assert (parse_repository('vlang/v') or { panic(err) }).str() == 'vlang/v'
	for input in ['', 'vlang', 'vlang/v/other', '/v', 'vlang/', 'vlang/v;echo', 'vlang/$(id)',
		'../v', 'vlang/a b'] {
		parse_repository(input) or { continue }
		assert false, input
	}
}

fn test_cursor_and_fixed_fetch_order_are_independent_of_ui_sort() {
	args := github_args(FetchRequest{
		repo:   Repository{ owner: 'vlang', name: 'v' }
		state:  'CLOSED'
		sort:   'Oldest'
		cursor: 'opaque=cursor=='
	})
	assert 'owner=vlang' in args
	assert 'name=v' in args
	assert 'state=CLOSED' in args
	assert args == github_args(FetchRequest{
		repo:   Repository{ owner: 'vlang', name: 'v' }
		state:  'CLOSED'
		sort:   'Newest'
		cursor: 'opaque=cursor=='
	})
	assert github_query.contains('orderBy: {field: CREATED_AT, direction: DESC}')
	assert 'cursor=opaque=cursor==' in args
	assert 'query=${github_query}' in args
}

fn test_relative_times_and_counts() {
	now := time.parse_iso8601('2026-10-01T20:00:00Z') or { panic(err) }
	assert relative_time('2026-10-01T19:59:45Z', now) == 'just now'
	assert relative_time('2026-10-01T19:30:00Z', now) == '30m ago'
	assert relative_time('2026-10-01T17:00:00Z', now) == '3h ago'
	assert relative_time('2026-09-29T20:00:00Z', now) == '2d ago'
	assert format_count(0) == '0'
	assert format_count(50) == '50'
	assert format_count(10941) == '10,941'
}

// Opt in to read-only network checks against a real repository.
fn test_live_github_pagination_and_local_sorting_when_requested() {
	if os.getenv('GHGUI_LIVE_TESTS') != '1' { return }
	repo := parse_repository('vlang/v') or { panic(err) }
	closed := fetch_issues(FetchRequest{ repo: repo, state: 'CLOSED', sort: 'Newest' }) or { panic(err) }
	assert closed.issues.len > 0
	assert closed.issues.all(it.state == 'CLOSED')
	assert closed.issues[0].number > 0
	assert closed.issues[0].title != ''
	if closed.has_next {
		next := fetch_issues(FetchRequest{ repo: repo, state: 'CLOSED', sort: 'Newest', cursor: closed.cursor }) or { panic(err) }
		assert next.issues.len > 0
		assert next.issues[0].number !in closed.issues.map(it.number)
	}
	open := fetch_issues(FetchRequest{ repo: repo, state: 'OPEN', sort: 'Newest' }) or { panic(err) }
	oldest := sort_issues(open.issues, 'Oldest')
	for i in 1 .. oldest.len {
		assert oldest[i - 1].created_at <= oldest[i].created_at
	}
	updated := sort_issues(open.issues, 'Recently updated')
	for i in 1 .. updated.len {
		assert updated[i - 1].updated_at >= updated[i].updated_at
	}
}
