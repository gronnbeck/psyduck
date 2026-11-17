# psyduck

Open-source (MIT) macOS app, Swift/SwiftUI: an alternative to Conductor.
Runs Claude Code in isolated git worktrees. Runs on the host (Xcode, codesign)
so this project's Claude session is a bare `claude`, not kekkai.

## Decisions
- **Distribution:** the np.lol distribution. Direct download, Developer ID +
  notarization, Sparkle auto-updates, published to the shared nplol dist bucket
  under `psyduck/edge/`. Not the Mac App Store. See `docs/DISTRIBUTION.md`.
- **CI runs on GitHub-hosted runners**, not the self-hosted Mac: the repo is
  public. Never add `pull_request` triggers to a workflow that loads secrets,
  and never point this repo at a self-hosted runner.
- **Min macOS:** 14.0. No App Sandbox (psyduck runs git and claude anywhere).
- **Bundle id:** `lol.np.psyduck` (edge: `lol.np.psyduck.edge`).
- **Architecture:** psyduck drives the `claude` CLI (`-p --output-format
  stream-json --include-partial-messages`, prompt on stdin, `--resume` per
  turn), never the API directly. All git is the git CLI via `Shell`.
- **Workspaces** are `git worktree`s at `~/psyduck/workspaces/<repo>/<name>`
  on branch `psyduck/<name>`, cut from `origin/<default branch>`, fetched
  first (`Git.defaultBaseRef`): always upstream's main or master, never the
  local copy or what is checked out. A repo with no `origin` uses its local
  main or master. **Rename** (row or "…" menu) changes the name and the
  branch together (`Workspace.branchName(for:)`: `psyduck/<name>`, or the name
  itself if it has a slash); the folder never moves, because claude finds its
  session by path. Refused while claude runs or a pull request is open. The diff panel compares against the commit recorded at creation.
- **Archive** (hover a sidebar row, or the context menu) is a soft delete:
  stops claude, saves uncommitted work as a commit under
  `refs/psyduck/archive/<id>` (branch untouched), removes the worktree and
  moves the record to `archive.json`, which isn't loaded at launch. Unarchive
  is not built yet.
- **Default permission mode** is `bypassPermissions` (Conductor-like);
  configurable in settings.
- **Primary action** (top-right of the window, head of the changes panel):
  one button, the next step for the branch, picked by `PrimaryAction.decide`
  in this order: pull (behind remote) → dirty: Create PR (commits, pushes and
  opens it) or Commit & push if a PR is open → push (unpushed) → Create PR →
  Ready for review (draft) → view PR. The panel's bottom bar adds Discard
  (confirmed) and Commit (no push) while there's uncommitted work. git and gh do the work
  directly, never the chat agent, so it works in any permission mode; claude
  (haiku, `--tools ""`) only writes the commit message and PR title/body. New
  actions go in that enum. Fetch + `gh pr view` run every ~32s, local status
  every 4s.
- **Settings** is a page inside the main window (⌘, and the gear), not a
  separate Settings window.
- **Design:** the Tinker design system, from the Claude Design canvas
  "Psyduck in Tinker" (https://claude.ai/artifact/0dae2f4b-8d85-49e5-a14e-36533dce43df,
  screens `Main.dc.html` and `Working.dc.html`, tokens in
  `project/ds/tinker/tokens.json`). The canvas is the spec. `Theme.swift` (`Tk`)
  holds every token; dark and light both follow the system appearance. Fonts:
  Inter (UI), Bricolage Grotesque (display), JetBrains Mono (code), all bundled.

- **Two apps in one window.** A rail on the left edge (`RootView`, `AppMode`)
  switches between **code** (workspaces, the original psyduck) and **desk**
  (pull requests and claude reviews, which was the separate tsukue app; it is
  called desk everywhere in psyduck). ⌘1 and ⌘2 switch. The two share the
  window, `Shell`, the fonts and the updater, and nothing else: each has its
  own stores, sidebar and settings page. Desk goes to GitHub and starts
  background reviews only once it has been opened in a session.
- **Desk's code lives in `PsyduckMac/Sources/Desk`**, with its own tokens
  (`Ink`, the same Tinker values as `Tk`), settings (`DeskSettings`, keys
  under `desk.`) and data (`desk/` inside psyduck's Application Support
  folder). `TsukueImport` copies tsukue's data and settings over once.
- **Desk's rules for GitHub:** claude never writes to GitHub; review agents
  get read-only tools (`ReviewStore.readTools`, `ReviewStore.readOnly`, never
  in the user-editable prompt template). Desk itself writes in exactly two
  places, both only on a button press: `PRStore.approve` (`gh pr review
  --approve`, after checking the head commit is the one shown; approve-all is
  the same call per PR) and `DraftStore.post` (one review POST with the draft
  the user edited). Don't add a third. `review-history.jsonl` is append only.
- **Desk's microcopy** is lowercase, no exclamation marks, "→" arrows, mono
  for numbers. The reviewer's name (`DeskSettings.agent`) is UI only.

## Code map (`PsyduckMac/Sources`)
- `RootView` — the mode rail and which app is showing.
- `AppStore` — repos, workspaces, persistence (`state.json` in Application
  Support, per bundle id), the chat runner, changed files.
- `Git` — worktrees, changed files, unified diff parsing.
- `ClaudeStream` — stream-json line → `ClaudeEvent`.
- `Shell` — runs CLIs with Homebrew and `~/.local/bin` on PATH (a
  Finder-launched app has neither).
- Views: `ShellView` (layout), `SidebarView`, `ChatView`, `ChangesPanel`,
  `DiffView`, `SettingsView`.

`PsyduckMac/Sources/Desk`:
- `PRStore`, `PullRequest` — the PR lists (`GhPullRequests`: one GraphQL
  query, or `ClaudePullRequests`), approving.
- `Review`, `ReviewAgents` — `ReviewStore` runs a team of read-only claude
  processes per review: first pass and specialists, one agent per focus, then
  a checker per file. `AgentLimiter` caps them. Results in `reviews.json`.
- `Draft`, `DraftView` — a finished review turned into a GitHub review the
  user edits and posts. `drafts.json`, `review-history.jsonl`.
- Views: `DeskView` (layout, sidebar, lists), `PRDetailView`,
  `DeskSettingsPane`, `DeskComponents`, `DeskProse`, `DeskTheme`.

## Commands
```sh
cd PsyduckMac && xcodegen generate && xcodebuild -scheme Psyduck -destination 'platform=macOS' test

# A real chat turn through claude (haiku, billed, ~10s)
TEST_RUNNER_PSYDUCK_LIVE_CLAUDE=1 xcodebuild test -scheme Psyduck -destination 'platform=macOS' \
  -only-testing:PsyduckTests/LiveClaudeTests

# Render the window to PNGs (no Screen Recording needed), from a state.json
TEST_RUNNER_PSYDUCK_RENDER_DIR=/tmp/screens TEST_RUNNER_PSYDUCK_RENDER_STATE=/path/state.json \
  xcodebuild test -scheme Psyduck -destination 'platform=macOS' -only-testing:PsyduckTests/ScreenRenderTests

# Render desk's screens with sample data
TEST_RUNNER_PSYDUCK_DESK_RENDER_DIR=/tmp/desk xcodebuild test -scheme Psyduck \
  -destination 'platform=macOS' -only-testing:PsyduckTests/DeskScreenRenderTests

# A real desk review through claude against a real PR (slow, billed)
TEST_RUNNER_PSYDUCK_DESK_LIVE_REVIEW='owner/repo#4' xcodebuild test -scheme Psyduck \
  -destination 'platform=macOS' -only-testing:PsyduckTests/LiveReviewTests
```

## Conventions
- Keep decisions (distribution, min macOS version, architecture) recorded in this file as they are made.
- Commit early, small commits, conventional-ish messages.
- `MARKETING_VERSION` in `project.yml` is the version people see; bump by hand.
  CI uses the run number as the build number.
