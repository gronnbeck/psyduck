# Remote workspaces (plan)

Status: phase 1 is built (`PsyduckCore`, the engine and the event log, on
macOS and Linux). Phases 2 and 3 are not.

Hosts on EC2 are set up by the bootstrapper in [EC2.md](EC2.md).

Goal: run psyduck agents on a remote machine and check on them from
anywhere. You can start a workspace with a prompt, close the laptop, and come
back to the live state: whether claude is still running, what it said, what
changed and where the branch stands.

A remote workflow is a normal psyduck session, running somewhere else: a
workspace (worktree + branch) with its chat with claude. You can send
follow-ups, stop it, see its changes and run the primary action, the same as
locally. There are no recipes or pipelines on top.

## Shape

```
PsyduckCore (SwiftPM, macOS + Linux)
  Git, Shell, ClaudeStream, BranchActions, Models   ← already Foundation-only
  WorkspaceEngine   ← the runner and state pulled out of AppStore
  EventLog          ← per-workspace, append-only, sequence-numbered JSONL

psyduckd     the server on the remote machine: WorkspaceEngine + API on a unix socket
psyduck      the CLI client: run / status / events / attach / list
Psyduck.app  the local engine, or connects to remote hosts (one sidebar section per host)
```

Only `AppStore` mixes engine logic with SwiftUI and AppKit, so splitting it is
most of the refactor.

### Event log

Each workspace's history is a numbered list of events, one JSON object per
line in `events/<workspace id>.jsonl`:

```json
{"seq":1,"at":"2026-11-15T10:00:00Z","type":"prompt","text":"add a duck"}
{"seq":2,"at":"2026-11-15T10:00:01Z","type":"session","sessionID":"…"}
{"seq":3,"at":"2026-11-15T10:00:04Z","type":"tool_use","id":"t1","name":"Bash","summary":"ls"}
```

| `type` | Means |
|---|---|
| `prompt` | The user's message; a turn starts |
| `queued` | A follow-up sent while claude was busy (the whole waiting text) |
| `session` | claude's session id for the turn |
| `text` | A finished block of claude's reply |
| `tool_use` / `tool_result` | A tool call and what it returned |
| `result` | claude's end-of-turn line: duration, cost, error |
| `turn_ended` | The claude process is gone; `cancelled` if it was stopped |
| `note` | A line psyduck adds: "committed abc123", or a failure |
| `delta` / `partial` | Live only, never stored: reply tokens as they arrive, and the reply so far for a client joining mid-reply |

Chat rows and session state (running, queued, cost) are built from those
events by `Transcript`, rather than stored on their own. A client that
disconnects asks for `since=N` and catches up. The agent keeps running whether
or not anything is connected. The local app uses the same engine and log, so
local and remote workspaces behave the same way.

Changed files and branch state (ahead/behind, dirty, PR) are not in the log.
A client asks for them, as the app does every few seconds.

## API

| Call | Does |
|---|---|
| `GET /workspaces` | Summaries: running, branch, ahead/behind, dirty count, PR |
| `POST /workspaces {repo, baseRef?, prompt?}` | Create a workspace. With `prompt`, its first turn starts right away |
| `GET /workspaces/:id` | Full state: changed files, branch, PR, current turn, cost |
| `GET /workspaces/:id/diff?path=` | One file's diff |
| `POST /workspaces/:id/turns {prompt}` | Start a turn, or queue it if one is running |
| `GET /workspaces/:id/events?since=N` | Replay from N, then stay open for live events |
| `POST /workspaces/:id/stop` | Stop the running turn |
| `POST /workspaces/:id/action` | Run the primary action (`PrimaryAction.decide`) |

The CLI mirrors these calls, and `--json` gives machine-readable output.

## Transport and auth

SSH, with no open port.

- `psyduckd` listens on `~/.psyduck/psyduckd.sock` on the remote machine.
- A client reaches it with `ssh <host> psyduck attach`, which connects
  stdio to the socket using JSON-RPC, or with SSH's unix-socket forwarding.
- SSH keys are the auth, and it works over Tailscale.
- HTTP with a bearer token can wait until a non-SSH client needs it.

## Claude as a client

Claude Code drives remote agents through the CLI (`psyduck run --json …`,
`psyduck status <id> --json`), documented in a skill or CLAUDE.md. That needs no
MCP server. An MCP server only matters for a Claude without a shell (claude.ai,
desktop, phone). It would mean exposing psyduckd over HTTP with real auth, so
it's out of scope until someone wants that.

## Linux

The remote machine is Linux, so `PsyduckCore`, `psyduckd` and `psyduck`
must build on Linux from phase 1.

- **Portability is mostly there.** The core files use only Foundation, and
  `Process`, `FileHandle` and `NSLock` all exist in swift-corelibs-foundation.
- **What has to change:**
  - `AppSettings` keeps settings in `UserDefaults`. On the server they move to
    a config file, `~/.config/psyduck/config.json`.
  - App state moves from Application Support to `~/.local/share/psyduck/`:
    `state.json` and the event logs.
  - `Shell` adds Homebrew paths to `PATH` and searches them for tools. Keep
    `~/.local/bin` (the native claude installer puts it there) and
    `/usr/local/bin`. The Homebrew paths are harmless on Linux.
- **Build:** use the Swift static Linux SDK (`swift build --swift-sdk
  x86_64-swift-linux-musl`, plus aarch64) to produce one static binary
  per architecture, with no Swift runtime to install.
- **Run:** a systemd user unit, `psyduckd.service`, with
  `loginctl enable-linger` so it keeps running after you log out. `psyduck
  install-service` writes the unit.
- **CI:** a Linux job on `ubuntu-latest` builds and tests `PsyduckCore`,
  including the worktree and primary-action tests (they only need git).
- **Release:** the same edge pipeline uploads the binaries to the bucket under
  `psyduck/edge/linux/`. There's no signing or notarization on Linux.
  `curl … | tar x` installs it.

## What the remote machine needs

- `claude` installed and logged in (`claude setup-token`, or an API key)
- git credentials for the repos' remotes
- `gh auth login` for the PR actions

`bypassPermissions` is easier to justify on a disposable remote box than on
your own Mac.

## Phases

1. **`PsyduckCore` + event log.** Extract the engine as a SwiftPM package that
   builds on macOS and Linux, and add a Linux CI job. The Mac app behaves the
   same on top of it, and the existing tests pin that behaviour.
2. **`psyduckd` + `psyduck` CLI.** Ship static Linux binaries and a systemd
   user unit. Try them against a real Linux box over SSH.
3. **Remote hosts in the app.** Add a host in settings, and its workspaces
   show in the sidebar under it.
4. *(Maybe)* HTTP + auth, and an MCP server for clients that have no shell.

## Open questions

- ~~Which remote machine?~~ Linux. See [Linux](#linux).
- ~~What's a "workflow"?~~ A normal psyduck session (workspace + chat). See
  the top.
- ~~Shared or per-user workspaces?~~ Per user for now. Each user runs their
  own `psyduckd` under their own Linux account, with their own claude login,
  git and gh credentials, and workspaces. There are no accounts or
  permissions inside psyduck, because the Unix user and SSH key are the
  boundary. Several people can share a machine by each having an account
  on it.
