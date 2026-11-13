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
  on branch `psyduck/<name>`, cut from the remote's default branch (local copy
  preferred). The diff panel compares against the commit recorded at creation.
- **Default permission mode** is `bypassPermissions` (Conductor-like);
  configurable in settings.
- Design: the np.lol design system (`Theme.swift`, bundled fonts), amber accent.

## Code map (`PsyduckMac/Sources`)
- `AppStore` — repos, workspaces, persistence (`state.json` in Application
  Support, per bundle id), the chat runner, changed files.
- `Git` — worktrees, changed files, unified diff parsing.
- `ClaudeStream` — stream-json line → `ClaudeEvent`.
- `Shell` — runs CLIs with Homebrew and `~/.local/bin` on PATH (a
  Finder-launched app has neither).
- Views: `ShellView` (layout), `SidebarView`, `ChatView`, `ChangesPanel`,
  `DiffView`, `SettingsView`.

## Commands
```sh
cd PsyduckMac && xcodegen generate && xcodebuild -scheme Psyduck -destination 'platform=macOS' test

# A real chat turn through claude (haiku, billed, ~10s)
TEST_RUNNER_PSYDUCK_LIVE_CLAUDE=1 xcodebuild test -scheme Psyduck -destination 'platform=macOS' \
  -only-testing:PsyduckTests/LiveClaudeTests

# Render the window to PNGs (no Screen Recording needed), from a state.json
TEST_RUNNER_PSYDUCK_RENDER_DIR=/tmp/screens TEST_RUNNER_PSYDUCK_RENDER_STATE=/path/state.json \
  xcodebuild test -scheme Psyduck -destination 'platform=macOS' -only-testing:PsyduckTests/ScreenRenderTests
```

## Conventions
- Keep decisions (distribution, min macOS version, architecture) recorded in this file as they are made.
- Commit early, small commits, conventional-ish messages.
- `MARKETING_VERSION` in `project.yml` is the version people see; bump by hand.
  CI uses the run number as the build number.
