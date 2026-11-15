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
- **Workspaces** are `git worktree`s at `~/psyduck/workspaces/<repo>/<name>`
  on branch `psyduck/<name>`, cut from the remote's default branch (local copy
  preferred). The diff panel compares against the commit recorded at creation.
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

`PsyduckMac/Sources` (the app):
- `AppStore` — mirrors the engine for SwiftUI, plus window state (selection,
  open diff). State lives in Application Support, per bundle id.
- `AppSettings` — UserDefaults-backed settings; gives the engine its config.
- Views: `ShellView` (layout), `SidebarView`, `ChatView`, `ChangesPanel`,
  `DiffView`, `SettingsView`.

## Commands
```sh
# The engine: fast, no Xcode project, runs on Linux too
swift test

# The same on Linux
docker run --rm -v "$PWD":/w -w /w swift:6.2-noble swift test --scratch-path /tmp/b

# The Mac app
cd PsyduckMac && xcodegen generate && xcodebuild -scheme Psyduck -destination 'platform=macOS' test

# Real chat turns through claude (haiku, billed, ~20s)
PSYDUCK_LIVE_CLAUDE=1 swift test --filter LiveClaudeTests

# Render the window to PNGs (no Screen Recording needed), from a state.json
TEST_RUNNER_PSYDUCK_RENDER_DIR=/tmp/screens TEST_RUNNER_PSYDUCK_RENDER_STATE=/path/state.json \
  xcodebuild test -scheme Psyduck -destination 'platform=macOS' -only-testing:PsyduckTests/ScreenRenderTests
```

## Conventions
- Keep decisions (distribution, min macOS version, architecture) recorded in this file as they are made.
- Commit early, small commits, conventional-ish messages.
- `MARKETING_VERSION` in `project.yml` is the version people see; bump by hand.
  CI uses the run number as the build number.
