# psyduck

An open-source macOS app for running Claude Code in isolated git worktrees,
an alternative to Conductor. The name is a pun on "conductor": a duck that
conducts, and has a headache.

**Download (edge, signed and notarized):**
<https://nplol-dist.hel1.your-objectstorage.com/psyduck/edge/psyduck-edge-latest.zip>

Installed copies update themselves through Sparkle.

## What it does (round 1)

- **Repos:** add a local git repo, or clone one from a URL.
- **Workspaces:** each new workspace is a fresh `git worktree` on its own
  `psyduck/<duck-name>` branch, cut from the repo's default branch. Your own
  checkout is never touched.
- **Chat:** one claude session per workspace, running inside the worktree.
  Replies stream in, tool calls show as rows, and each turn resumes the same
  claude session (`--resume`).
- **Changes panel:** the right-hand panel lists every file the workspace has
  changed since its base commit (committed, uncommitted and untracked). Click
  one to read its diff.
- **Settings:** the claude path (auto-detected, overridable), permission
  mode, model, git path and where worktrees go.
- Archiving a workspace removes its worktree and keeps the branch.

You need [Claude Code](https://docs.claude.com/en/docs/claude-code) installed
and signed in. psyduck runs your `claude` binary; it doesn't call the API
itself.

> **Permissions:** the default mode is `bypassPermissions`, which lets claude
> run any tool without asking, the same as Conductor's default. The worktree
> keeps claude's edits off your checkout, but it is not a sandbox. Pick
> "accept edits" or "plan" in settings if you want less.

## Build it yourself

Needs Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd PsyduckMac
xcodegen generate
open Psyduck.xcodeproj          # or:
xcodebuild -scheme Psyduck -destination 'platform=macOS' test
```

Local builds are ad-hoc signed and have no update feed, so Sparkle stays off.

## Layout

| Path | What |
|---|---|
| `PsyduckMac/` | The SwiftUI app; `project.yml` is the XcodeGen spec (the `.xcodeproj` isn't committed) |
| `PsyduckMac/Icon/make-icon.swift` | The icon generator. It *is* the artwork |
| `.github/workflows/macos.yml` | Build and test on every PR and push |
| `.github/workflows/macos-release.yml` | Signed, notarized edge build, plus the Sparkle appcast |
| `docs/DISTRIBUTION.md` | How releases work, and what secrets they need |

## License

MIT. See `LICENSE`. The bundled fonts (Bricolage Grotesque, JetBrains Mono,
Boldonse) are under the SIL Open Font License; see `PsyduckMac/Fonts/`.

Not affiliated with Conductor, Anthropic, or Pokémon.
