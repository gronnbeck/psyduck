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
  `psyduck/<duck-name>` branch, cut from the default branch as it is upstream
  (`origin/main` or `origin/master`, fetched first). Your own checkout is
  never touched.
- **Chat:** one claude session per workspace, running inside the worktree.
  Replies stream in, tool calls show as rows, and each turn resumes the same
  claude session (`--resume`).
- **Changes panel:** the right-hand panel lists every file the workspace has
  changed since its base branch (committed, uncommitted and untracked). Click
  one to open its diff in a tab beside the session; Esc or the × closes it.
- **Settings:** the claude path (auto-detected, overridable), permission
  mode, model, git path and where worktrees go.
- **Rename:** right-click a workspace to rename it. Its branch is renamed
  with it (`psyduck/<name>`, or the name as typed if it has a slash, like
  `fix/login`).
- Archiving a workspace removes its worktree and keeps the branch.

## Remote hosts

Agents can run on another machine and keep going when your Mac is asleep.
The other machine runs `psyduck serve` (there is a container image in
`docker/`); in the app, Settings → Remote hosts takes a name and the command
that reaches it, usually `ssh <host> docker exec -i psyduck psyduck attach`.
The host's workspaces show in the sidebar under its name. It is new and
experimental: see [docs/REMOTE.md](docs/REMOTE.md).

## Desk

The second icon in the left rail (⌘2; ⌘1 goes back to code) is **desk**: your
open pull requests across GitHub, and claude reviews of them. It used to be a
separate app, tsukue.

- **Pull requests:** the ones waiting for your review and the ones you
  opened, with checks and review state, through your `gh` login.
- **Reviews:** a team of claude agents reads a PR and reports what it found.
  They can only read. Review requests are reviewed in the background as they
  arrive (you can turn that off in desk's settings).
- **Posting:** turn a review into a draft, edit it by hand or by chat, and
  post it to GitHub. Or approve, one PR or several. Nothing is written to
  GitHub until you press the button.
- Desk does nothing until you open it. If you used tsukue, its reviews,
  drafts and settings are copied over the first time psyduck starts.

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

The engine is a plain Swift package and tests without Xcode, on macOS or
Linux:

```sh
swift test
```

Local builds are ad-hoc signed and have no update feed, so Sparkle stays off.

## Layout

| Path | What |
|---|---|
| `Sources/PsyduckCore/` | The engine: repos, worktrees, claude turns, event logs, branch actions. A Swift package, macOS and Linux |
| `PsyduckMac/` | The SwiftUI app; `project.yml` is the XcodeGen spec (the `.xcodeproj` isn't committed) |
| `PsyduckMac/Icon/make-icon.swift` | The icon generator. It *is* the artwork |
| `.github/workflows/macos.yml` | Build and test on every PR and push |
| `.github/workflows/macos-release.yml` | Signed, notarized edge build, plus the Sparkle appcast |
| `docs/DISTRIBUTION.md` | How releases work, and what secrets they need |
| `Sources/psyduck/` | The host side: `psyduck serve`, `attach`, `status` |
| `docker/` | A container image for a host, and its compose file |
| `docs/REMOTE.md` | Running agents on a remote machine: how to try it, the protocol, what's left |
| `docs/EC2.md` | Spec: bootstrap a Linux EC2 host for psyduck from your Mac |

## License

MIT. See `LICENSE`. The bundled fonts (Inter, Bricolage Grotesque, JetBrains Mono)
are under the SIL Open Font License; see `PsyduckMac/Fonts/`.

Not affiliated with Conductor, Anthropic, or Pokémon.
