# EC2 host bootstrapper (spec)

Status: proposed, nothing built yet. Depends on [REMOTE.md](REMOTE.md) for
what runs on the host.

Goal: from your Mac, one command gives you a Linux EC2 machine that is ready
to run psyduck sessions. It has `psyduckd` running, claude logged in, git and
gh set up, and an SSH entry the psyduck CLI and app can use. Further commands
stop, start, list and destroy it.

Assumes the Mac already has AWS access: the `aws` CLI with a profile that can
create the resources listed under [IAM](#iam-the-macs-profile).

## Without the Mac side: the bootstrap script

If you already have a machine (an EC2 instance you made by hand, or any
Ubuntu or Debian box), `scripts/bootstrap-host.sh` does the on-machine part
alone. Download it onto the machine and run it as the user psyduck will run
as:

```sh
curl -fsSLO https://raw.githubusercontent.com/gronnbeck/psyduck/main/scripts/bootstrap-host.sh
bash bootstrap-host.sh
```

It installs git, gh and claude, makes `~/psyduck/{repos,workspaces}`, turns on
linger, then runs the claude and GitHub logins and asks for a git identity.
It uses sudo for the system parts, takes no secrets as arguments, and can be
run again: it skips what is already there.

| Option | Does |
|---|---|
| `--no-login` | Install only. Use this when there is no terminal, for example as EC2 user data |
| `--login-only` | Only the logins |
| `--user NAME` | When run as root: the user to set up (default: whoever called sudo, else `ubuntu`) |

It creates nothing in AWS. It doesn't install `psyduckd`, which doesn't ship
yet ([REMOTE.md](REMOTE.md), phase 2).

## Commands

These are part of the `psyduck` CLI and run on the Mac. They shell out to
`aws` and `ssh`, the same way psyduck drives git and claude, and use no AWS SDK.

| Command | Does |
|---|---|
| `psyduck host create <name> [--region] [--type] [--disk]` | Provision, bootstrap, log in, and register the host |
| `psyduck host list` | Hosts tagged `psyduck:managed`, with their state |
| `psyduck host ssh <name>` | Open a shell on the host |
| `psyduck host stop <name>` / `start <name>` | Stop or start the instance. The disk, and so the workspaces, stay |
| `psyduck host destroy <name>` | Terminate the instance and delete its security group and ssh entry (confirmed) |
| `psyduck host login <name>` | Redo the claude/gh logins on the host |

Every step is idempotent and finds its resources by tag. If `create` fails
halfway, running it again continues from where it stopped. `--dry-run` prints
the `aws` commands without running them.

## Defaults

| | Default | Why |
|---|---|---|
| OS | Ubuntu 24.04 LTS | Well-trodden, and Swift's static Linux binaries run on it |
| Arch | arm64 (Graviton) | Cheaper per vCPU; `psyduckd` ships for aarch64 anyway |
| Type | `t4g.large` (2 vCPU, 8 GB) | Enough for claude plus a build; override with `--type` |
| Disk | 50 GB gp3, root | Worktrees and repo clones live here |
| Region | the profile's region | `--region` to override |
| Network | the default VPC, a public subnet | Outbound internet for claude, GitHub and apt |

The AMI comes from Canonical's public SSM parameter, not a hard-coded id:
`/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id`.

## Access: SSH over SSM Session Manager

**Recommended.** The instance has **no inbound security-group rules at all**.
SSH runs through Session Manager, so:

- No port is open to the internet.
- It doesn't break when your IP changes.
- It doesn't break when the public IP changes on stop/start.
- AWS access is checked by IAM, and SSH keys are checked on top.

What it needs:

- The Session Manager plugin on the Mac: `brew install --cask
  session-manager-plugin`. `create` checks for it.
- An instance profile `psyduck-host` with `AmazonSSMManagedInstanceCore`, and
  nothing else.

`create` writes one entry into `~/.ssh/config`, between `# psyduck` markers so
it can update and remove its own entries:

```
Host psyduck-<name>
  HostName i-0123456789abcdef0
  User ubuntu
  IdentityFile ~/.ssh/id_ed25519
  ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p --region <region> --profile <profile>
```

After that, `ssh psyduck-<name>` works, and so does the transport in
REMOTE.md (`ssh psyduck-<name> psyduck attach`).

Fallback: `--access ssh-ip` opens port 22 only to your current public IP.
`psyduck host allow-ip <name>` updates it when your IP changes. Use it where
Session Manager isn't allowed.

## What `create` does

1. **Preflight**
   - `aws sts get-caller-identity` succeeds.
   - The region is set.
   - The Session Manager plugin is installed.
   - An SSH key exists (`~/.ssh/id_ed25519.pub`, or `--key`).
2. **Shared setup**, once per account and region
   - Import the public key as the key pair `psyduck-<mac user>`.
   - Create the IAM role and instance profile `psyduck-host`.
3. **Security group** `psyduck-<name>`: no inbound rules, outbound open.
4. **Launch** with `run-instances`:
   - The AMI, type, disk, key pair, instance profile and security group above.
   - `HttpTokens=required` (IMDSv2) with hop limit 1, so containers on the
     box can't reach the instance metadata.
   - `InstanceInitiatedShutdownBehavior=stop`, so a shutdown on the box only
     stops the instance.
   - Tags: `Name=psyduck-<name>`, `psyduck:managed=true`, `psyduck:host=<name>`.
   - User data: the cloud-init script below. It contains **no secrets**,
     because user data can be read back with `describe-instance-attribute`.
5. **Wait**
   - `aws ec2 wait instance-running`.
   - Then the SSM agent shows as online.
   - Then `ssh … cloud-init status --wait` exits 0.
6. **Log in** over SSH, the same steps as `psyduck host login`; see below.
7. **Register**
   - Write the `~/.ssh/config` entry.
   - Add the host to the psyduck app's host list.
   - Print `ssh psyduck-<name>`.

### cloud-init (no secrets)

Runs as root on first boot:

1. **Packages:** `apt-get install git build-essential curl unzip jq`, plus
   `gh` from GitHub's apt repository.
2. **As `ubuntu`:**
   - Install claude with the native installer (`curl -fsSL
     https://claude.ai/install.sh | bash`), which puts it in `~/.local/bin`.
   - Download `psyduck` and `psyduckd` for aarch64 from
     `https://nplol-dist.hel1.your-objectstorage.com/psyduck/edge/linux/` and
     check them against the published checksum.
   - Run `psyduck install-service`, which writes the systemd user unit, then
     `loginctl enable-linger ubuntu`.
3. **Directories:** `~/psyduck/{repos,workspaces}` and
   `~/.config/psyduck/` (mode 700).

Until `psyduckd` ships (REMOTE.md phase 2), the bootstrapper skips the psyduck
download. The rest is useful on its own as a box to run `claude` on, so this
can be built alongside REMOTE.md.

### Logins (over SSH, interactive)

Credentials never go into user data, tags or the AMI. They're set up over
the SSH session:

- **claude:** `ssh -t psyduck-<name> claude setup-token` runs the login on
  the box. The long-lived token it prints goes into
  `~/.config/psyduck/env` (mode 600) as `CLAUDE_CODE_OAUTH_TOKEN`, which the
  systemd unit loads. Running it on the box means the token never passes
  through the Mac's shell history.
- **GitHub:**
  - `ssh -t psyduck-<name> gh auth login` uses the device flow, then
    `gh auth setup-git`, so git over HTTPS uses gh's credentials.
  - The bootstrapper does **not** copy the Mac's `gh auth token`. That token
    usually has broad scopes, and the box runs agents in
    `bypassPermissions`.
  - Using a fine-grained token limited to the repos you'll work on there is
    recommended, and `login` says so.
- **git identity:** copy `user.name` and `user.email` from the Mac's global
  git config.

## IAM

### The Mac's profile

It needs:

- `ec2:RunInstances`, `TerminateInstances`, `StartInstances`,
  `StopInstances`, `Describe*`, `CreateTags`
- `ec2:CreateSecurityGroup`, `DeleteSecurityGroup`,
  `AuthorizeSecurityGroupIngress` (only for `--access ssh-ip`)
- `ec2:ImportKeyPair`
- `iam:CreateRole`, `AttachRolePolicy`, `CreateInstanceProfile`,
  `AddRoleToInstanceProfile`, `PassRole` (on `psyduck-host` only)
- `ssm:StartSession` (on instances tagged `psyduck:managed=true`),
  `ssm:GetParameter` (the AMI parameter)

The docs will include a ready-made policy JSON scoped to those resources and tags.

### The instance role (`psyduck-host`)

`AmazonSSMManagedInstanceCore` only. The agents on the box get no other AWS
permissions, so an agent running in bypass mode can't touch the account.

## Cost

- **Instance:** a stopped instance costs only its EBS disk.
- **`psyduckd` idle stop (optional, off by default):** with `idleStopHours` set
  in the host's config, `psyduckd` runs `sudo shutdown -h now` after that long
  with no running turn and no attached client. The shutdown behavior makes that
  a stop, not a terminate.
- **`psyduck host start`:** brings the instance back, and the workspaces are
  where they were.

## Testing

- **Unit:** the `aws` and `ssh` argument builders, the ssh-config block
  editing, and the cloud-init rendering. These are pure functions, so no AWS
  is needed.
- **`--dry-run`:** prints every command, so the flow can be reviewed without
  creating anything.
- **Live, gated** by `PSYDUCK_LIVE_EC2=1`, billed: create a `t4g.small`, wait
  for cloud-init, check `claude --version` and `gh --version` over SSM SSH, then
  destroy it. Never run in CI.

## Open questions

- **Which AWS account and region?** A dedicated account (or at least region)
  for psyduck hosts keeps the blast radius small.
- **Tailscale?** If the Mac already has a tailnet, joining the host to it is an
  alternative to SSM. It needs an auth key on the box, so it's not the default.
- **Docker on the host?** Some repos need it for their tests. Add an
  `--with docker` flag, or always install it?
- **Prebuilt AMI?** cloud-init takes a few minutes per host. An AMI baked with
  the toolchain would make `create` faster, at the cost of keeping it updated.
