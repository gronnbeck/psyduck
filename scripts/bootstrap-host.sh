#!/usr/bin/env bash
# Sets up a Linux machine (Ubuntu or Debian) to run psyduck sessions:
# git, gh, claude, the directories psyduck uses, and the claude and GitHub
# logins. Safe to run again; it skips what is already there.
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
  -h, --help     Show this.
EOF
}

target_user=""
do_install=1
do_login=1

while [ $# -gt 0 ]; do
    case "$1" in
        --user) [ $# -ge 2 ] || { echo "--user needs a name" >&2; exit 2; }; target_user="$2"; shift 2 ;;
        --user=*) target_user="${1#--user=}"; shift ;;
        --no-login) do_login=0; shift ;;
        --login-only) do_install=0; shift ;;
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
             install -d -m 700 "$HOME/.config/psyduck"'
    echo "$target_home/psyduck"
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
    step "claude login"
    if [ -s "$target_home/.config/psyduck/env" ]; then
        echo "A claude token is already saved in ~/.config/psyduck/env. Delete that file to log in again."
        return
    fi
    as_user '
        echo "Open the URL claude prints, and paste the code back here."
        claude setup-token
        echo
        read -rsp "Paste the token printed above, to save it for psyduck (Enter skips): " token
        echo
        [ -n "$token" ] || { echo "No token given, nothing saved."; exit 0; }
        install -d -m 700 "$HOME/.config/psyduck"
        umask 177
        printf "CLAUDE_CODE_OAUTH_TOKEN=%s\n" "$token" > "$HOME/.config/psyduck/env"
        echo "Saved to ~/.config/psyduck/env (mode 600)."'
}

login_github() {
    step "GitHub login"
    if as_user 'gh auth status --hostname github.com >/dev/null 2>&1'; then
        echo "gh is already logged in."
    else
        cat <<'EOF'
Agents on this machine run without asking permission, and can use whatever
this login can reach. A fine-grained token limited to the repos you'll work
on here is the safer choice:
https://github.com/settings/personal-access-tokens/new
EOF
        as_user 'gh auth login --hostname github.com --git-protocol https'
    fi
    as_user 'gh auth setup-git'
}

set_git_identity() {
    step "git identity"
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

step "Done"
as_user 'printf "git     %s\ngh      %s\nclaude  %s\n" \
    "$(git --version 2>/dev/null || echo missing)" \
    "$(gh --version 2>/dev/null | head -n 1 || echo missing)" \
    "$(claude --version 2>/dev/null || echo missing)"'
