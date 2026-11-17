#!/usr/bin/env bash
# Sets up a Linux machine (Ubuntu or Debian) to run psyduck sessions:
# git, gh, claude, the directories psyduck uses, and a guided setup of the
# claude login, the GitHub login and your git identity. Safe to run again; it
# skips what is already there, and ends by listing what is set up and what
# isn't.
#
# Settings for psyduck on this machine live in ~/.config/psyduck/.env
# (KEY=VALUE lines, mode 600). The claude token is saved there; add anything
# else your sessions need.
#
#   curl -fsSLO https://raw.githubusercontent.com/gronnbeck/psyduck/main/scripts/bootstrap-host.sh
#   bash bootstrap-host.sh
#
# Run it as the user psyduck will run as (it uses sudo for the system parts),
# or as root with --user. It holds no secrets and asks for none on the command
# line: the logins are typed on this machine.
# shellcheck disable=SC2016  # the single-quoted scripts are expanded by the shell they run in
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bootstrap-host.sh [options]

  --user NAME    The user psyduck runs as. Default: you, or when run as
                 root, whoever called sudo, else "ubuntu".
  --no-login     Install only. Skip the claude and GitHub logins.
  --login-only   Only the logins. Skip the install.
  --status       Only show what is set up and what is missing.

Logins and other settings are kept in ~/.config/psyduck/.env.
  -h, --help     Show this.
EOF
}

target_user=""
do_install=1
do_login=1
env_file_name=".config/psyduck/.env"

while [ $# -gt 0 ]; do
    case "$1" in
        --user) [ $# -ge 2 ] || { echo "--user needs a name" >&2; exit 2; }; target_user="$2"; shift 2 ;;
        --user=*) target_user="${1#--user=}"; shift ;;
        --no-login) do_login=0; shift ;;
        --login-only) do_install=0; shift ;;
        --status) do_install=0; do_login=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
    target_user="${target_user:-${SUDO_USER:-ubuntu}}"
    [ "$target_user" != root ] || die "psyduck shouldn't run as root. Pass --user NAME."
else
    target_user="${target_user:-$(id -un)}"
    [ "$target_user" = "$(id -un)" ] || die "Run as root (or with sudo) to set up another user."
fi
id "$target_user" >/dev/null 2>&1 || die "No user named $target_user on this machine."
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
[ -n "$target_home" ] || die "Can't find the home directory of $target_user."

# Runs a command as root.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# Runs a bash script (first argument) as the psyduck user, from their home,
# with ~/.local/bin on PATH. Further arguments reach the script as $1, $2...
as_user() {
    local script="$1"; shift
    local path="$target_home/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    if [ "$(id -u)" -eq 0 ]; then
        runuser -u "$target_user" -- env HOME="$target_home" PATH="$path" \
            bash -c 'cd "$HOME" && exec bash -c "$@"' bash "$script" bash "$@"
    else
        env PATH="$path" bash -c 'cd "$HOME" && exec bash -c "$@"' bash "$script" bash "$@"
    fi
}

install_packages() {
    step "Packages"
    command -v apt-get >/dev/null || die "This script needs apt-get (Ubuntu or Debian)."
    export DEBIAN_FRONTEND=noninteractive
    as_root apt-get update
    as_root apt-get install -y git build-essential curl unzip jq ca-certificates

    if command -v gh >/dev/null; then
        echo "gh is already installed."
        return
    fi
    # gh comes from GitHub's own apt repository.
    local keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
    as_root install -d -m 755 /etc/apt/keyrings
    as_root curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$keyring"
    as_root chmod go+r "$keyring"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" \
        | as_root tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    as_root apt-get update
    as_root apt-get install -y gh
}

install_directories() {
    step "Directories"
    as_user 'mkdir -p "$HOME/psyduck/repos" "$HOME/psyduck/workspaces" "$HOME/.local/bin"
             install -d -m 700 "$HOME/.config/psyduck"
             file="$HOME/$1"
             [ -e "$file" ] && exit 0
             umask 177
             printf "%s\n" \
                 "# Settings for psyduck on this machine, one KEY=VALUE per line." \
                 "# psyduck passes them to claude, git and gh. Keep this file private." > "$file"' "$env_file_name"
    echo "$target_home/psyduck"
    echo "$target_home/$env_file_name"
}

install_claude() {
    step "claude"
    if as_user 'command -v claude >/dev/null'; then
        echo "claude is already installed."
    else
        # The native installer; it lands in ~/.local/bin.
        as_user 'curl -fsSL https://claude.ai/install.sh | bash'
    fi
    # Login shells get ~/.local/bin from Ubuntu's ~/.profile once it exists.
    # Other shells need it spelled out.
    as_user 'grep -qs "\.local/bin" "$HOME/.bashrc" ||
             printf "\nexport PATH=\"\$HOME/.local/bin:\$PATH\"\n" >> "$HOME/.bashrc"'
}

enable_linger() {
    step "Keep the user's services running after logout"
    if command -v loginctl >/dev/null && as_root loginctl enable-linger "$target_user" 2>/dev/null; then
        echo "Linger is on for $target_user."
    else
        warn "couldn't turn on linger (no systemd here?). Sessions may stop when you log out."
    fi
}

login_claude() {
    step "claude login (1 of 3)"
    if grep -qs '^CLAUDE_CODE_OAUTH_TOKEN=.' "$target_home/$env_file_name"; then
        echo "A claude token is already in ~/$env_file_name. Remove that line to log in again."
        return
    fi
    cat <<'EOF'
This gives claude on this machine a long-lived token for your account:
  1. claude prints a URL. Open it in a browser on any computer and sign in.
  2. Paste the code from the browser back here.
  3. claude prints a token starting with sk-ant-oat. Paste it at the prompt
     that follows, and it is saved for psyduck.
EOF
    as_user '
        claude setup-token
        echo
        read -rsp "Paste the token printed above (Enter skips): " token
        echo
        [ -n "$token" ] || { echo "No token given, nothing saved."; exit 0; }
        file="$HOME/$1"
        install -d -m 700 "$(dirname "$file")"
        umask 177
        touch "$file"
        # Replace an older token, keep every other line.
        tmp="$(mktemp "$file.XXXXXX")"
        grep -v "^CLAUDE_CODE_OAUTH_TOKEN=" "$file" > "$tmp" || true
        printf "CLAUDE_CODE_OAUTH_TOKEN=%s\n" "$token" >> "$tmp"
        mv "$tmp" "$file"
        echo "Saved to ~/$1 (only you can read it)."' "$env_file_name"
}

login_github() {
    step "GitHub login (2 of 3)"
    if as_user 'gh auth status --hostname github.com >/dev/null 2>&1'; then
        echo "gh is already logged in."
    else
        cat <<'EOF'
Agents on this machine run without asking permission, and can use whatever
this login can reach. A fine-grained token limited to the repos you'll work
on here is the safer choice:
https://github.com/settings/personal-access-tokens/new

gh asks how to log in next. Pick "Paste an authentication token" for a token
like that, or "Login with a web browser" for your whole account. gh keeps the
login itself, in ~/.config/gh.
EOF
        as_user 'gh auth login --hostname github.com --git-protocol https'
    fi
    as_user 'gh auth setup-git'
}

set_git_identity() {
    step "git identity (3 of 3)"
    local key label value
    for key in user.name user.email; do
        if value="$(as_user 'git config --global "$1"' "$key")" && [ -n "$value" ]; then
            echo "$key is $value"
            continue
        fi
        label="name"; [ "$key" = user.email ] && label="email"
        read -rp "Your $label for commits made here (Enter skips): " value
        [ -z "$value" ] || as_user 'git config --global "$1" "$2"' "$key" "$value"
    done
}

if [ "$do_install" -eq 1 ]; then
    install_packages
    install_directories
    install_claude
    enable_linger
fi

if [ "$do_login" -eq 1 ]; then
    if [ -t 0 ]; then
        login_claude
        login_github
        set_git_identity
    else
        warn "no terminal, so the logins were skipped. Run: bash bootstrap-host.sh --login-only"
    fi
fi

# What is set up, and the command that fixes each thing that isn't.
show_status() {
    step "Setup"
    as_user '
        ok() { printf "  ok       %s\n" "$1"; }
        missing() { printf "  missing  %s\n           %s\n" "$1" "$2"; }
        have() { command -v "$1" >/dev/null 2>&1; }
        check() { if have "$1"; then ok "$2"; else missing "$1" "run: bash bootstrap-host.sh"; fi; }

        check git "$(git --version 2>/dev/null)"
        check gh "$(gh --version 2>/dev/null | head -n 1)"
        check claude "claude $(claude --version 2>/dev/null)"

        if grep -qs "^CLAUDE_CODE_OAUTH_TOKEN=." "$HOME/$1"; then
            ok "claude login (token in ~/$1)"
        else
            missing "claude login" "run: bash bootstrap-host.sh --login-only"
        fi
        if have gh && gh auth status --hostname github.com >/dev/null 2>&1; then
            ok "GitHub login"
        else
            missing "GitHub login" "run: bash bootstrap-host.sh --login-only"
        fi
        name="$(git config --global user.name 2>/dev/null || true)"
        email="$(git config --global user.email 2>/dev/null || true)"
        if [ -n "$name" ] && [ -n "$email" ]; then
            ok "git identity ($name <$email>)"
        else
            missing "git identity" "run: git config --global user.name \"Your Name\"; git config --global user.email you@example.com"
        fi
        if [ -d "$HOME/psyduck/workspaces" ]; then
            ok "$HOME/psyduck"
        else
            missing "$HOME/psyduck" "run: bash bootstrap-host.sh"
        fi
        echo
        echo "Settings file: ~/$1"' "$env_file_name"
}

show_status
