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
- **Engine and app are split.** Everything that isn't UI is `PsyduckCore`, the
  Swift package at the repo root (Foundation only, builds on macOS and Linux).
  `WorkspaceEngine` (an actor) owns repos, worktrees, claude turns and branch
  actions; the Mac app runs one in-process and `AppStore` only mirrors it for
  SwiftUI. The same engine is what a remote server will host (`docs/REMOTE.md`).
  Never put AppKit/SwiftUI in `Sources/PsyduckCore`.
- **The event log is the source of truth for a chat.** Each workspace has an
  append-only, sequence-numbered log (`events/<workspace id>.jsonl` beside
  `state.json`). Chat rows and session state are built from it by `Transcript`,
  in the engine and in every client, never stored on their own. Token deltas
  are live-only (not stored). Changed files and branch state are asked for,
  not logged.
- **Remote hosts.** The app talks to engines through `EngineClient`: its own
  `WorkspaceEngine`, and a `RemoteEngine` per host in settings. A host is a
  name and a shell command (`ssh … psyduck attach`) whose stdin and stdout
  carry the wire protocol (`Wire`: one JSON object per line) to `psyduck
  serve` on the other end. No port, no token: ssh and the socket's file mode
  are the auth. Anything the app does to a workspace goes through
  `AppStore.engine(for:)`, never straight to `engine`, or it silently acts on
  the wrong machine. An unreachable host keeps its last known workspaces; it
  is out of reach, not empty. The host command runs only when saved in
  settings, never while typed. Changing `Wire` in a way old clients can't
  read means bumping `Wire.version`; a new call is added to
  `Wire.capabilities` instead, so an app that updates itself still talks to
  a host that hasn't been rebuilt. See `docs/REMOTE.md`.
- **Copies of host workspaces** (`WorkspaceMirror`) are one way, host to Mac,
  over the same connection (no rsync). Off, the open session, or all, in
  settings; always available on demand. It writes only inside
  `~/psyduck/mirrors/<host>/<repo>/<workspace>`, refuses paths that would
  leave it (the host is not trusted with the Mac's disk), and removes only
  files an earlier copy put there.
- **The host image** (`docker/`) takes its logins from environment variables
  (`CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`) at run time. Never bake a secret
  into the image or take one as a build argument.
- **Workspaces** are `git worktree`s at `~/psyduck/workspaces/<repo>/<name>`
  on branch `psyduck/<name>`, cut from `origin/<default branch>`, fetched
  first (`Git.defaultBaseRef`): always upstream's main or master, never the
  local copy or what is checked out. A repo with no `origin` uses its local
  main or master. **Rename** (row or "…" menu) changes the name and the
  branch together (`Workspace.branchName(for:)`: `psyduck/<name>`, or the name
  itself if it has a slash); the folder never moves, because claude finds its
  session by path. Refused while claude runs or a pull request is open. The diff panel compares against where the branch and its base
  branch upstream last met (`Git.diffBase`), as a pull request does, so merging
  or rebasing the base in doesn't list other people's work as changes.
- **Archive** (hover a sidebar row, or the context menu) is a soft delete:
  stops claude, saves uncommitted work as a commit under
  `refs/psyduck/archive/<id>` (branch untouched), removes the worktree and
  moves the record to `archive.json`, which isn't loaded at launch. Its event
  log stays in `events/`. Unarchive is not built yet.
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
- **Diffs open as tabs** over the center pane, beside the session, one per
  file clicked in the changes panel. The session view stays alive underneath.
- **Long lists are lazy and rows are `Equatable`** (chat transcript, changed
  files): `AppStore` publishes on every bit of streamed text, and a view that
  rebuilds every row each time makes a long session lag. Streamed text is
  shown in ~60ms batches, and `changes`/`branches` are only assigned when
  they differ.
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

## Code map
`Sources/PsyduckCore` (the package; `swift test` at the repo root):
- `WorkspaceEngine` — repos, workspaces, the chat runner, branch actions.
- `WorkspaceEvent` / `EventLog` — the per-workspace event log and its JSON.
- `Transcript` — events → chat rows and session state.
- `EngineStorage` — `state.json` + logs on disk; migrates pre-log state files.
- `EngineConfig` — claude/git paths, roots, permission mode, model.
- `Git` — worktrees, changed files, unified diff parsing.
- `BranchActions` — `BranchState`, `PrimaryAction.decide`.
- `ClaudeStream` — stream-json line → `ClaudeEvent`; the turn's arguments.
- `Shell` — runs CLIs with Homebrew and `~/.local/bin` on PATH (a
  Finder-launched app has neither).
- `Remote/` — `EngineClient`, `Wire`, `RemoteServer` (host side),
  `RemoteEngine` (client side, reconnects), `LineConnection` (unix sockets
  and process pipes).

`Sources/psyduck` — the host executable: `serve`, `attach`, `status`.

`PsyduckMac/Sources` (the app):
- `RootView` — the mode rail and which app is showing.
- `AppStore` — mirrors the engine for SwiftUI, plus window state (selection,
  open diff tabs). State lives in Application Support, per bundle id.
- `AppSettings` — UserDefaults-backed settings; gives the engine its config.
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
# The engine: fast, no Xcode project, runs on Linux too
swift test

# The same on Linux
docker run --rm -v "$PWD":/w -w /w swift:6.2-noble swift test --scratch-path /tmp/b

# The host image, and a host on this machine
docker compose -f docker/compose.yml up -d --build

# The Mac app
cd PsyduckMac && xcodegen generate && xcodebuild -scheme Psyduck -destination 'platform=macOS' test

# Real chat turns through claude (haiku, billed, ~20s)
PSYDUCK_LIVE_CLAUDE=1 swift test --filter LiveClaudeTests

# Render the window to PNGs (no Screen Recording needed), from a state.json
TEST_RUNNER_PSYDUCK_RENDER_DIR=/tmp/screens TEST_RUNNER_PSYDUCK_RENDER_STATE=/path/state.json \
  xcodebuild test -scheme Psyduck -destination 'platform=macOS' -only-testing:PsyduckTests/ScreenRenderTests
# add TEST_RUNNER_PSYDUCK_RENDER_HOSTS=1 for a connected remote host and an unreachable one

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
