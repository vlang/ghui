module main

import json2
import os
import strings
import sync.stdatomic
import time

const first_issue_batch = 15
const page_size = 50

const github_query = r'query Issues($owner: String!, $name: String!, $state: IssueState!, $cursor: String, $first: Int!) {
  repository(owner: $owner, name: $name) {
    open: issues(states: OPEN) { totalCount }
    closed: issues(states: CLOSED) { totalCount }
    issues(first: $first, after: $cursor, states: [$state], orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title url state stateReason createdAt updatedAt
        author { login }
        labels(first: 20) { nodes { name color } }
        assignees(first: 20) { nodes { login } }
        milestone { title }
        ' + reaction_group_fields + '
        comments { totalCount }
      }
    }
  }
}'

const pull_requests_query = r'query PullRequests($owner: String!, $name: String!, $states: [PullRequestState!]!, $cursor: String, $first: Int!) {
  repository(owner: $owner, name: $name) {
    open: pullRequests(states: OPEN) { totalCount }
    closed: pullRequests(states: [CLOSED, MERGED]) { totalCount }
    issues: pullRequests(first: $first, after: $cursor, states: $states, orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        __typename number title url state isDraft mergeable createdAt updatedAt totalCommentsCount
        baseRefName headRefName additions deletions changedFiles
        mergedAt mergedBy { login }
        author { login }
        labels(first: 20) { nodes { name color } }
        assignees(first: 20) { nodes { login } }
        milestone { title }
        ' + reaction_group_fields + '
        comments { totalCount }
      }
    }
  }
}'

enum ItemKind {
	issues
	prs
}

fn (kind ItemKind) label() string {
	return if kind == .prs { 'PRs' } else { 'Issues' }
}

fn (kind ItemKind) singular() string {
	return if kind == .prs { 'Pull request' } else { 'Issue' }
}

struct Repository {
	owner string
	name  string
}

fn parse_repository(value string) !Repository {
	parts := value.split('/')
	if parts.len != 2 || parts.any(it.len == 0) {
		return error('Expected a repository in OWNER/REPO format, for example vlang/v.')
	}
	for part in parts {
		for ch in part.bytes() {
			if !((ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`)
				|| (ch >= `0` && ch <= `9`) || ch in [`-`, `_`, `.`]) {
				return error('Repository names may contain letters, numbers, hyphens, underscores and dots.')
			}
		}
		if part in ['.', '..'] {
			return error('Expected a repository in OWNER/REPO format.')
		}
	}
	return Repository{ owner: parts[0], name: parts[1] }
}

fn (repo Repository) str() string {
	return '${repo.owner}/${repo.name}'
}

struct User {
	login string
}

struct IssueLabel {
	name  string
	color string
}

struct LabelConnection {
	nodes []IssueLabel
}

struct UserConnection {
	nodes []User
}

struct Milestone {
	title string
}

struct Count {
	total int @[json: totalCount]
}

struct Issue {
	kind          ItemKind
	is_draft      bool   @[json: isDraft]
	mergeable     string
	base_ref      string @[json: baseRefName]
	head_ref      string @[json: headRefName]
	head_oid      string @[json: headRefOid]
	merged_at     string @[json: mergedAt]
	merged_by     User   @[json: mergedBy]
	additions     int
	deletions     int
	changed_files int @[json: changedFiles]
	number        int
	title         string
	body          string
	url           string
	state         string
	state_reason  string @[json: stateReason]
	created_at    string @[json: createdAt]
	updated_at    string @[json: updatedAt]
	author        User
	labels        LabelConnection
	assignees     UserConnection
	milestone     Milestone
	comments      Count
	pull_requests Count @[json: closedByPullRequestsReferences]
	reaction_groups []ReactionGroup @[json: reactionGroups]
}

fn (issue Issue) github_url(repo Repository) string {
	if issue.url != '' { return issue.url }
	path := if issue.kind == .prs { 'pull' } else { 'issues' }
	return 'https://github.com/${repo}/${path}/${issue.number}'
}

fn (issue Issue) list_state() string {
	return if issue.state == 'MERGED' { 'CLOSED' } else { issue.state }
}

fn (issue Issue) has_merge_conflicts() bool {
	return issue.kind == .prs && issue.state == 'OPEN' && issue.mergeable == 'CONFLICTING'
}

fn (issue Issue) status() string {
	return if issue.state == '' {
		'Loading'
	} else if issue.state == 'MERGED' {
		'Merged'
	} else if issue.state == 'CLOSED' {
		'Closed'
	} else if issue.is_draft {
		'Draft'
	} else {
		'Open'
	}
}

struct IssuePage {
	issues       []Issue
	supplemental []Issue
	open_count   int
	closed_count int
	has_next     bool
	cursor       string
}

struct FetchRequest {
	kind            ItemKind
	generation      int
	repo            Repository
	state           string
	sort            string
	cursor          string
	append          bool
	limit           int = page_size
	use_cache       bool
	refresh_through Issue
	cancel          &FetchCancellation = unsafe { nil }
}

struct FetchResult {
	request       FetchRequest
	page          IssuePage
	error         string
	done          bool = true
	cached        bool
	stored        bool
	storage_error string
}

// Only this flag is shared across threads; all app state stays on the UI thread.
@[heap]
struct FetchCancellation {
mut:
	stopped i64
}

fn (mut token FetchCancellation) stop() {
	stdatomic.store_i64(&token.stopped, 1)
}

fn cancelled(token &FetchCancellation) bool {
	if isnil(token) { return false }
	return stdatomic.load_i64(&token.stopped) != 0
}

fn recent_closed_pr_args(request FetchRequest) []string {
	query := pull_requests_query.replace('field: CREATED_AT', 'field: UPDATED_AT')
	mut args := github_args(FetchRequest{ ...request, cursor: '', limit: page_size })
	for i, arg in args {
		if arg.starts_with('query=') { args[i] = 'query=${query}' }
	}
	return args
}

fn github_args(request FetchRequest) []string {
	// The server order is fixed so local sorting never invalidates a cursor.
	query := if request.kind == .prs { pull_requests_query } else { github_query }
	mut args := ['api', '--hostname', 'github.com', 'graphql', '-f', 'query=${query}', '-f',
		'owner=${request.repo.owner}', '-f', 'name=${request.repo.name}', '-f',
		if request.kind == .prs { 'states[]=${request.state}' } else { 'state=${request.state}' },
		'-F', 'first=${request.limit}']
	if request.kind == .prs && request.state == 'CLOSED' { args << ['-f', 'states[]=MERGED'] }
	if request.cursor != '' {
		args << ['-f', 'cursor=${request.cursor}']
	}
	return args
}

// Arguments go directly to gh, without shell interpolation. Drain its output
// while it runs so large pages cannot fill the pipe and stall the process.
fn run_gh_with_cancel(args []string, token &FetchCancellation) !string {
	return run_gh_raw_with_cancel(args, token)!.trim_space()
}

// Diff content must retain leading/trailing whitespace and its final newline.
fn run_gh_raw_with_cancel(args []string, token &FetchCancellation) !string {
	if cancelled(token) { return error('Request cancelled.') }
	gh := os.find_abs_path_of_executable('gh') or {
		return error('GitHub CLI was not found. Install gh and run gh auth login, then refresh.')
	}
	mut env := os.environ()
	env['GH_PROMPT_DISABLED'] = '1'
	env['GH_NO_UPDATE_NOTIFIER'] = '1'
	env['NO_COLOR'] = '1'
	started := time.now()
	return run_gh_process(gh, args, env, token, started) or {
		direct_env := gh_proxy_retry_environment(env, err.msg()) or { return err }
		// A refused proxy connection never reached GitHub, so retrying cannot
		// repeat a mutation. Keep the same cancellation token and time budget.
		run_gh_process(gh, args, direct_env, token, started) or {
			return error('The local proxy is unavailable. A direct GitHub connection also failed: ${err.msg()}')
		}
	}
}

fn run_gh_process(gh string, args []string, env map[string]string, token &FetchCancellation, started time.Time) !string {
	if cancelled(token) { return error('Request cancelled.') }
	if time.since(started) > 30 * time.second {
		return error('GitHub took longer than 30 seconds to respond. Try refreshing again.')
	}
	mut process := os.new_process(gh)
	process.set_args(args)
	process.set_environment(env)
	process.set_redirect_stdio()
	process.run()
	defer { process.close() }
	mut output := strings.new_builder(8192)
	mut errors := strings.new_builder(512)
	for process.is_alive() {
		if cancelled(token) {
			process.signal_term()
			process.wait()
			return error('Request cancelled.')
		}
		if time.since(started) > 30 * time.second {
			process.signal_term()
			process.wait()
			return error('GitHub took longer than 30 seconds to respond. Try refreshing again.')
		}
		mut received := false
		// Drain available blocks before sleeping. Sleeping after each 4 KB block
		// made large descriptions/reply pages take seconds just to read locally.
		for _ in 0 .. 64 {
			block := process.stdout_read()
			if block == '' { break }
			output.write_string(block)
			received = true
		}
		for _ in 0 .. 64 {
			block := process.stderr_read()
			if block == '' { break }
			errors.write_string(block)
			received = true
		}
		if !received { time.sleep(10 * time.millisecond) }
	}
	output.write_string(process.stdout_slurp())
	errors.write_string(process.stderr_slurp())
	process.wait()
	text := output.str()
	if process.code != 0 {
		message := errors.str().trim_space()
		return error(if message != '' {
			message
		} else if text.trim_space() != '' {
			text.trim_space()
		} else {
			'gh failed: ${process.err}'
		})
	}
	return text
}

fn decode_page(source string) !IssuePage {
	response := json2.decode[json2.Any](source) or {
		return error('Could not read GitHub’s response: ${err}')
	}
	mut messages := []string{}
	for item in json_array(json_field(response, 'errors')) {
		messages << json_text(json_field(item, 'message'))
	}
	if messages.len > 0 { return error(messages.join('\n')) }
	repo := json_object(json_field(json_field(response, 'data'), 'repository'))
	if repo.len == 0 {
		return error('Repository was not found, or your gh account does not have access.')
	}
	connection := json_object(json_field(repo, 'issues'))
	if 'nodes' !in connection || 'open' !in repo || 'closed' !in repo {
		return error('GitHub’s response did not contain issue data.')
	}
	mut issues := []Issue{}
	for item in json_array(json_field(connection, 'nodes')) {
		issues << decode_issue(item)!
	}
	page_info := json_field(connection, 'pageInfo')
	return IssuePage{
		issues:       issues
		open_count:   json_field(json_field(repo, 'open'), 'totalCount').int()
		closed_count: json_field(json_field(repo, 'closed'), 'totalCount').int()
		has_next:     json_field(page_info, 'hasNextPage').bool()
		cursor:       json_text(json_field(page_info, 'endCursor'))
	}
}

fn decode_issue(item json2.Any) !Issue {
	if json_field(item, 'number').int() <= 0 || json_text(json_field(item, 'title')) == '' {
		return error('GitHub returned an issue without a number or title.')
	}
	mut labels := []IssueLabel{}
	for label in json_array(json_field(json_field(item, 'labels'), 'nodes')) {
		labels << IssueLabel{
			name:  json_text(json_field(label, 'name'))
			color: json_text(json_field(label, 'color'))
		}
	}
	mut assignees := []User{}
	for user in json_array(json_field(json_field(item, 'assignees'), 'nodes')) {
		assignees << User{ login: json_text(json_field(user, 'login')) }
	}
	return Issue{
		kind:          if json_text(json_field(item, '__typename')) == 'PullRequest' || json_text(json_field(item, 'kind')) == 'prs' {
			.prs
		} else {
			.issues
		}
		is_draft:      json_field(item, 'isDraft').bool()
		mergeable:     json_text(json_field(item, 'mergeable'))
		base_ref:      json_text(json_field(item, 'baseRefName'))
		head_ref:      json_text(json_field(item, 'headRefName'))
		head_oid:      json_text(json_field(item, 'headRefOid'))
		merged_at:     json_text(json_field(item, 'mergedAt'))
		merged_by:     User{ login: json_text(json_field(json_field(item, 'mergedBy'), 'login')) }
		additions:     json_field(item, 'additions').int()
		deletions:     json_field(item, 'deletions').int()
		changed_files: json_field(item, 'changedFiles').int()
		number:        json_field(item, 'number').int()
		title:         json_text(json_field(item, 'title'))
		body:          json_text(json_field(item, 'body'))
		url:           json_text(json_field(item, 'url'))
		state:         json_text(json_field(item, 'state'))
		state_reason:  json_text(json_field(item, 'stateReason'))
		created_at:    json_text(json_field(item, 'createdAt'))
		updated_at:    json_text(json_field(item, 'updatedAt'))
		author:        User{ login: json_text(json_field(json_field(item, 'author'), 'login')) }
		labels:        LabelConnection{ nodes: labels }
		assignees:     UserConnection{ nodes: assignees }
		milestone:     Milestone{ title: json_text(json_field(json_field(item, 'milestone'), 'title')) }
		comments:      Count{ total: github_comment_count(item) }
		pull_requests: Count{ total: json_field(json_field(item, 'closedByPullRequestsReferences'), 'totalCount').int() }
		reaction_groups: decode_reaction_groups(item)
	}
}

fn github_comment_count(item json2.Any) int {
	// PR comments.totalCount excludes review summaries and inline comments.
	if 'totalCommentsCount' in json_object(item) {
		return json_field(item, 'totalCommentsCount').int()
	}
	return json_field(json_field(item, 'comments'), 'totalCount').int()
}

// GitHub returns null for deleted authors, milestones and state reasons.
fn json_field(value json2.Any, key string) json2.Any {
	if value is map[string]json2.Any { return value[key] or { json2.null } }
	return json2.null
}

fn json_object(value json2.Any) map[string]json2.Any {
	if value is map[string]json2.Any { return value }
	return {}
}

fn json_array(value json2.Any) []json2.Any {
	if value is []json2.Any { return value }
	return []json2.Any{}
}

fn json_text(value json2.Any) string {
	if value is string { return value }
	return ''
}

fn fetch_issues(request FetchRequest) !IssuePage {
	return decode_page(run_gh_with_cancel(github_args(request), request.cancel)!)
}

fn fetch_in_background(request FetchRequest, results chan FetchResult) {
	mut refresh_through := request.refresh_through
	if !request.append {
		started := time.now()
		if cached := read_issue_cache(request) {
			if cancelled(request.cancel) { return }
			for issue in cached.issues {
				if refresh_through.number == 0 || compare_issues_oldest(&issue, &refresh_through) < 0 {
					refresh_through = issue
				}
			}
			if request.use_cache {
				profile_fetch('cached issues (${cached.issues.len})', started)
				results <- FetchResult{ request: request, page: cached, cached: true, done: false }
				wake_ui()
			}
		}
	}
	// Keep creation-order cursors for Load more, but include recently active
	// closed PRs that may have been created long before the loaded pages.
	mut recent := []Issue{}
	if request.kind == .prs && request.state == 'CLOSED' && !request.append {
		source := run_gh_with_cancel(recent_closed_pr_args(request), request.cancel) or {
			if cancelled(request.cancel) { return }
			results <- FetchResult{ request: request, error: err.msg() }
			wake_ui()
			return
		}
		page := decode_page(source) or {
			results <- FetchResult{ request: request, error: err.msg() }
			wake_ui()
			return
		}
		recent = page.issues
	}
	mut cursor := request.cursor
	mut loaded := IssuePage{}
	mut remaining := page_size
	for {
		if cancelled(request.cancel) { return }
		limit := if loaded.issues.len == 0 { first_issue_batch } else if remaining > 0 { remaining } else { page_size }
		batch := FetchRequest{ ...request, cursor: cursor, limit: limit }
		started := time.now()
		source := run_gh_with_cancel(github_args(batch), request.cancel) or {
			if cancelled(request.cancel) { return }
			results <- FetchResult{ request: request, error: err.msg() }
			wake_ui()
			return
		}
		page := decode_page(source) or {
			results <- FetchResult{ request: request, error: err.msg() }
			wake_ui()
			return
		}
		if cancelled(request.cancel) { return }
		profile_fetch('issues (${page.issues.len})', started)
		issues := merge_issues(loaded.issues, page.issues)
		loaded = IssuePage{ ...page, issues: issues }
		remaining -= page.issues.len
		// Revalidate every loaded row, including older pages kept in SQLite.
		// Otherwise a PR merged beyond the first page can remain open forever.
		last := if page.issues.len > 0 { page.issues.last() } else { Issue{} }
		refreshed := refresh_through.number == 0 || compare_issues_oldest(&last, &refresh_through) <= 0
		done := (remaining <= 0 && refreshed) || !page.has_next || page.issues.len == 0 || page.cursor == cursor
		mut storage_error := ''
		stored := store_issue_page(request, loaded, done) or {
			storage_error = err.msg()
			loaded
		}
		if cancelled(request.cancel) { return }
		canonical_numbers := stored.issues.map(it.number)
		supplemental := recent.filter(it.number !in canonical_numbers)
		shown := IssuePage{ ...stored, issues: merge_recent_prs(stored.issues, recent), supplemental: supplemental }
		results <- FetchResult{ request: request, page: shown, done: done, stored: storage_error == '' && os.getenv('GHGUI_NO_CACHE') != '1', storage_error: storage_error }
		wake_ui()
		if done { return }
		cursor = page.cursor
	}
}

// Prefer the newest metadata when the two independent reads overlap.
fn merge_recent_prs(canonical []Issue, recent []Issue) []Issue {
	mut issues := canonical.clone()
	for issue in recent {
		mut found := false
		for i, existing in issues {
			if existing.number == issue.number {
				if issue_updated_at(issue) > issue_updated_at(existing)
					|| (issue_updated_at(issue) == issue_updated_at(existing) && issue.state == 'MERGED' && existing.state != 'MERGED') {
					issues[i] = issue
				}
				found = true
				break
			}
		}
		if !found { issues << issue }
	}
	return issues
}

fn merge_issues(first []Issue, second []Issue) []Issue {
	mut issues := first.clone()
	mut seen := map[int]bool{}
	for issue in issues { seen[issue.number] = true }
	for issue in second {
		if issue.number !in seen {
			issues << issue
			seen[issue.number] = true
		}
	}
	return issues
}

fn profile_fetch(kind string, started time.Time) {
	if os.getenv('GHGUI_PROFILE') == '1' {
		eprintln('${kind} ready in ${time.since(started).milliseconds()}ms')
	}
}

fn relative_time(source string, now time.Time) string {
	created := time.parse_iso8601(source) or { return 'at an unknown time' }
	seconds := i64((now - created).seconds())
	if seconds < 60 { return 'just now' }
	if seconds < 3600 { return '${seconds / 60}m ago' }
	if seconds < 86400 { return '${seconds / 3600}h ago' }
	if seconds < 2592000 { return '${seconds / 86400}d ago' }
	if seconds < 31536000 { return '${seconds / 2592000}mo ago' }
	return '${seconds / 31536000}y ago'
}

fn format_count(number int) string {
	digits := number.str()
	mut result := ''
	for i, digit in digits {
		if i > 0 && (digits.len - i) % 3 == 0 { result += ',' }
		result += digit.ascii_str()
	}
	return result
}
