module main

import db.sqlite
import json2
import os

type IssueDatabase = sqlite.DB

@[table: 'issues']
struct StoredIssue {
	key         string @[primary]
	repository  string
	number      int
	title       string
	state       string
	created_at  string
	updated_at  string
	metadata    string
	body        string
	body_loaded bool
	listed      bool
}

@[table: 'repositories']
struct StoredRepository {
	key             string @[primary]
	open_count      int
	closed_count    int
	legacy_imported bool
}

@[table: 'issue_pages']
struct StoredPage {
	key            string @[primary]
	repository     string
	state          string
	cursor         string
	has_next       bool
	oldest_created string
	oldest_number  int
}

// Used only to import existing caches. New data is stored as ORM rows.
struct IssueCache {
	version  int = 1
	saved_at i64
	pages    []string
}

fn legacy_cache_root() string {
	mut root := os.getenv('GHGUI_CACHE_DIR')
	if root == '' {
		$if macos {
			root = os.join_path(os.home_dir(), 'Library', 'Caches', 'ghgui')
		} $else {
			base := os.getenv('XDG_CACHE_HOME')
			root = os.join_path(if base != '' {
				base
			} else {
				os.join_path(os.home_dir(), '.cache')
			}, 'ghgui')
		}
	}
	return root
}

fn issue_database_path() string {
	if path := os.getenv_opt('GHGUI_DB_PATH') {
		if path != '' { return path }
	}
	if os.getenv('GHGUI_CACHE_DIR') != '' {
		return os.join_path(os.getenv('GHGUI_CACHE_DIR'), 'issues.sqlite3')
	}
	$if macos {
		return os.join_path(os.home_dir(), 'Library', 'Application Support', 'ghgui', 'issues.sqlite3')
	} $else {
		root := os.getenv('XDG_DATA_HOME')
		return os.join_path(if root != '' {
			root
		} else {
			os.join_path(os.home_dir(), '.local', 'share')
		}, 'ghgui', 'issues.sqlite3')
	}
}

fn open_issue_database() !IssueDatabase {
	path := issue_database_path()
	os.mkdir_all(os.dir(path))!
	mut db := sqlite.connect(path)!
	os.chmod(path, 0o600) or {}
	mut ready := false
	defer { if !ready { db.close() or {} } }
	// Connections belong to their worker, and transactions never span API calls.
	db.busy_timeout(1500)
	db.exec_param_many('PRAGMA journal_mode = WAL', []string{})!
	db.synchronization_mode(.normal)!
	sql db {
		create table StoredIssue
		create table StoredRepository
		create table StoredPage
		create table ChatgptReview
	}!
	// ORM creates the models; these indexes speed repository/state ordering.
	db.exec_param_many('CREATE INDEX IF NOT EXISTS issues_created ON issues(repository, state, listed, created_at)', []string{})!
	db.exec_param_many('CREATE INDEX IF NOT EXISTS issues_updated ON issues(repository, state, listed, updated_at)', []string{})!
	ready = true
	return IssueDatabase(db)
}

// Keep existing issue rows/keys intact while giving PRs independent counts,
// cursors and listings in the same ORM tables. No schema migration is needed.
fn storage_repository(repo Repository, kind ItemKind) string {
	return repo.str().to_lower() + if kind == .prs { ':prs' } else { '' }
}

fn (db IssueDatabase) save_issue(repo Repository, issue Issue, body_loaded bool) ! {
	repository := storage_repository(repo, issue.kind)
	key := '${repository}#${issue.number}'
	previous := sql db { select from StoredIssue where key == key }!
	mut record := StoredIssue{
		key:         key
		repository:  repository
		number:      issue.number
		title:       issue.title
		state:       issue.list_state()
		created_at:  issue.created_at
		updated_at:  issue_updated_at(issue)
		metadata:    json2.encode(Issue{ ...issue, body: '' })
		body:        issue.body
		body_loaded: body_loaded
		listed:      true
	}
	if previous.len > 0 {
		old := previous[0]
		old_metadata := json2.decode[json2.Any](old.metadata) or { json2.null }
		was_merged := issue.kind == .prs && json_text(json_field(old_metadata, 'state')) == 'MERGED'
		stale_open := old.state == 'CLOSED' && issue.state == 'OPEN'
			&& old.updated_at == record.updated_at
		stale_draft := issue.kind == .prs && !json_field(old_metadata, 'isDraft').bool()
			&& issue.is_draft && old.updated_at == record.updated_at
		if (old.updated_at > record.updated_at && issue.state != 'MERGED')
			|| (was_merged && issue.state != 'MERGED') || stale_open || stale_draft {
			// A slower response must not revert newer metadata from another worker.
			// Merged PRs cannot reopen, including reads from the same second.
			// Prefer a confirmed closure over an OPEN read from that same second.
			// Likewise, a stale draft read must not undo marking a PR ready.
			record = StoredIssue{ ...old, listed: true }
		} else if !body_loaded {
			record = StoredIssue{ ...record, body: old.body, body_loaded: old.body_loaded }
		}
		if body_loaded && (old.updated_at <= issue_updated_at(issue) || !old.body_loaded) {
			record = StoredIssue{ ...record, body: issue.body, body_loaded: true }
		}
	}
	sql db { upsert record into StoredIssue }!
}

fn (db IssueDatabase) save_page(request FetchRequest, page IssuePage, complete bool) ! {
	repository := storage_repository(request.repo, request.kind)
	previous := sql db { select from StoredRepository where key == repository }!
	record := StoredRepository{
		key:             repository
		open_count:      page.open_count
		closed_count:    page.closed_count
		legacy_imported: previous.len > 0 && previous[0].legacy_imported
	}
	sql db { upsert record into StoredRepository }!
	state := request.state
	if complete && !request.append {
		// Hide missing rows only in the range covered by a successful refresh.
		// Older pages and downloaded descriptions remain available.
		if !page.has_next {
			sql db { update StoredIssue set listed = false where repository == repository && state == state }!
		} else if page.issues.len > 0 {
			last := page.issues.last()
			boundary_created := last.created_at
			boundary_number := last.number
			sql db {
				update StoredIssue set listed = false where repository == repository && state == state
					&& (created_at > boundary_created || (created_at == boundary_created && number >= boundary_number))
			}!
		}
	}
	for issue in page.issues { db.save_issue(request.repo, issue, false)! }
	key := '${repository}:${state}'
	last := if page.issues.len > 0 { page.issues.last() } else { Issue{} }
	mut progress := StoredPage{
		key:            key
		repository:     repository
		state:          state
		cursor:         page.cursor
		has_next:       page.has_next
		oldest_created: last.created_at
		oldest_number:  last.number
	}
	old_pages := sql db { select from StoredPage where key == key }!
	if !request.append && page.has_next && old_pages.len > 0 {
		old := old_pages[0]
		if old.oldest_created < progress.oldest_created
			|| (old.oldest_created == progress.oldest_created && old.oldest_number < progress.oldest_number) {
			// Refresh the top without losing the pagination position of older data.
			progress = StoredPage{ ...old, has_next: page.has_next }
		}
	}
	sql db { upsert progress into StoredPage }!
}

fn (db IssueDatabase) issue_page(request FetchRequest) !IssuePage {
	repository := storage_repository(request.repo, request.kind)
	state := request.state
	stats := sql db { select from StoredRepository where key == repository }!
	if stats.len == 0 { return IssuePage{} }
	rows := match request.sort {
		'Oldest' {
			sql db { select key, metadata from StoredIssue where repository == repository && state == state && listed == true order by created_at asc }!
		}
		'Recently updated' {
			sql db { select key, metadata from StoredIssue where repository == repository && state == state && listed == true order by updated_at desc }!
		}
		'Least recently updated' {
			sql db { select key, metadata from StoredIssue where repository == repository && state == state && listed == true order by updated_at asc }!
		}
		else {
			sql db { select key, metadata from StoredIssue where repository == repository && state == state && listed == true order by created_at desc }!
		}
	}
	mut issues := []Issue{}
	for row in rows {
		value := json2.decode[json2.Any](row.metadata)!
		issues << decode_issue(value)!
	}
	key := '${repository}:${state}'
	pages := sql db { select from StoredPage where key == key }!
	return IssuePage{
		issues:       sort_issues(issues, request.sort)
		open_count:   stats[0].open_count
		closed_count: stats[0].closed_count
		has_next:     pages.len > 0 && pages[0].has_next
		cursor:       if pages.len > 0 { pages[0].cursor } else { '' }
	}
}

fn read_issue_cache(request FetchRequest) ?IssuePage {
	if os.getenv('GHGUI_NO_CACHE') == '1' { return none }
	mut db := open_issue_database() or { return none }
	defer { db.close() or {} }
	if request.kind == .issues { import_legacy_cache(mut db, request.repo) or { return none } }
	page := db.issue_page(request) or { return none }
	if page.issues.len == 0 && page.open_count == 0 && page.closed_count == 0 { return none }
	return page
}

fn store_issue_page(request FetchRequest, page IssuePage, complete bool) !IssuePage {
	if os.getenv('GHGUI_NO_CACHE') == '1' || cancelled(request.cancel) { return page }
	mut db := open_issue_database()!
	defer { db.close() or {} }
	db.exec_param_many('BEGIN IMMEDIATE', []string{})!
	mut committed := false
	defer { if !committed { db.rollback() or {} } }
	db.save_page(request, page, complete)!
	db.commit()!
	committed = true
	return db.issue_page(request)!
}

fn store_issue_body(request DetailRequest, issue Issue) ! {
	if os.getenv('GHGUI_NO_CACHE') == '1' || cancelled(request.cancel) { return }
	mut db := open_issue_database()!
	defer { db.close() or {} }
	db.exec_param_many('BEGIN IMMEDIATE', []string{})!
	mut committed := false
	defer { if !committed { db.rollback() or {} } }
	db.save_issue(request.repo, issue, true)!
	db.commit()!
	committed = true
}

fn read_issue_body(request DetailRequest) ?Issue {
	if os.getenv('GHGUI_NO_CACHE') == '1' { return none }
	mut db := open_issue_database() or { return none }
	defer { db.close() or {} }
	key := '${storage_repository(request.repo, request.kind)}#${request.number}'
	rows := sql db { select from StoredIssue where key == key && body_loaded == true } or { return none }
	if rows.len == 0 { return none }
	value := json2.decode[json2.Any](rows[0].metadata) or { return none }
	issue := decode_issue(value) or { return none }
	return Issue{ ...issue, body: rows[0].body }
}

fn store_merged_pull_request(repo Repository, issue Issue) ! {
	store_closed_item(repo, issue)!
}

fn store_closed_item(repo Repository, issue Issue) ! {
	if os.getenv('GHGUI_NO_CACHE') == '1' { return }
	mut db := open_issue_database()!
	defer { db.close() or {} }
	db.exec_param_many('BEGIN IMMEDIATE', []string{})!
	mut committed := false
	defer { if !committed { db.rollback() or {} } }
	repository := storage_repository(repo, issue.kind)
	key := '${repository}#${issue.number}'
	previous := sql db { select from StoredIssue where key == key }!
	db.save_issue(repo, issue, true)!
	if previous.len > 0 && previous[0].state == 'OPEN' {
		stats := sql db { select from StoredRepository where key == repository }!
		if stats.len > 0 {
			record := StoredRepository{ ...stats[0], open_count: int_max(0, stats[0].open_count - 1), closed_count: stats[0].closed_count + 1 }
			sql db { upsert record into StoredRepository }!
		}
	}
	db.commit()!
	committed = true
}

fn import_legacy_cache(mut db IssueDatabase, repo Repository) ! {
	repository := repo.str().to_lower()
	stats := sql db { select from StoredRepository where key == repository }!
	if stats.len > 0 && stats[0].legacy_imported { return }
	db.exec_param_many('BEGIN IMMEDIATE', []string{})!
	mut committed := false
	defer { if !committed { db.rollback() or {} } }
	for state in ['OPEN', 'CLOSED'] {
		for sort in ['Oldest', 'Recently updated', 'Newest'] {
			path := os.join_path(legacy_cache_root(), repo.owner, repo.name, '${state}_${sort.replace(' ', '_')}.json')
			source := os.read_file(path) or { continue }
			cache := json2.decode[json2.Any](source) or { continue }
			if json_field(cache, 'version').int() != 1 { continue }
			mut loaded := IssuePage{}
			for raw in json_array(json_field(cache, 'pages')) {
				page := decode_page(json_text(raw)) or { continue }
				loaded = IssuePage{ ...page, issues: merge_issues(loaded.issues, page.issues) }
			}
			if loaded.issues.len == 0 { continue }
			// Oldest/updated cursors belong to a different server ordering.
			if sort == 'Newest' {
				db.save_page(FetchRequest{ repo: repo, state: state }, loaded, false)!
			} else {
				for issue in loaded.issues { db.save_issue(repo, issue, false)! }
				metadata := StoredRepository{
					key:          repository
					open_count:   loaded.open_count
					closed_count: loaded.closed_count
				}
				sql db { upsert metadata into StoredRepository }!
			}
		}
	}
	latest := sql db { select from StoredRepository where key == repository }!
	if latest.len > 0 {
		sql db { update StoredRepository set legacy_imported = true where key == repository }!
	} else {
		record := StoredRepository{ key: repository, legacy_imported: true }
		sql db { insert record into StoredRepository }!
	}
	db.commit()!
	committed = true
}
