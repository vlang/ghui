module main

import json2
import os
import time
import ui2

// Same shape as vlang/v#29490: no conversation comments, one summary, and
// two inline comments, the second attached to a review without a summary.
const review_only_response = r'{"data":{"repository":{"issue":{"__typename":"PullRequest","number":29490,"title":"Check late bodies","state":"CLOSED","body":"Description","totalCommentsCount":3,"comments":{"totalCount":0,"nodes":[],"pageInfo":{"hasNextPage":false}},"reviews":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"review-one","body":"Reviewed the change","submittedAt":"2026-10-05T09:12:12Z","state":"COMMENTED","author":{"login":"alice"},"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"inline-one","body":"Preserve serial checking","createdAt":"2026-10-05T09:12:12Z","path":"vlib/checker.v","line":null,"originalLine":290,"url":"https://github.com/vlang/v/pull/29490#discussion_r1","author":{"login":"alice"}}]}},{"id":"review-two","body":"","submittedAt":"2026-10-05T11:21:37Z","state":"COMMENTED","author":null,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"inline-two","body":"Rechecked the fix","createdAt":"2026-10-05T11:21:37Z","path":"vlib/checker.v","line":291,"originalLine":290,"author":null}]}}]}}}}}'

fn test_pr_review_only_discussion_renders_all_comments_and_correct_counts() {
	detail := decode_detail(review_only_response) or { panic(err) }
	assert detail.issue.comments.total == 3
	assert detail.comments.map(it.id) == ['review-one', 'inline-one', 'inline-two']
	assert detail.comments.map(it.kind) == [CommentKind.review, .inline_review, .inline_review]
	assert detail.comments[1].line == 290 && detail.comments[2].line == 291
	assert author_name(detail.comments[2].author) == 'ghost'
	assert !detail.has_next && detail.source_count == 2
	assert detail.comments[1].display_body().contains('[vlib/checker.v:290](https://github.com/vlang/v/pull/29490#discussion_r1)')
	assert detail.comments[0].action(time.now()).starts_with('reviewed ')

	mut app := App{ kind: .prs, state: 'CLOSED' }
	app.open_issue(29490)
	request := app.begin_detail_fetch(false)
	// A later body response must not reduce the count to conversation comments.
	app.apply_detail_result(DetailResult{ request: request, part: .comments, detail: detail })
	app.apply_detail_result(DetailResult{ request: request, part: .body, detail: decode_detail_part(review_only_response, .body) or { panic(err) } })
	assert app.detail.issue.comments.total == 3 && app.detail.comments.len == 3
	for width in [800.0, 1440.0] {
		layout := detail_layout(&app, ui2.rect(0, 0, width, 860))
		assert layout.content.children.filter(it.id.starts_with('comment_')).len == 3
		assert layout.content.children.filter(it.id == 'comments_heading')[0].text == 'Comments (3)'
		ui2.validate_element_tree(render_app(&app, ui2.rect(0, 0, width, 860))) or { panic(err) }
	}
	app.close_issue()
	app.open_issue(29490)
	assert app.detail.comments.len == 3 && app.detail_comments_loaded
}

fn test_reactions_decode_for_pr_reviews_and_inline_comments() {
	// The same groups appear on a PR description, summary, and inline comment.
	groups := '"reactionGroups":[{"content":"HOORAY","viewerHasReacted":true,"reactors":{"totalCount":4,"nodes":[{"login":"alice"},{"login":"bob"}]}}],'
	source := review_only_response.replace('"body":"Description",', '"body":"Description",${groups}')
		.replace('"id":"review-one",', '"id":"review-one",${groups}')
		.replace('"id":"inline-one",', '"id":"inline-one",${groups}')
	detail := decode_detail(source) or { panic(err) }
	assert detail.issue.kind == .prs
	assert detail.issue.reaction_groups[0].content == 'HOORAY'
	assert detail.comments[0].reaction_groups == detail.issue.reaction_groups
	assert detail.comments[1].reaction_groups == detail.issue.reaction_groups
	assert detail.comments[0].reaction_groups[0].description().contains('@alice, @bob and 2 others')
	assert detail.comments[1].reaction_groups[0].reactors.nodes.map(it.login) == ['alice', 'bob']
	assert detail.comments[2].reaction_groups.len == 0
	// A review with reactions still has meaningful content without a summary.
	blank := decode_detail(source.replace('"id":"review-two",', '"id":"review-two",${groups}')) or { panic(err) }
	assert blank.comments.any(it.id == 'review-two' && it.reaction_groups.len == 1)
}

fn test_pr_list_count_includes_reviews_and_survives_storage_encoding() {
	source := r'{"__typename":"PullRequest","number":29490,"title":"Check late bodies","comments":{"totalCount":0},"totalCommentsCount":3}'
	item := json2.decode[json2.Any](source) or { panic(err) }
	issue := decode_issue(item) or { panic(err) }
	assert issue.comments.total == 3
	stored := json2.decode[json2.Any](json2.encode(issue)) or { panic(err) }
	assert (decode_issue(stored) or { panic(err) }).comments.total == 3
}

fn test_pr_comment_and_review_cursors_advance_independently() {
	request := DetailRequest{
		kind:   .prs
		number: 29490
		cursor: json2.encode(PrDiscussionCursor{
			comments: 'conversation-cursor'
			reviews:  'review-cursor'
		})
	}
	args := detail_query_args(request, .comments)
	assert 'cursor=conversation-cursor' in args && 'reviewCursor=review-cursor' in args
	assert 'loadComments=true' in args && 'loadReviews=true' in args
	assert args[args.index('loadReviews=true') - 1] == '-F'
	for done in [PrDiscussionCursor{ comments_done: true, reviews: 'next-review' },
		PrDiscussionCursor{ reviews_done: true, comments: 'next-comment' }] {
		next_args := detail_query_args(DetailRequest{ ...request, cursor: json2.encode(done) }, .comments)
		assert 'loadComments=${!done.comments_done}' in next_args
		assert 'loadReviews=${!done.reviews_done}' in next_args
	}
	for part in [DetailPart.body, .complete] {
		query := detail_query_args(request, part).filter(it.starts_with('query='))[0]
		assert query.contains('totalCommentsCount')
	}
	// A page with only conversation comments still retains the composite cursor.
	page := decode_detail_part(r'{"data":{"repository":{"issue":{"__typename":"PullRequest","number":29490,"totalCommentsCount":3,"comments":{"nodes":[{"id":"c","body":"Reply"}],"pageInfo":{"hasNextPage":true,"endCursor":"next-comment"}}}}}}', .comments) or { panic(err) }
	assert page.has_next
	cursor := pr_discussion_cursor(page.cursor)
	assert cursor.comments == 'next-comment' && !cursor.comments_done && cursor.reviews_done
}

const pr_pagination_script = r'#!/bin/sh
set -eu
printf "%s\n" "$@" >> "$PR_COMMENT_TEST_ROOT/args"
query=""
review_cursor=""
for arg in "$@"; do
  case "$arg" in
    query=*) query="$arg" ;;
    reviewCursor=*) review_cursor="${arg#reviewCursor=}" ;;
  esac
done
case "$query" in
  *"query PullRequestComments"*)
    if [ "$review_cursor" = next-review ]; then
      cat "$PR_COMMENT_TEST_ROOT/review.json"
    else
      cat "$PR_COMMENT_TEST_ROOT/blank.json"
    fi ;;
  *"query ReviewComments"*) cat "$PR_COMMENT_TEST_ROOT/inline.json" ;;
  *) exit 2 ;;
esac
'

fn test_pr_worker_continues_after_blank_reviews_and_loads_more_than_100_inline_comments() {
	$if windows {
		return
	}
	root := os.join_path(os.temp_dir(), 'ghgui-pr-comments-${os.getpid()}-${time.now().unix_nano()}')
	os.mkdir_all(os.join_path(root, 'bin')) or { panic(err) }
	defer { os.rmdir_all(root) or {} }
	os.write_file(os.join_path(root, 'bin', 'gh'), pr_pagination_script) or { panic(err) }
	os.chmod(os.join_path(root, 'bin', 'gh'), 0o700) or { panic(err) }
	old_path := os.getenv('PATH')
	old_root := os.getenv('PR_COMMENT_TEST_ROOT')
	defer {
		os.setenv('PATH', old_path, true)
		os.setenv('PR_COMMENT_TEST_ROOT', old_root, true)
	}
	os.setenv('PATH', '${os.join_path(root, 'bin')}:${old_path}', true)
	os.setenv('PR_COMMENT_TEST_ROOT', root, true)
	os.write_file(os.join_path(root, 'blank.json'), r'{"data":{"repository":{"issue":{"__typename":"PullRequest","number":42,"totalCommentsCount":102,"comments":{"nodes":[],"pageInfo":{"hasNextPage":false}},"reviews":{"nodes":[{"id":"blank","body":"","comments":{"nodes":[]}}],"pageInfo":{"hasNextPage":true,"endCursor":"next-review"}}}}}}') or { panic(err) }
	mut nodes := []string{}
	for i in 1 .. 101 {
		nodes << '{"id":"inline-${i}","body":"Finding ${i}","createdAt":"2026-10-05T10:00:00Z"}'
	}
	os.write_file(os.join_path(root, 'review.json'), '{"data":{"repository":{"issue":{"__typename":"PullRequest","number":42,"totalCommentsCount":102,"reviews":{"nodes":[{"id":"summary","body":"Review summary","state":"COMMENTED","submittedAt":"2026-10-05T10:00:00Z","comments":{"nodes":[${nodes.join(',')}],"pageInfo":{"hasNextPage":true,"endCursor":"inline-100"}}}],"pageInfo":{"hasNextPage":false}}}}}}') or { panic(err) }
	os.write_file(os.join_path(root, 'inline.json'), '{"data":{"node":{"comments":{"nodes":[${nodes.last()},{"id":"inline-101","body":"Final reply","createdAt":"2026-10-05T11:00:00Z"}],"pageInfo":{"hasNextPage":false}}}}}') or { panic(err) }
	mut app := App{ kind: .prs }
	app.open_issue(42)
	request := app.begin_detail_fetch(false)
	worker := spawn fetch_comments_in_background(request, app.detail_results)
	first := <-app.detail_results
	assert first.error == '' && !first.done && first.detail.comments.len == 0
	app.apply_detail_result(first)
	last := <-app.detail_results
	assert last.error == '' && last.done && !last.detail.has_next
	app.apply_detail_result(last)
	worker.wait()
	assert app.detail.comments.len == 102
	assert app.detail.comments[0].id == 'summary'
	assert app.detail.comments.last().id == 'inline-101'
	assert app.detail.issue.comments.total == 102
	args := os.read_file(os.join_path(root, 'args')) or { panic(err) }
	assert args.contains('loadComments=false') && args.contains('reviewCursor=next-review')
	assert args.contains('review=summary') && args.contains('cursor=inline-100')
	// Nested API failures must reach the caller, rather than hiding more replies.
	os.write_file(os.join_path(root, 'inline.json'), r'{"errors":[{"message":"Review comments unavailable"}]}') or { panic(err) }
	fetch_detail_part(DetailRequest{ ...request, cursor: first.detail.cursor }, .comments) or {
		assert err.msg() == 'Review comments unavailable'
		return
	}
	assert false, 'A failed nested comment page was accepted.'
}

fn test_live_reported_pr_includes_review_summary_and_both_inline_comments() {
	if os.getenv('GHGUI_LIVE_TESTS') != '1' { return }
	request := DetailRequest{ kind: .prs, repo: Repository{ owner: 'vlang', name: 'v' }, number: 29490 }
	for part in [DetailPart.comments, .complete] {
		detail := fetch_detail_part(request, part) or { panic(err) }
		assert detail.issue.comments.total >= 3 && detail.comments.len >= 3
		assert detail.comments.any(it.kind == .review && it.body.starts_with('Reviewed 498bfff'))
		assert detail.comments.any(it.kind == .inline_review && it.body.starts_with('[P2] Preserve'))
		assert detail.comments.any(it.kind == .inline_review && it.body.starts_with('Rechecked 4298be'))
	}
	assert (fetch_detail_part(request, .body) or { panic(err) }).issue.comments.total >= 3
}
