# Remote workspaces

Status: phases 1 to 3 are built, in a first form you can experiment with.
`psyduck serve` runs the engine on a host, the Mac app lists hosts in
settings and shows their workspaces in the sidebar, and `docker/` has a
container image for a host. Not built: static binaries and a release for
them, a systemd unit, and the human-facing CLI (`run`, `events`).

## Try it: a host in a container

On the machine that will run the agents (a Mac with Docker works):

```sh
git clone https://github.com/gronnbeck/psyduck && cd psyduck
cp docker/.env.example docker/.env     # fill in the tokens, see below
docker compose -f docker/compose.yml up -d --build
docker logs psyduck                    # "psyduck serving at …", and the claude it found
```

`docker/.env` holds the logins, which reach the container as environment
variables and are never in the image:

| Variable | What |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | From `claude setup-token`, run anywhere with a browser |
| `GH_TOKEN` | A GitHub token that can read and push your repos and open PRs (`gh auth token` prints your own) |
| `GIT_USER_NAME`, `GIT_USER_EMAIL` | Who the agent's commits are from |

Then in the Mac app: Settings → Remote hosts → Add a host. Give it a name
and the command that reaches the server:

```
ssh studio docker exec -i psyduck psyduck attach
```

The app runs that command and talks to it over stdin and stdout, so ssh keys
are the whole of the auth and no port is opened. Check the command in a
terminal first: it should sit there silently, and print one line of JSON if
you type `{"id":1,"method":"hello"}`. Two things that commonly go wrong:

- ssh finds no `docker`, because a non-interactive ssh session has a short
  `PATH`. Use the full path (`/usr/local/bin/docker`, or
  `/opt/homebrew/bin/docker`).
- ssh asks for a password or a host key. The app can't answer; set up a key
  and connect once by hand.

The host appears in the sidebar under its name. Clone a repo onto it with the
arrow beside the name (the host clones it with its own git login), then make
workspaces as usual. Close the laptop and the agent keeps going; the app
catches up when it reconnects.

Everything the host must keep is in the `psyduck-data` volume (`/data` in the
container): state and event logs, the repos and worktrees, claude's own
sessions, and `config.json` (model, permission mode). The image has git, gh
and claude and nothing else, so a project that needs a toolchain needs an
image built on top of it.

Without Docker, the same thing by hand: `swift build -c release --product
psyduck`, run `psyduck serve` under the account that has the logins, and use
`ssh <host> psyduck attach` as the command.

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

psyduck      on the host, one binary:
               serve    WorkspaceEngine behind a unix socket (~/.psyduck/psyduck.sock)
               attach   joins stdin and stdout to that socket; what ssh runs
               status   lists the host's repos and workspaces
Psyduck.app  its own engine, plus one RemoteEngine per host (one sidebar section each)
```

`EngineClient` is what the app asks of any engine. `WorkspaceEngine` answers
in-process; `RemoteEngine` sends the same calls over a connection to
`RemoteServer`, which hands them to the host's `WorkspaceEngine`. The plan
had a separate `psyduckd`; it is `psyduck serve` instead, so a host has one
binary.

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

## Wire protocol

One JSON object per line, both ways (`Wire` in `PsyduckCore`):

```
→ {"id":1,"method":"snapshot"}
← {"id":1,"result":{"repos":[…],"workspaces":[…]}}
→ {"id":2,"method":"events","params":{"workspace":"…","since":12,"sub":7}}
← {"id":2,"result":{}}
← {"sub":7,"event":{"seq":13,"type":"text",…}}     as they happen
← {"id":3,"error":"that workspace doesn't exist"}
```

| Method | Does |
|---|---|
| `hello` | The protocol version and the machine's name. A client and server with different versions refuse each other |
| `snapshot` | Repos and workspaces |
| `addRepo {path}`, `cloneRepo {url}`, `removeRepo {repo}` | Repos on the host |
| `newWorkspace {repo, text?}` | Create a workspace. With `text`, its first turn starts right away |
| `rename {workspace, name}`, `archive {workspace}` | As in the app |
| `send {workspace, text}` | Start a turn, or queue it if one is running |
| `stop {workspace}` | Stop the running turn |
| `events {workspace, since, sub}` | Replay after `since`, then live events, tagged with the client's `sub`. `unsubscribe {sub}` ends it |
| `changedFiles`, `diff {file}`, `branchState {network}` | What the changes panel asks for |
| `perform {action}`, `discard` | The primary action, and discard |

## Transport and auth

SSH, with no open port.

- `psyduck serve` listens on `~/.psyduck/psyduck.sock` on the remote machine,
  readable only by its own user.
- A client reaches it with `ssh <host> psyduck attach`, which connects
  stdio to the socket. The app runs whatever command the host is given, so
  `docker exec` or a jump host fit in the same line.
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
2. **`psyduck serve` + `attach`.** Built, with a container image. Still to
   do: static Linux binaries in the edge release, a systemd user unit, and
   the commands for people and for Claude as a client (`run`, `events`).
3. **Remote hosts in the app.** Built: add a host in settings, and its
   workspaces show in the sidebar under it. Still to do: the app's model and
   permission settings don't reach a host (it reads its own `config.json`),
   and there is no notification when a remote turn finishes.
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
