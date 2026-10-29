module main

import json2
import math
import ui2

// Keep nested PR review queries bounded and tooltips readable.
const reaction_group_fields = 'reactionGroups { content viewerHasReacted reactors(first: 10) { totalCount nodes { ... on User { login } ... on Bot { login } ... on Organization { login } ... on Mannequin { login } } } }'

const reaction_contents = ['THUMBS_UP', 'THUMBS_DOWN', 'LAUGH', 'HOORAY', 'CONFUSED', 'HEART',
	'ROCKET', 'EYES']

struct ReactorConnection {
	total int @[json: totalCount]
	nodes []User
}

struct ReactionGroup {
	content            string
	reactors           ReactorConnection
	viewer_has_reacted bool @[json: viewerHasReacted]
}

fn decode_reaction_groups(item json2.Any) []ReactionGroup {
	mut groups := []ReactionGroup{}
	for node in json_array(json_field(item, 'reactionGroups')) {
		content := json_text(json_field(node, 'content'))
		connection := json_field(node, 'reactors')
		count := json_field(connection, 'totalCount').int()
		if content !in reaction_contents || count <= 0 { continue }
		mut users := []User{}
		mut seen := map[string]bool{}
		for reactor in json_array(json_field(connection, 'nodes')) {
			login := json_text(json_field(reactor, 'login'))
			if login == '' || login.to_lower() in seen { continue }
			users << User{ login: login }
			seen[login.to_lower()] = true
		}
		groups << ReactionGroup{
			content:            content
			reactors:           ReactorConnection{ total: count, nodes: users }
			viewer_has_reacted: json_field(node, 'viewerHasReacted').bool()
		}
	}
	return groups
}

fn (group ReactionGroup) emoji() string {
	return match group.content {
		'THUMBS_UP' { '👍' }
		'THUMBS_DOWN' { '👎' }
		'LAUGH' { '😄' }
		'HOORAY' { '🎉' }
		'CONFUSED' { '😕' }
		'HEART' { '❤️' }
		'ROCKET' { '🚀' }
		'EYES' { '👀' }
		else { '' }
	}
}

fn (group ReactionGroup) description() string {
	name := match group.content {
		'THUMBS_UP' { 'Thumbs up' }
		'THUMBS_DOWN' { 'Thumbs down' }
		'LAUGH' { 'Laugh' }
		'HOORAY' { 'Hooray' }
		'CONFUSED' { 'Confused' }
		'HEART' { 'Heart' }
		'ROCKET' { 'Rocket' }
		'EYES' { 'Eyes' }
		else { '' }
	}
	mut description := '${name}: ${group.reactors.total} reaction${if group.reactors.total == 1 {
		''
	} else {
		's'
	}}' +
		if group.viewer_has_reacted { ' · You reacted' } else { '' }
	users := group.reactors.nodes.filter(it.login != '').map('@${it.login}')
	if users.len > 0 {
		description += '\n' + users.join(', ')
		remaining := math.max(0, group.reactors.total - users.len)
		if remaining > 0 {
			description += ' and ${remaining} other${if remaining == 1 { '' } else { 's' }}'
		}
	}
	return description
}

fn reaction_row(id string, groups []ReactionGroup, width f64, y f64) ui2.Element {
	mut children := []ui2.Element{}
	mut x := 0.0
	mut row_y := 0.0
	available := math.max(1, width)
	for content in reaction_contents {
		matching := groups.filter(it.content == content && it.reactors.total > 0)
		if matching.len == 0 { continue }
		group := matching[0]
		count := group.reactors.total.str()
		// Leave room for native label insets, the emoji, and full digit widths.
		pill_width := math.min(available, math.max(56, 44 + count.len * 8.4))
		if x > 0 && x + pill_width > available {
			x = 0
			row_y += 32
		}
		pill_id := '${id}_${content.to_lower()}'
		tooltip := group.description()
		style := bordered_box(if group.viewer_has_reacted { u32(0xddf4ff) } else { subtle }, 13)
		children << ui2.Element{
			...ui2.view(pill_id, ui2.rect(x, row_y, pill_width, 26),
				ui2.BoxStyle{
					...style
					border_color: if group.viewer_has_reacted {
						blue
					} else {
						border
					}
				}, [
					ui2.with_tooltip(ui2.label('${pill_id}_text', '${group.emoji()} ${count}', ui2.rect(4, 1, pill_width - 8, 24),
						ui2.TextStyle{
							size:  12
							color: if group.viewer_has_reacted {
								blue
							} else {
								muted
							}
							align: .center
						}), tooltip),
				])
			tooltip:             tooltip
			accessibility_label: tooltip
		}
		x += pill_width + 6
	}
	return ui2.view(id, ui2.rect(12, y, available, if children.len > 0 { row_y + 26 } else { 0 }),
		box(0xffffff, 0), children)
}
