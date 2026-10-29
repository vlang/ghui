module main

import clipboard
import time

const issue_sort_options = ['Newest', 'Oldest', 'Most commented', 'Least commented',
	'Recently updated', 'Least recently updated']

struct CachedDetail {
	detail          IssueDetail
	body_loaded     bool
	comments_loaded bool
}

@[heap]
struct App {
mut:
	repo                      Repository
	kind                      ItemKind
	state                     string = 'OPEN'
	sort                      string = 'Newest'
	search                    string
	search_pending            bool
	search_generation         int
	search_request            SearchRequest
	search_results            chan SearchRequest = chan SearchRequest{cap: 8}
	author                    string = 'Author'
	label                     string = 'Labels'
	assignee                  string = 'Assignees'
	milestone                 string = 'Milestones'
	issues                    []Issue
	supplemental              []Issue
	selected                  map[int]bool
	open_count                int
	closed_count              int
	loaded_state              string
	loading                   bool
	list_received             bool
	list_cached               bool
	list_cache                map[string]IssuePage
	list_cancel               &FetchCancellation = unsafe { nil }
	initialized               bool
	generation                int
	has_next                  bool
	cursor                    string
	error                     string
	storage_error             string
	updated                   string
	compact                   bool
	results                   chan FetchResult = chan FetchResult{cap: 8}
	active_issue              int
	open_pr_visible           bool
	open_pr_text              string
	open_pr_error             string
	open_pr_previous_focus    string
	detail                    IssueDetail
	detail_loading            bool
	detail_loaded             bool
	detail_body_loading       bool
	detail_comments_loading   bool
	detail_comments_loaded    bool
	detail_cache              map[int]CachedDetail
	detail_cancel             &FetchCancellation = unsafe { nil }
	detail_error              string
	detail_generation         int
	detail_results            chan DetailResult = chan DetailResult{cap: 8}
	diff_visible              bool
	diff_loading              bool
	diff_loaded               bool
	pr_diff                   PullRequestDiff
	diff_error                string
	diff_generation           int
	diff_request              DiffRequest
	diff_results              chan DiffResult = chan DiffResult{cap: 8}
	diff_discussion_scroll    f64
	reference_generation      int
	reference_loading         bool
	reference_error           string
	reference_request         ReferenceRequest
	reference_results         chan ReferenceResult = chan ReferenceResult{cap: 8}
	close_loading             bool
	close_generation          int
	close_request             CloseIssueRequest
	close_errors              map[int]string
	close_results             chan CloseIssueResult = chan CloseIssueResult{cap: 1}
	close_pr_loading          bool
	close_pr_generation       int
	close_pr_request          ClosePrRequest
	close_pr_errors           map[int]string
	close_pr_results          chan ClosePrResult = chan ClosePrResult{cap: 1}
	merge_loading             bool
	merge_generation          int
	merge_request             MergeRequest
	merge_errors              map[int]string
	merge_results             chan MergeResult = chan MergeResult{cap: 1}
	ready_loading             bool
	ready_generation          int
	ready_request             ReadyRequest
	ready_errors              map[int]string
	ready_results             chan ReadyResult = chan ReadyResult{cap: 1}
	comment_drafts            map[int]string
	repository_drafts         map[string]map[int]string
	comment_loading           bool
	comment_generation        int
	comment_request           CommentRequest
	comment_errors            map[int]string
	comment_results           chan CommentResult = chan CommentResult{cap: 1}
	chatgpt_reviews           map[string]ChatgptReview
	chatgpt_review_pending    map[string]bool
	chatgpt_review_results    chan ChatgptReviewResult = chan ChatgptReviewResult{cap: 8}
	chatgpt_review_error      string
	last_review_pr            string
	list_scroll               f64
	system_clipboard          &clipboard.Clipboard = unsafe { nil }
	screenshot_detail_started bool
	screenshot_comments_ready bool
	screenshot_diff_started   bool
	pending_url_diff          bool
	startup_url               string
}

const app_state = &App{}

fn (app &App) list_scroll_id() string {
	return '${app.kind}_${app.state}'
}

fn (app &App) list_key() string {
	return '${app.kind}_${app.state}'
}

fn (app &App) detail_scroll_id() string {
	return 'detail_${app.kind}_${app.active_issue}'
}

fn (mut app App) open_issue(number int) {
	app.pending_url_diff = false
	app.close_diff()
	app.cancel_reference()
	if !isnil(app.detail_cancel) { app.detail_cancel.stop() }
	app.active_issue = number
	app.detail_loaded = false
	app.detail_comments_loaded = false
	app.detail_error = ''
	app.detail = IssueDetail{ issue: Issue{ kind: app.kind, number: number } }
	for issue in app.issues {
		if issue.number == number {
			app.detail = IssueDetail{ issue: issue }
			break
		}
	}
	if cached := app.detail_cache[number] {
		if cached.detail.issue.kind == app.kind {
			app.detail = cached.detail
			app.detail_loaded = cached.body_loaded
			app.detail_comments_loaded = cached.comments_loaded
		}
	}
}

fn (mut app App) close_issue() {
	app.pending_url_diff = false
	app.close_diff()
	app.cancel_reference()
	if !isnil(app.detail_cancel) { app.detail_cancel.stop() }
	app.active_issue = 0
	app.detail_generation++
	app.detail_loading = false
	app.detail_body_loading = false
	app.detail_comments_loading = false
}

fn (mut app App) begin_detail_fetch(append_page bool) DetailRequest {
	app.cancel_reference()
	if !isnil(app.detail_cancel) { app.detail_cancel.stop() }
	app.detail_cancel = &FetchCancellation{}
	app.detail_generation++
	app.detail_loading = true
	app.detail_body_loading = !append_page
	app.detail_comments_loading = true
	app.detail_error = ''
	return DetailRequest{
		kind:       app.kind
		generation: app.detail_generation
		repo:       app.repo
		number:     app.active_issue
		cursor:     if append_page { app.detail.cursor } else { '' }
		append:     append_page
		cancel:     app.detail_cancel
	}
}

fn (mut app App) apply_detail_result(result DetailResult) {
	if result.request.generation != app.detail_generation || result.request.number != app.active_issue || result.request.kind != app.kind {
		return
	}
	if result.part in [.body, .complete] && !result.cached { app.detail_body_loading = false }
	if result.part in [.comments, .complete] {
		app.detail_comments_loading = !result.done && result.error == ''
	}
	app.detail_loading = app.detail_body_loading || app.detail_comments_loading
	if result.storage_error != '' { app.storage_error = result.storage_error }
	if result.error != '' {
		app.detail_error = if app.detail_error == '' {
			result.error
		} else {
			'${app.detail_error}\n${result.error}'
		}
		return
	}
	if result.part in [.body, .complete] {
		app.detail = IssueDetail{ ...app.detail, issue: result.detail.issue }
		app.detail_loaded = true
	}
	if result.part in [.comments, .complete] {
		// Comments added from here stay last until a later read returns the whole discussion.
		complete := result.done && !result.detail.has_next
		posted := app.detail.comments.filter(it.posted > 0
			&& (!complete || result.request.generation <= it.posted))
		loaded := app.detail.comments.filter(it.posted == 0)
		mut fetched := if result.request.append {
			merge_comments(loaded, result.detail.comments)
		} else if !result.done {
			// Keep cached replies visible until their replacements have arrived.
			merge_comments(result.detail.comments, loaded)
		} else {
			result.detail.comments
		}
		if app.kind == .prs { fetched = sort_discussion_comments(fetched) }
		comments := merge_comments(fetched, posted)
		app.detail = IssueDetail{
			...app.detail
			issue:    Issue{ ...app.detail.issue, comments: Count{ total: int_max(result.detail.issue.comments.total, comments.len) } }
			comments: comments
			has_next: result.detail.has_next
			cursor:   result.detail.cursor
		}
		app.detail_comments_loaded = true
	}
	app.detail_cache[app.active_issue] = CachedDetail{
		detail:          app.detail
		body_loaded:     app.detail_loaded
		comments_loaded: app.detail_comments_loaded
	}
	for i, issue in app.issues {
		if issue.number == app.active_issue && app.detail_loaded {
			app.issues[i] = app.detail.issue
			break
		}
	}
	app.issues = sort_issues(app.issues.filter(it.list_state() == app.state), app.sort)
}

fn (mut app App) begin_fetch(append_page bool) FetchRequest {
	if !isnil(app.list_cancel) { app.list_cancel.stop() }
	app.list_cancel = &FetchCancellation{}
	app.generation++
	app.loading = true
	app.list_received = false
	app.list_cached = !append_page && app.issues.len > 0
	app.error = ''
	app.storage_error = ''
	mut refresh_through := Issue{}
	if !append_page {
		supplemental_numbers := app.supplemental.map(it.number)
		for issue in app.issues {
			if issue.number in supplemental_numbers { continue }
			if refresh_through.number == 0 || compare_issues_oldest(&issue, &refresh_through) < 0 {
				refresh_through = issue
			}
		}
	}
	return FetchRequest{
		kind:            app.kind
		generation:      app.generation
		repo:            app.repo
		state:           app.state
		sort:            app.sort
		cursor:          if append_page { app.cursor } else { '' }
		append:          append_page
		use_cache:       !append_page && app.issues.len == 0
		refresh_through: refresh_through
		cancel:          app.list_cancel
	}
}

fn (mut app App) apply_result(result FetchResult) {
	// A tab change can supersede a request still in flight; sorting stays local.
	if result.request.generation != app.generation || result.request.kind != app.kind { return }
	app.loading = !result.done && result.error == ''
	if result.storage_error != '' { app.storage_error = result.storage_error }
	if result.error != '' {
		app.error = result.error
		return
	}
	if result.request.append {
		loaded_numbers := result.page.issues.map(it.number)
		supplemental_numbers := app.supplemental.map(it.number)
		app.supplemental = app.issues.filter(it.number in supplemental_numbers
			&& it.number !in loaded_numbers && it.list_state() == app.state)
	} else if !result.cached {
		app.supplemental = result.page.supplemental
	}
	if result.stored {
		app.issues = merge_issues(result.page.issues, app.supplemental)
		if !app.list_received && !result.request.append { app.selected.clear() }
	} else if result.request.append {
		app.issues = merge_issues(app.issues, result.page.issues)
	} else {
		app.issues = if !result.done && !result.cached {
			merge_issues(result.page.issues, app.issues)
		} else {
			result.page.issues
		}
		if !app.list_received && !result.cached { app.selected.clear() }
	}
	app.issues = sort_issues(app.issues, app.sort)
	app.loaded_state = result.request.state
	app.open_count = result.page.open_count
	app.closed_count = result.page.closed_count
	app.has_next = result.page.has_next
	app.cursor = result.page.cursor
	if result.cached {
		app.list_cached = true
	} else {
		app.list_received = true
		app.updated = time.now().hhmm()
		if result.done { app.list_cached = false }
	}
	if result.done && !result.cached {
		app.list_cache[app.list_key()] = IssuePage{ ...result.page, issues: app.issues, supplemental: app.supplemental }
	}
}

fn (mut app App) change_state(state string) {
	app.state = state
	app.issues = []Issue{}
	app.supplemental = []Issue{}
	app.selected.clear()
	app.has_next = false
	app.cursor = ''
	app.loaded_state = ''
	app.error = ''
	app.clear_filters()
	app.restore_list()
}

fn (mut app App) change_kind(kind ItemKind) {
	if kind == app.kind { return }
	if app.loaded_state != '' {
		app.list_cache[app.list_key()] = IssuePage{
			issues:       app.issues
			supplemental: app.supplemental
			open_count:   app.open_count
			closed_count: app.closed_count
			has_next:     app.has_next
			cursor:       app.cursor
		}
	}
	if !isnil(app.list_cancel) { app.list_cancel.stop() }
	app.generation++
	app.close_issue()
	app.kind = kind
	app.loading = false
	app.open_count = 0
	app.closed_count = 0
	app.storage_error = ''
	app.updated = ''
	app.list_scroll = 0
	app.change_state('OPEN')
}

fn (mut app App) change_sort(sort string) {
	if sort !in issue_sort_options { return }
	app.sort = sort
	app.issues = sort_issues(app.issues, app.sort)
}

fn (mut app App) restore_list() {
	if page := app.list_cache[app.list_key()] {
		app.issues = sort_issues(page.issues.filter(it.list_state() == app.state), app.sort)
		app.supplemental = page.supplemental.filter(it.list_state() == app.state)
		app.open_count = page.open_count
		app.closed_count = page.closed_count
		app.has_next = page.has_next
		app.cursor = page.cursor
		app.loaded_state = app.state
	}
}

fn issue_updated_at(issue Issue) string {
	return if issue.updated_at != '' { issue.updated_at } else { issue.created_at }
}

fn sort_issues(source []Issue, sort string) []Issue {
	mut issues := source.clone()
	match sort {
		'Oldest' {
			issues.sort_with_compare(compare_issues_oldest)
		}
		'Recently updated' {
			issues.sort_with_compare(compare_issues_updated)
		}
		'Least recently updated' {
			issues.sort_with_compare(compare_issues_least_updated)
		}
		'Most commented' {
			issues.sort_with_compare(compare_issues_most_commented)
		}
		'Least commented' {
			issues.sort_with_compare(compare_issues_least_commented)
		}
		else {
			issues.sort_with_compare(compare_issues_newest)
		}
	}
	return issues
}

fn compare_issue_keys(first string, second string, first_number int, second_number int) int {
	if first < second { return -1 }
	if first > second { return 1 }
	if first_number < second_number { return -1 }
	if first_number > second_number { return 1 }
	return 0
}

fn compare_issues_oldest(first &Issue, second &Issue) int {
	return compare_issue_keys(first.created_at, second.created_at, first.number, second.number)
}

fn compare_issues_newest(first &Issue, second &Issue) int {
	return -compare_issues_oldest(first, second)
}

fn compare_issues_updated(first &Issue, second &Issue) int {
	return -compare_issue_keys(issue_updated_at(first), issue_updated_at(second), first.number, second.number)
}

fn compare_issues_least_updated(first &Issue, second &Issue) int {
	return -compare_issues_updated(first, second)
}

fn compare_issues_most_commented(first &Issue, second &Issue) int {
	if first.comments.total > second.comments.total { return -1 }
	if first.comments.total < second.comments.total { return 1 }
	return compare_issues_newest(first, second)
}

fn compare_issues_least_commented(first &Issue, second &Issue) int {
	if first.comments.total < second.comments.total { return -1 }
	if first.comments.total > second.comments.total { return 1 }
	return compare_issues_newest(first, second)
}

fn (mut app App) clear_filters() {
	app.cancel_search()
	app.search = ''
	app.author = 'Author'
	app.label = 'Labels'
	app.assignee = 'Assignees'
	app.milestone = 'Milestones'
}

fn (app &App) visible_issues() []Issue {
	query := app.search.trim_space().to_lower()
	return app.issues.filter((query == '' || it.title.to_lower().contains(query) || it.number.str() == query.trim_left('#')
		|| it.author.login.to_lower().contains(query))
		&& (app.author == 'Author' || it.author.login == app.author)
		&& (app.label == 'Labels' || it.labels.nodes.any(it.name == app.label))
		&& (app.assignee == 'Assignees' || it.assignees.nodes.any(it.login == app.assignee))
		&& (app.milestone == 'Milestones' || it.milestone.title == app.milestone))
}

fn (app &App) filter_options(kind string) []string {
	mut unique := map[string]bool{}
	for issue in app.issues {
		match kind {
			'Author' { unique[issue.author.login] = true }
			'Labels' {
				for label in issue.labels.nodes { unique[label.name] = true }
			}
			'Assignees' {
				for user in issue.assignees.nodes { unique[user.login] = true }
			}
			'Milestones' { unique[issue.milestone.title] = true }
			else {}
		}
	}
	unique.delete('')
	mut options := unique.keys()
	options.sort()
	mut result := [kind]
	result << options
	return result
}

fn (app &App) all_visible_selected(issues []Issue) bool {
	return issues.len > 0 && issues.all(app.selected[it.number] or { false })
}

fn (mut app App) toggle_selection(number int) {
	if app.selected[number] or { false } {
		app.selected.delete(number)
	} else {
		app.selected[number] = true
	}
}

fn (mut app App) toggle_all() {
	issues := app.visible_issues()
	all_selected := app.all_visible_selected(issues)
	for issue in issues {
		if all_selected {
			app.selected.delete(issue.number)
		} else {
			app.selected[issue.number] = true
		}
	}
}
