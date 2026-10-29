module main

import json2
import time

const first_comment_batch = 10
const next_comment_batch = 20

const issue_comment_fields = 'id body createdAt author { login } ' + reaction_group_fields

const issue_body_query = r'query IssueBody($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      number title body url state stateReason createdAt updatedAt
      author { login }
      labels(first: 20) { nodes { name color } }
      assignees(first: 20) { nodes { login } }
      milestone { title }
      ' + reaction_group_fields + '
      comments { totalCount }
    }
  }
}'

const issue_comments_query = r'query IssueComments($owner: String!, $name: String!, $number: Int!, $cursor: String, $first: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      number
      comments(first: $first, after: $cursor) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes { ' + issue_comment_fields + ' }
      }
    }
  }
}'

const issue_detail_query = r'query IssueDetail($owner: String!, $name: String!, $number: Int!, $cursor: String, $first: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      number title body url state stateReason createdAt updatedAt
      author { login }
      labels(first: 20) { nodes { name color } }
      assignees(first: 20) { nodes { login } }
      milestone { title }
      ' + reaction_group_fields + '
      comments(first: $first, after: $cursor) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes { ' + issue_comment_fields + ' }
      }
    }
  }
}'

enum CommentKind {
	conversation
	review
	inline_review
}

struct IssueComment {
	id         string
	body       string
	created_at string
	author     User
	kind       CommentKind
	state      string
	path       string
	line       int
	url        string
	posted     int // detail generation when this app added the comment; 0 if fetched
	reaction_groups []ReactionGroup @[json: reactionGroups]
}

struct IssueDetail {
	issue    Issue
	comments []IssueComment
	has_next bool
	cursor   string
	source_count int // API entries consumed, including reviews without a body
	review_pages []ReviewCommentPage
}

struct DetailRequest {
	kind       ItemKind
	generation int
	repo       Repository
	number     int
	cursor     string
	append     bool
	limit      int                = page_size
	cancel     &FetchCancellation = unsafe { nil }
}

enum DetailPart {
	complete
	body
	comments
}

struct DetailResult {
	request       DetailRequest
	detail        IssueDetail
	error         string
	part          DetailPart
	done          bool = true
	cached        bool
	storage_error string
}

fn detail_args(request DetailRequest) []string {
	return detail_query_args(request, .complete)
}

fn detail_query_args(request DetailRequest, part DetailPart) []string {
	mut query := match part {
		.body { issue_body_query }
		.comments { issue_comments_query }
		.complete { issue_detail_query }
	}
	if request.kind == .prs {
		query = match part {
			.comments { pull_request_comments_query }
			.complete { pull_request_detail_query }
			.body {
				// Aliases keep issues and PRs in the same progressive pipeline.
				query.replace('query Issue', 'query PullRequest')
					.replace('issue(number:', 'issue: pullRequest(number:')
					.replace('stateReason', 'isDraft mergeable baseRefName headRefName headRefOid additions deletions changedFiles mergedAt mergedBy { login }')
					.replace('      number', '      __typename number totalCommentsCount')
			}
		}
	}
	mut args := ['api', '--hostname', 'github.com', 'graphql', '-f', 'query=${query}', '-f',
		'owner=${request.repo.owner}', '-f', 'name=${request.repo.name}', '-F',
		'number=${request.number}']
	if part != .body {
		args << ['-F', 'first=${request.limit}']
		if request.kind == .prs {
			cursor := pr_discussion_cursor(request.cursor)
			args << ['-F', 'loadComments=${!cursor.comments_done}', '-F', 'loadReviews=${!cursor.reviews_done}']
			if cursor.comments != '' { args << ['-f', 'cursor=${cursor.comments}'] }
			if cursor.reviews != '' { args << ['-f', 'reviewCursor=${cursor.reviews}'] }
		} else if request.cursor != '' {
			args << ['-f', 'cursor=${request.cursor}']
		}
	}
	return args
}

fn decode_detail(source string) !IssueDetail {
	return decode_detail_part(source, .complete)
}

fn decode_detail_part(source string, part DetailPart) !IssueDetail {
	response := decode_detail_response(source)!
	item := json_field(json_field(json_field(response, 'data'), 'repository'), 'issue')
	if json_object(item).len == 0 {
		return error('Issue was not found, or your gh account does not have access.')
	}
	if json_field(item, 'number').int() <= 0 {
		return error('GitHub returned an issue without a number.')
	}
	connection := json_field(item, 'comments')
	issue := if part == .comments {
		Issue{ kind: if json_text(json_field(item, '__typename')) == 'PullRequest' {
			.prs
		} else {
			.issues
		}, number: json_field(item, 'number').int(), comments: Count{ total: github_comment_count(item) } }
	} else {
		decode_issue(item)!
	}
	if part == .body { return IssueDetail{ issue: issue } }
	if 'nodes' !in json_object(connection) && 'nodes' !in json_object(json_field(item, 'reviews')) {
		return error('GitHub’s response did not contain comments.')
	}
	comments := decode_comment_nodes(connection, .conversation)!
	page_info := json_field(connection, 'pageInfo')
	detail := IssueDetail{
		issue:    issue
		comments: comments
		has_next: json_field(page_info, 'hasNextPage').bool()
		cursor:   json_text(json_field(page_info, 'endCursor'))
		source_count: json_array(json_field(connection, 'nodes')).len
	}
	if 'reviews' in json_object(item) || (issue.kind == .prs && 'totalCommentsCount' in json_object(item)) {
		return decode_pr_discussion(item, detail)!
	}
	return detail
}

fn decode_detail_response(source string) !json2.Any {
	response := json2.decode[json2.Any](source) or {
		return error('Could not read GitHub’s response: ${err}')
	}
	mut messages := []string{}
	for item in json_array(json_field(response, 'errors')) {
		messages << json_text(json_field(item, 'message'))
	}
	if messages.len > 0 { return error(messages.join('\n')) }
	return response
}

fn decode_comment_nodes(connection json2.Any, kind CommentKind) ![]IssueComment {
	mut comments := []IssueComment{}
	for node in json_array(json_field(connection, 'nodes')) {
		id := json_text(json_field(node, 'id'))
		if id == '' { return error('GitHub returned a comment without an ID.') }
		comments << IssueComment{
			id:         id
			body:       json_text(json_field(node, 'body'))
			created_at: json_text(json_field(node, 'createdAt'))
			author:     User{ login: json_text(json_field(json_field(node, 'author'), 'login')) }
			kind:       kind
			path:       json_text(json_field(node, 'path'))
			line:       if json_field(node, 'line').int() > 0 { json_field(node, 'line').int() } else { json_field(node, 'originalLine').int() }
			url:        json_text(json_field(node, 'url'))
			reaction_groups: decode_reaction_groups(node)
		}
	}
	return comments
}

fn fetch_detail(request DetailRequest) !IssueDetail {
	return fetch_detail_part(request, .complete)
}

fn fetch_detail_part(request DetailRequest, part DetailPart) !IssueDetail {
	detail := decode_detail_part(run_gh_with_cancel(detail_query_args(request, part), request.cancel)!, part)!
	if request.kind == .prs && part != .body {
		return fetch_pr_review_comments(request, detail)!
	}
	return detail
}

fn fetch_detail_in_background(request DetailRequest, results chan DetailResult) {
	// Description and first replies can arrive in either order. Pagination never
	// holds up the description, and loading more replies doesn't re-fetch it.
	if !request.append {
		if issue := read_issue_body(request) {
			if cancelled(request.cancel) { return }
			results <- DetailResult{ request: request, part: .body, detail: IssueDetail{ issue: issue }, cached: true }
			wake_ui()
		}
		spawn fetch_body_in_background(request, results)
	}
	fetch_comments_in_background(request, results)
}

fn fetch_body_in_background(request DetailRequest, results chan DetailResult) {
	started := time.now()
	detail := fetch_detail_part(request, .body) or {
		if cancelled(request.cancel) { return }
		results <- DetailResult{ request: request, part: .body, error: err.msg() }
		wake_ui()
		return
	}
	if cancelled(request.cancel) { return }
	profile_fetch('issue description', started)
	mut storage_error := ''
	store_issue_body(request, detail.issue) or { storage_error = err.msg() }
	if cancelled(request.cancel) { return }
	results <- DetailResult{ request: request, part: .body, detail: detail, storage_error: storage_error }
	wake_ui()
}

fn fetch_comments_in_background(request DetailRequest, results chan DetailResult) {
	mut cursor := request.cursor
	mut remaining := page_size
	mut loaded := IssueDetail{}
	for remaining > 0 {
		if cancelled(request.cancel) { return }
		limit := if remaining == page_size {
			first_comment_batch
		} else {
			int_min(next_comment_batch, remaining)
		}
		started := time.now()
		page := fetch_detail_part(DetailRequest{ ...request, cursor: cursor, limit: limit }, .comments) or {
			if cancelled(request.cancel) { return }
			results <- DetailResult{ request: request, part: .comments, error: err.msg() }
			wake_ui()
			return
		}
		if cancelled(request.cancel) { return }
		profile_fetch('comments (${page.comments.len})', started)
		loaded = IssueDetail{ ...page, comments: merge_comments(loaded.comments, page.comments) }
		remaining -= page.source_count
		done := remaining <= 0 || !page.has_next || page.source_count == 0 || page.cursor == cursor
		results <- DetailResult{ request: request, part: .comments, detail: loaded, done: done }
		wake_ui()
		if done { return }
		cursor = page.cursor
	}
}

fn merge_comments(first []IssueComment, second []IssueComment) []IssueComment {
	mut comments := first.clone()
	mut seen := map[string]bool{}
	for comment in comments { seen[comment.id] = true }
	for comment in second {
		if comment.id !in seen {
			comments << comment
			seen[comment.id] = true
		}
	}
	return comments
}
