module main

import json2
import time

const review_comment_fields = 'id body createdAt path line originalLine url author { login } ' + reaction_group_fields

const pull_request_discussion_fields = r'
      totalCommentsCount
      comments(first: $first, after: $cursor) @include(if: $loadComments) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes { ' + issue_comment_fields + ' }
      }
      reviews(first: $first, after: $reviewCursor, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) @include(if: $loadReviews) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id body submittedAt state author { login }
          ' + reaction_group_fields + '
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { ' + review_comment_fields + ' }
          }
        }
      }'

const pull_request_comments_query = r'query PullRequestComments($owner: String!, $name: String!, $number: Int!, $cursor: String, $reviewCursor: String, $first: Int!, $loadComments: Boolean!, $loadReviews: Boolean!) {
  repository(owner: $owner, name: $name) {
    issue: pullRequest(number: $number) {
      __typename number' + pull_request_discussion_fields + '
    }
  }
}'

const pull_request_detail_query = r'query PullRequestDetail($owner: String!, $name: String!, $number: Int!, $cursor: String, $reviewCursor: String, $first: Int!, $loadComments: Boolean!, $loadReviews: Boolean!) {
  repository(owner: $owner, name: $name) {
    issue: pullRequest(number: $number) {
      __typename number title body url state isDraft mergeable createdAt updatedAt
      baseRefName headRefName headRefOid additions deletions changedFiles
      mergedAt mergedBy { login }
      author { login }
      labels(first: 20) { nodes { name color } }
      assignees(first: 20) { nodes { login } }
      milestone { title }
      ' + reaction_group_fields + pull_request_discussion_fields + '
    }
  }
}'

const review_comments_query = r'query ReviewComments($review: ID!, $cursor: String!) {
  node(id: $review) {
    ... on PullRequestReview {
      comments(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { ' + review_comment_fields + ' }
      }
    }
  }
}'

// The two connections have unrelated cursors and can finish on different pages.
struct PrDiscussionCursor {
	comments      string
	reviews       string
	comments_done bool
	reviews_done  bool
}

struct ReviewCommentPage {
	review string
	cursor string
}

fn pr_discussion_cursor(source string) PrDiscussionCursor {
	if source == '' { return PrDiscussionCursor{} }
	return json2.decode[PrDiscussionCursor](source) or { PrDiscussionCursor{ comments: source } }
}

fn decode_pr_discussion(item json2.Any, detail IssueDetail) !IssueDetail {
	reviews := json_field(item, 'reviews')
	mut comments := detail.comments.clone()
	mut pages := []ReviewCommentPage{}
	for review in json_array(json_field(reviews, 'nodes')) {
		id := json_text(json_field(review, 'id'))
		if id == '' { return error('GitHub returned a review without an ID.') }
		body := json_text(json_field(review, 'body'))
		reaction_groups := decode_reaction_groups(review)
		// A blank review is a container for inline comments, not a blank card.
		if body.trim_space() != '' || reaction_groups.len > 0 {
			comments << IssueComment{
				id:         id
				body:       body
				created_at: json_text(json_field(review, 'submittedAt'))
				author:     User{ login: json_text(json_field(json_field(review, 'author'), 'login')) }
				kind:       .review
				state:      json_text(json_field(review, 'state'))
				reaction_groups: reaction_groups
			}
		}
		connection := json_field(review, 'comments')
		if 'nodes' !in json_object(connection) {
			return error('GitHub’s response did not contain review comments.')
		}
		comments = merge_comments(comments, decode_comment_nodes(connection, .inline_review)!)
		page_info := json_field(connection, 'pageInfo')
		if json_field(page_info, 'hasNextPage').bool() {
			cursor := json_text(json_field(page_info, 'endCursor'))
			if cursor == '' {
				return error('GitHub returned review comments without a pagination cursor.')
			}
			pages << ReviewCommentPage{ review: id, cursor: cursor }
		}
	}
	review_info := json_field(reviews, 'pageInfo')
	cursor := PrDiscussionCursor{
		comments:      detail.cursor
		comments_done: !detail.has_next
		reviews:       json_text(json_field(review_info, 'endCursor'))
		reviews_done:  !json_field(review_info, 'hasNextPage').bool()
	}
	return IssueDetail{
		...detail
		comments:     sort_discussion_comments(comments)
		has_next:     !cursor.comments_done || !cursor.reviews_done
		cursor:       json2.encode(cursor)
		source_count: detail.source_count + json_array(json_field(reviews, 'nodes')).len
		review_pages: pages
	}
}

fn review_comments_args(page ReviewCommentPage) []string {
	return ['api', '--hostname', 'github.com', 'graphql', '-f', 'query=${review_comments_query}',
		'-f', 'review=${page.review}', '-f', 'cursor=${page.cursor}']
}

fn fetch_pr_review_comments(request DetailRequest, detail IssueDetail) !IssueDetail {
	mut comments := detail.comments.clone()
	for pending in detail.review_pages {
		mut page := pending
		for {
			response := decode_detail_response(run_gh_with_cancel(review_comments_args(page), request.cancel)!)!
			connection := json_field(json_field(json_field(response, 'data'), 'node'), 'comments')
			if 'nodes' !in json_object(connection) {
				return error('GitHub’s response did not contain review comments.')
			}
			comments = merge_comments(comments, decode_comment_nodes(connection, .inline_review)!)
			info := json_field(connection, 'pageInfo')
			if !json_field(info, 'hasNextPage').bool() { break }
			cursor := json_text(json_field(info, 'endCursor'))
			if cursor == '' || cursor == page.cursor {
				return error('GitHub’s review comment pagination did not advance.')
			}
			page = ReviewCommentPage{ ...page, cursor: cursor }
		}
	}
	return IssueDetail{ ...detail, comments: sort_discussion_comments(comments), review_pages: []ReviewCommentPage{} }
}

fn sort_discussion_comments(source []IssueComment) []IssueComment {
	mut comments := source.clone()
	comments.sort_with_compare(compare_discussion_comments)
	return comments
}

fn compare_discussion_comments(a &IssueComment, b &IssueComment) int {
	if a.created_at < b.created_at { return -1 }
	if a.created_at > b.created_at { return 1 }
	// Put a review summary before inline comments submitted at the same instant.
	if a.kind == .review && b.kind != .review { return -1 }
	if b.kind == .review && a.kind != .review { return 1 }
	if a.id < b.id { return -1 }
	if a.id > b.id { return 1 }
	return 0
}

fn (comment IssueComment) action(now time.Time) string {
	action := if comment.kind == .review {
		match comment.state {
			'APPROVED' { 'approved' }
			'CHANGES_REQUESTED' { 'requested changes' }
			'DISMISSED' { 'reviewed (dismissed)' }
			else { 'reviewed' }
		}
	} else {
		'commented'
	}
	return '${action} ${relative_time(comment.created_at, now)}'
}

fn (comment IssueComment) display_body() string {
	body := if comment.body.trim_space() == '' { 'This comment has no text.' } else { comment.body }
	if comment.kind != .inline_review || comment.path == '' { return body }
	location := comment.path + if comment.line > 0 { ':${comment.line}' } else { '' }
	label := location.replace('\\', '\\\\').replace('[', '\\[').replace(']', '\\]')
	context := if comment.url != '' { '[${label}](${comment.url})' } else { label }
	return 'Comment on ${context}\n\n${body}'
}
