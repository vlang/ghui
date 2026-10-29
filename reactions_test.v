module main

import json2
import ui2

const reaction_detail_response = r'{"data":{"repository":{"issue":{
  "number":42,"title":"Reactions","body":"Description","state":"OPEN",
  "reactionGroups":[
    {"content":"THUMBS_UP","viewerHasReacted":true,"reactors":{"totalCount":12,"nodes":[{"login":"alice"},{"login":"build[bot]"},null,{"login":""},{"login":"Alice"}]}},
    {"content":"HEART","viewerHasReacted":false,"reactors":{"totalCount":2,"nodes":[{"login":"bob"},{"login":"carol"}]}},
    {"content":"ROCKET","reactors":{"totalCount":0}},
    {"content":"UNKNOWN","reactors":{"totalCount":5}}
  ],
  "comments":{"totalCount":1,"nodes":[{
    "id":"reply","body":"Reply","reactionGroups":[
      {"content":"EYES","viewerHasReacted":false,"reactors":{"totalCount":3,"nodes":[{"login":"alice"},{"login":"bob"},{"login":"carol"}]}}
    ]
  }],"pageInfo":{"hasNextPage":false}}
}}}}'

fn test_reactions_decode_for_descriptions_and_conversation_comments() {
	detail := decode_detail(reaction_detail_response) or { panic(err) }
	assert detail.issue.reaction_groups.map(it.content) == ['THUMBS_UP', 'HEART']
	assert detail.issue.reaction_groups[0].reactors.total == 12
	assert detail.issue.reaction_groups[0].reactors.nodes.map(it.login) == ['alice', 'build[bot]']
	assert detail.issue.reaction_groups[0].viewer_has_reacted
	assert !detail.issue.reaction_groups[1].viewer_has_reacted
	assert detail.comments[0].reaction_groups[0].content == 'EYES'
	assert detail.comments[0].reaction_groups[0].reactors.total == 3
	assert detail.comments[0].reaction_groups[0].reactors.nodes.map(it.login) == [
		'alice',
		'bob',
		'carol',
	]
	for part in [DetailPart.body, .comments] {
		partial := decode_detail_part(reaction_detail_response, part) or { panic(err) }
		if part == .body {
			assert partial.issue.reaction_groups == detail.issue.reaction_groups
		} else {
			assert partial.comments[0].reaction_groups == detail.comments[0].reaction_groups
		}
	}
	legacy := decode_detail(r'{"data":{"repository":{"issue":{"number":1,"title":"Legacy","comments":{"nodes":[{"id":"old","body":"Reply"}]}}}}}') or { panic(err) }
	assert legacy.issue.reaction_groups.len == 0
	assert legacy.comments.all(it.reaction_groups.len == 0)
}

fn test_reaction_refresh_preserves_description_and_updates_cached_comments() {
	mut app := App{}
	app.open_issue(42)
	initial := app.begin_detail_fetch(false)
	detail := decode_detail(reaction_detail_response) or { panic(err) }
	app.apply_detail_result(DetailResult{ request: initial, detail: detail })
	refresh := app.begin_detail_fetch(false)
	updated := decode_detail(reaction_detail_response.replace('"totalCount":3', '"totalCount":8')) or { panic(err) }
	// Replies can arrive first; the description's reactions must stay visible.
	app.apply_detail_result(DetailResult{ request: refresh, part: .comments, detail: updated, done: false })
	assert app.detail.issue.reaction_groups == detail.issue.reaction_groups
	assert app.detail.comments[0].reaction_groups[0].reactors.total == 8
	app.apply_detail_result(DetailResult{ request: refresh, part: .comments, detail: updated })
	app.apply_detail_result(DetailResult{
		request: refresh
		part:    .body
		detail:  IssueDetail{ issue: Issue{ ...detail.issue, reaction_groups: []ReactionGroup{} } }
	})
	assert app.detail.issue.reaction_groups.len == 0
	assert app.detail.comments[0].reaction_groups[0].reactors.total == 8
	app.close_issue()
	app.open_issue(42)
	assert app.detail.issue.reaction_groups.len == 0
	assert app.detail.comments[0].reaction_groups[0].reactors.total == 8
}

fn test_comment_reactions_survive_json_encoding() {
	// Cached comments use the same JSON names as GitHub's response.
	comment := (decode_detail(reaction_detail_response) or { panic(err) }).comments[0]
	decoded := json2.decode[IssueComment](json2.encode(comment)) or { panic(err) }
	assert decoded.reaction_groups == comment.reaction_groups
}

fn test_reaction_tooltips_name_reactors_and_account_for_partial_lists() {
	detail := decode_detail(reaction_detail_response) or { panic(err) }
	assert detail.issue.reaction_groups[0].description() == 'Thumbs up: 12 reactions · You reacted\n@alice, @build[bot] and 10 others'
	assert detail.issue.reaction_groups[1].description() == 'Heart: 2 reactions\n@bob, @carol'
	assert detail.comments[0].reaction_groups[0].description() == 'Eyes: 3 reactions\n@alice, @bob, @carol'
	partial := ReactionGroup{ content: 'HEART', reactors: ReactorConnection{ total: 3, nodes: [
		User{ login: 'bob' },
		User{ login: 'carol' },
	] } }
	assert partial.description() == 'Heart: 3 reactions\n@bob, @carol and 1 other'
	// Old cached counts remain usable before a live read supplies the usernames.
	legacy := ReactionGroup{ content: 'HEART', reactors: ReactorConnection{ total: 1 } }
	assert legacy.description() == 'Heart: 1 reaction'
	row := reaction_row('reactions', detail.comments[0].reaction_groups, 400, 0)
	assert row.children[0].tooltip.contains('@alice, @bob, @carol')
	assert row.children[0].children[0].tooltip == row.children[0].tooltip
}

fn test_reaction_counts_wrap_inside_description_and_comment_cards() {
	mut groups := []ReactionGroup{}
	for i, content in reaction_contents {
		groups << ReactionGroup{
			content:            content
			reactors:           ReactorConnection{ total: if i == 0 { 123456 } else { i + 1 } }
			viewer_has_reacted: i == 0
		}
	}
	app := App{
		active_issue:           42
		detail_loaded:          true
		detail_comments_loaded: true
		detail:                 IssueDetail{
			issue:    Issue{ number: 42, title: 'Reactions', body: 'Description', reaction_groups: groups }
			comments: [IssueComment{ id: 'reply', body: 'Reply', reaction_groups: groups }]
		}
	}
	for width in [240.0, 800.0, 1440.0] {
		layout := detail_layout(&app, ui2.rect(0, 0, width, 860))
		for id in ['description', 'comment_reply'] {
			card := layout.content.children.filter(it.id == id)[0]
			row := card.children.filter(it.id == '${id}_reactions')[0]
			assert row.children.len == 8
			assert row.frame.y + row.frame.height < card.frame.height
			for pill in row.children {
				assert pill.frame.x >= 0 && pill.frame.x + pill.frame.width <= row.frame.width
				assert pill.frame.y + pill.frame.height <= row.frame.height
				assert pill.accessibility_label == pill.tooltip
				assert !pill.clickable
			}
			assert row.children[0].children[0].text == '👍 123456'
			assert row.children[0].box.border_color == blue
			assert row.children[0].tooltip.contains('You reacted')
			assert row.children[1].box.border_color == border
			if width == 240 {
				assert row.frame.height > 26
			}
		}
		ui2.validate_element_tree(layout.content) or { panic(err) }
	}
	empty := discussion_card('empty', 'alice', 'opened', 'Description', []ReactionGroup{}, Repository{}, 400, 0)
	assert !empty.children.any(it.id == 'empty_reactions')
}
