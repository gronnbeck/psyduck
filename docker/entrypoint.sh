#!/bin/sh
# Starts `psyduck serve` in the container. Logins come from the environment
# (see docker/.env.example), never from the image.
set -e

mkdir -p /data/state /data/claude /data/repos /data/workspaces
if [ ! -f "$PSYDUCK_CONFIG" ]; then
    cat > "$PSYDUCK_CONFIG" <<'JSON'
{
  "workspacesRoot": "/data/workspaces",
  "reposRoot": "/data/repos",
  "permissionMode": "bypassPermissions",
  "model": ""
}
JSON
fi

[ -n "$GIT_USER_NAME" ] && git config --global user.name "$GIT_USER_NAME"
[ -n "$GIT_USER_EMAIL" ] && git config --global user.email "$GIT_USER_EMAIL"

if [ -n "$GH_TOKEN" ]; then
    # git asks gh for the password, and gh answers with GH_TOKEN.
    git config --global credential.https://github.com.helper ""
    git config --global --add credential.https://github.com.helper "!gh auth git-credential"
else
    echo "psyduck: GH_TOKEN isn't set. Private repos, pushes and pull requests won't work." >&2
fi

if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ] && [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "psyduck: CLAUDE_CODE_OAUTH_TOKEN isn't set. Make one with 'claude setup-token'; until then every turn fails." >&2
fi

exec psyduck serve
