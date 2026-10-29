# ghgui

A desktop GitHub issue and pull request browser written in V with ui2. Data comes from the
authenticated GitHub CLI, including private repositories your account can read.

```sh
# Requires V 0.5.2+, ui2, and GitHub CLI.
v install https://github.com/vlang/ui2
gh auth login
make
./ghgui vlang/v
```

<img width="1552" height="1004" alt="image" src="https://github.com/user-attachments/assets/9f920cbf-29d8-41ad-933c-b151f184ae1a" />


If you already have a ui2 checkout, link it into `~/.vmodules/ui2` instead of
installing another copy.

`make` uses a local ui2 copy in `.build/vmodules` with a small macOS rich-text
patch that preserves inline styles and text selections during refresh.
The installed ui2 module stays untouched. Set `UI2_SOURCE=/path/to/ui2` when
building to use a checkout elsewhere.

After feature changes, run `make prod` to build the optimized `ghui` executable
with `v -prod -o ghui .` and the local ui2 module. Run it with `./ghui vlang/v`.

On macOS, `make app` builds the production executable and packages it as
`Github.app` in the repository root. Open it in Finder or run `open Github.app`.
It opens `vlang/v` by default; use `make app APP_REPO=owner/repo` to choose another
default repository. To pass a repository and options for a launch, use
`open Github.app --args owner/repo --prs`. The launcher includes Homebrew's
standard paths so it can find your authenticated `gh` installation from Finder.
`make clean` also removes the generated app bundle.

The bundle uses the generated **G** logo in `packaging/macos/AppIcon.png`.
`make app` converts it into a macOS icon with standard and Retina sizes and
includes it in the bundle; `make install` copies the icon to the installed app.

To update the copy in `~/Applications`, run `make install`, then quit and reopen
Github to load the new executable. Set `APP_INSTALL_DIR` to choose another
installation folder. `make install` preserves your existing link-routing setup.

To make links clicked in other Mac apps open in ghui, run `make install-links`.
This installs `Github.app` and a background `Github Links.app` into
`~/Applications`, remembers your current browser, and registers Github Links as
the HTTP/HTTPS handler. Approve the macOS default-browser confirmation if shown;
you can also select **Github Links** under **System Settings → Desktop & Dock →
Default web browser**. Repository, issue, PR, and PR **Files changed** URLs open
in ghui, including links to another repository while the app is running.
Other sites and unsupported GitHub pages (code, profiles, actions, and specific
comment or diff anchors) open at their original URL in your previous browser.
Use `make uninstall-links` to restore that browser. Re-running `make install-links`
updates the apps without replacing the saved browser. Set `APP_INSTALL_DIR` to
choose another installation folder. Links followed inside a browser stay there;
macOS routing applies to URLs opened by other apps. For an explicit launch, use
`open -a Github https://github.com/owner/repo/pull/42` or
`./ghui https://github.com/owner/repo/issues/42`.

The **Issues / PRs** switch is at the top left, followed by Refresh. Choose
**File → Open pull request…** in the menu bar, or use the `⌘G` / `Ctrl+G`
shortcut from any view to open a small **Open pull request**
dialog. Enter a PR number in the current repository and press Enter to open it
inside the app, including PRs outside the loaded list. Escape cancels the dialog.
Use the Open / Closed tabs to switch states, click a row to read its description and
comments inside the app, and
use the view buttons to change row density. Rows use smaller fonts and padding,
and identify issues as `#number`. Right-click a title in a list or detail view and
choose **Copy GitHub URL** to copy its link. For a PR, **Review on ChatGPT.com**
opens Firefox with `Review PR [github pr url]. Ignore CI, Leave comment.` prefilled
in ChatGPT; press Send in Firefox to submit it. The PR is marked **ChatGPT review**
in the list and detail view. Choosing the action again, or pressing `⌘⇧R` /
`Ctrl+Shift+R`, reopens its review chat once sent. The shortcut uses the open PR,
a single selected PR, or the last PR reviewed from the list. Review markers and
conversation URLs survive app restarts. Firefox must be installed, with history
enabled: ghui follows the original prompt's Firefox history visits to find the
chat, then saves its URL in the local database.
The filter text box above the list matches loaded PRs and issues by title,
`#number`, or author 100 ms after you stop typing. Filtering is local and makes no API
requests. Clear filters restores the loaded list. Author,
label, milestone, and assignee filters apply to the loaded pages; **Load more
issues** fetches the next 50. Counts always show the repository totals. The **Sort**
menu orders loaded PRs and issues by creation date (**Newest** / **Oldest**),
activity (**Recently updated** / **Least recently updated**), or comment count
(**Most commented** / **Least commented**). Recently updated puts the latest
activity first using GitHub's last-updated timestamp. The Closed PR list also
fetches the 50 most recently updated PRs, including older PRs merged recently.
Sorting is immediate and makes no API call; it preserves filters, selections,
and pagination. Load more to include older PRs or issues in the sort.
Refresh rechecks all loaded pages, removing PRs that have been merged or closed
from the Open list. It preserves filters and keeps saved rows visible if a request fails.

In the issue view, **Comments** jumps to the discussion, **Load more comments**
fetches the next 50 replies, and **Back to issues** restores your list filters
and scroll position. Refresh reloads the current issue and its comments.

Descriptions and comments show emoji reaction counts, including PR review summaries
and inline comments. Reactions from your account are highlighted; hover over a
reaction for its name, count, and the usernames of people who reacted. Tooltips
show up to ten usernames and summarize any remaining reactors. Refresh updates
the counts and usernames.
Press **Close issue** below an open issue's status to close it as completed
using your authenticated GitHub account. The button shows progress and any
GitHub error; after success, the status, Open / Closed lists, counts, and local
storage update automatically.
To reply, write under **Add a comment** at the end of an issue or PR discussion
and press **Comment**, or `⌘↩` / `Ctrl+Enter` in the text box. The comment is
posted with your authenticated GitHub account and appears in the discussion
immediately; Markdown is supported. If posting fails, GitHub's error is shown and
your text stays in the box. Unsent drafts are kept per issue while the app is open.
Clicking the selected **Issues** or **PRs** tab also returns from a detail view
to its list, preserving filters and scroll position.
PRs use the same filters, progressive loading, local sorting, and SQLite ORM
storage. Closed PRs include merged PRs; open, draft, closed, and merged states
have distinct indicators. Merged PRs show who merged them, the target branch,
and when they were merged. The PR view also shows source and target branches
and the number of changed files, additions, and deletions.
Open PRs with merge conflicts show a red **Conflicts** badge in the list and a
notice in the PR view. Squash merging is disabled until the conflicts are
resolved and you refresh the PR.
**Close PR** closes an open PR, including a draft, without merging it. The button
shows progress and any GitHub error; after success, the status, Open / Closed
lists, counts, and local storage update automatically.
For an open draft PR, **Ready for review** removes its draft status using your
authenticated GitHub account. The button shows progress and any GitHub error;
after success, the status and local storage update and squash merging becomes available.
**View diff** opens the full unified diff inside the app, with selectable code,
green additions, and red deletions. Refresh reloads the changes; **Back to PR** or
`Esc` returns to the discussion at the previous scroll position. Diffs are available
for open, draft, closed, and merged PRs.
Its Comments section shows conversation comments, review summaries, and inline review comments in date
order. Inline comments link to their file and line on GitHub, including outdated
comments. Reviews and their replies are paginated independently so long discussions
remain complete. **Squash merge** immediately merges an open,
non-draft PR into its target branch using your authenticated GitHub account.
It preserves GitHub's default commit description with all `Co-authored-by:` lines removed.
The button shows progress and any GitHub error, then updates the status and lists
after success. If the source branch changes after loading, refresh before merging.
Use `./ghgui vlang/v --prs` to start in PR mode.
Descriptions and comments use V's `x.markdown` module. The native macOS view
renders bold, italic, inline and fenced code, lists, quotes, links, task lists,
tables, inline images (including SVG badges), and inline HTML formatting such as
`<sub>` and `<sup>`. Images load in the background and keep their alt text as links
when unavailable. Text stays selectable and read-only. Other backends display
parsed text and image alt links with the same block layout;
inline styling requires ui2's native macOS rich-text controls.
References such as `#29407` and `owner/repo#123` are clickable in descriptions
and comments. References to the current repository open the issue or PR inside
the app, selecting the appropriate tab automatically. References to other
repositories also open inside ghui. Other links and links to specific comments
use your saved browser to preserve their destination.

Issues appear in batches: the first 15 are shown immediately, then the rest of
the 50-issue page loads in the background. Issue descriptions load independently
of comments; replies appear in batches of 10, then 20. Previously viewed issues
and tabs display immediately while refreshing. Issues, their metadata, fetched
descriptions, and pagination positions are stored in **SQLite using V's ORM**.
Repeat launches show the stored issues before GitHub responds. Existing JSON
caches are imported automatically. Refresh always requests fresh data, and
GitHub pagination uses a fixed newest-first order independently of the UI sort.
Local sorting covers all issues downloaded so far; load more to include older issues.

Network calls run in the background with a 30-second timeout. If an inherited
localhost HTTP/HTTPS proxy refuses a connection, ghui retries once with a direct
connection. Other proxy and GitHub errors are reported normally. Switching tabs
or leaving an issue cancels obsolete reads. A requested issue or PR closure, PR undrafting, squash merge, or comment
continues if you navigate away. Checkboxes select rows locally.

Shortcuts: `⌘R` / `Ctrl+R` / `F5` refresh, `⌘F` / `Ctrl+F` focus the filter,
`⌘↩` / `Ctrl+Enter` posts the comment being written, `Esc` returns to the issue list.

```sh
./ghgui vlang/v --check  # Verify gh access without opening a window
./ghgui vlang/v --prs --check  # Verify pull request fetching
make test
make test-native       # macOS: verify Markdown styles and selections across refreshes
GHGUI_LIVE_TESTS=1 make test  # Also verify live fetching, pagination and comments
make custom            # Optional ui2 custom renderer on macOS / Windows
```

The default build uses native controls on macOS and Windows. Linux uses ui2’s
custom renderer.

The database is `~/Library/Application Support/ghgui/issues.sqlite3` on macOS,
or `$XDG_DATA_HOME/ghgui/issues.sqlite3` on Linux (default `~/.local/share/ghgui`).
Set `GHGUI_DB_PATH` to choose a database file. `GHGUI_CACHE_DIR` remains supported
as a directory override. SQLite development libraries are needed to build on Linux;
macOS includes SQLite.

For fetch timings, run `GHGUI_PROFILE=1 ./ghgui vlang/v`. Set `GHGUI_NO_CACHE=1`
to temporarily disable persistent storage.

On macOS, save a native screenshot after loading and close the window with:

```sh
GHGUI_SCREENSHOT_PATH=/tmp/ghgui.png ./ghgui vlang/v
GHGUI_SCREENSHOT_ISSUE=29233 GHGUI_SCREENSHOT_PATH=/tmp/issue.png ./ghgui vlang/v
```
