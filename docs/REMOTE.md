# Remote workspaces (plan)

Status: proposed, nothing built yet.

Goal: run psyduck agents on a remote machine and check on them from
anywhere. You can start a workspace with a prompt, close the laptop, and come
back to the live state: whether claude is still running, what it said, what
changed and where the branch stands.

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

Each workspace's history is a numbered list of events:

- turn started, text, tool use, tool result, turn finished
- queued prompt
- branch state changed (ahead/behind, dirty, PR)

Chat items and workspace state are built from those events rather than stored
on their own. A client that disconnects asks for `since=N` and catches up. The
agent keeps running whether or not anything is connected. The local app uses
the same log, so local and remote workspaces behave the same way.

## API

| Call | Does |
|---|---|
| `GET /workspaces` | Summaries: running, branch, ahead/behind, dirty count, PR |
| `POST /workspaces {repo, baseRef?}` | Create a worktree |
| `GET /workspaces/:id` | Full state: changed files, branch, PR, current turn, cost |
| `GET /workspaces/:id/diff?path=` | One file's diff |
| `POST /workspaces/:id/turns {prompt}` | Start a turn, or queue it if one is running |
| `GET /workspaces/:id/events?since=N` | Replay from N, then stay open for live events |
| `POST /workspaces/:id/stop` | Stop the running turn |
| `POST /workspaces/:id/action` | Run the primary action (`PrimaryAction.decide`) |
| `POST /runs {repo, prompt, then: [...]}` | One-shot workflow: new workspace, then the prompt, then actions (e.g. `createPR`); returns the workspace id |

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

## What the remote machine needs

- `claude` installed and logged in (`claude setup-token`, or an API key)
- git credentials for the repos' remotes
- `gh auth login` for the PR actions

`bypassPermissions` is easier to justify on a disposable remote box than on
your own Mac.

## Phases

1. **`PsyduckCore` + event log.** Extract the engine. The Mac app behaves the
   same on top of it, and the existing tests pin that behaviour.
2. **`psyduckd` + `psyduck` CLI.** CI builds and tests on Linux too. Try them
   against a real box over SSH.
3. **Remote hosts in the app.** Add a host in settings, and its workspaces
   show in the sidebar under it.
4. *(Maybe)* HTTP + auth, and an MCP server for clients that have no shell.

## Open questions

- **Which remote machine?** A Linux VPS (e.g. Hetzner), a Mac mini, or
  either? This decides whether phase 1 must build on Linux from the start.
- **What's a "workflow"?** The one-shot `prompt → actions` run above, or
  multi-step recipes (prompt, run tests, prompt again, open PR) defined in a
  file in the repo?
- **Shared or per-user workspaces?** Does a remote host serve one person, or
  several people (e.g. Ken and Håvard) on the same box?
