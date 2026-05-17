#!/usr/bin/env bash
# Launch Claude Code inside a per-workspace Docker container.
#
# Superset invokes this script with $PWD = workspace worktree. When the agent
# is launched with a prompt, Superset appends the prompt as argv (per the
# "Command (With Prompt)" config slot). We also accept the prompt via
# $CLAUDE_SANDBOX_PROMPT (env) or stdin so the script is usable manually.
#
# Behavior:
#   - First invocation in a worktree: `docker run` a fresh container.
#   - Subsequent invocations while the container is still up: `docker exec`
#     into it, so closing/reopening a terminal reattaches to the same sandbox.
#   - Container is `--rm`, so when claude exits the container is removed.
#     Worktree state lives on disk via the bind mount, not in the container.

set -euo pipefail

# --- config -----------------------------------------------------------------
IMAGE="${CLAUDE_SANDBOX_IMAGE:-claude-sandbox:latest}"
NETWORK="${CLAUDE_SANDBOX_NETWORK:-bridge}"

# --- prompt detection -------------------------------------------------------
# Priority: argv tail > CLAUDE_SANDBOX_PROMPT env > stdin (if piped).
PROMPT=""
if [ "$#" -gt 0 ] && [ -n "${1:-}" ]; then
    PROMPT="$*"
elif [ -n "${CLAUDE_SANDBOX_PROMPT:-}" ]; then
    PROMPT="$CLAUDE_SANDBOX_PROMPT"
elif [ ! -t 0 ]; then
    # stdin is not a TTY -- assume it carries the prompt. Read all of it.
    PROMPT="$(cat)"
fi

# --- preflight --------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "claude-sandbox: docker not found on PATH." >&2
    echo "  Install Docker Desktop (macOS) or the docker engine (Linux)." >&2
    exit 127
fi

if ! docker info >/dev/null 2>&1; then
    echo "claude-sandbox: docker daemon not reachable." >&2
    echo "  Is Docker Desktop running?" >&2
    exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "claude-sandbox: image '$IMAGE' not found." >&2
    echo "  Build it from the repo root:" >&2
    echo "    docker build -t claude-sandbox:latest ." >&2
    exit 1
fi

if [ ! -d "$HOME/.claude" ] || [ ! -f "$HOME/.claude.json" ]; then
    echo "claude-sandbox: missing Claude Code host config." >&2
    echo "  Need both \$HOME/.claude/ (dir) and \$HOME/.claude.json (file)." >&2
    echo "  Run \`claude /login\` on the host first to create them." >&2
    exit 1
fi

# macOS: Claude Code stores OAuth tokens in the system keychain, not in any
# file. The Linux container can't read the keychain, so we extract the JSON
# blob and stage it at ~/.claude/.credentials.json (where Claude Code on
# Linux looks for it -- that path is inside the mounted ~/.claude directory).
#
# Caveat: when Claude inside the container refreshes the token, it writes a
# new credentials file but does NOT update the host's keychain. The host's
# keychain copy becomes stale, and you may need to re-run `claude /login`
# on the host the next time you use Claude there. Refresh tokens last weeks,
# so this is infrequent.
if [ "$(uname -s)" = "Darwin" ]; then
    creds="$HOME/.claude/.credentials.json"
    if blob="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null)"; then
        umask 077
        printf '%s\n' "$blob" > "$creds"
    else
        echo "claude-sandbox: warning -- couldn't read 'Claude Code-credentials' from keychain." >&2
        echo "  Run \`claude /login\` on the host (so the keychain entry exists)." >&2
        echo "  Continuing; the container may prompt you to log in instead." >&2
    fi
fi

# --- container name ---------------------------------------------------------
# basename + short hash of full path -- collision-free across worktrees that
# happen to share a basename. shasum on macOS, sha1sum on Linux.
hash_path() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 1 | cut -c1-8
    else
        printf '%s' "$1" | sha1sum | cut -c1-8
    fi
}

# Sanitize: replace any char outside [A-Za-z0-9_.-] (including the trailing
# newline from basename) with `-`, then collapse runs and trim trailing `-`.
WORKTREE_BASENAME="$(basename "$PWD" | tr -c 'A-Za-z0-9_.-' '-' | tr -s '-' | sed 's/-*$//')"
NAME="claude-sandbox-${WORKTREE_BASENAME}-$(hash_path "$PWD")"

# --- build claude argv ------------------------------------------------------
# Claude Code accepts an initial prompt as a positional argument.
# When no prompt is given, omit it so claude starts in plain interactive mode.
claude_argv=(claude)
if [ -n "$PROMPT" ]; then
    claude_argv+=("$PROMPT")
fi

# --- reattach if container already exists -----------------------------------
# Invoke entrypoint.sh explicitly so /workdir/.env is re-sourced in the exec
# path too (docker exec otherwise bypasses ENTRYPOINT).
if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    exec docker exec -it "$NAME" /usr/local/bin/entrypoint.sh "${claude_argv[@]}"
fi

# --- run flags --------------------------------------------------------------
docker_args=(
    run --rm -it
    --name "$NAME"
    -v "$PWD:/workdir"
    -v "$HOME/.claude:/home/claude/.claude"      # rw -- claude writes session state here
    -v "$HOME/.claude.json:/home/claude/.claude.json"  # the actual config file (lives next to .claude/, not inside)
    -v "$HOME/.gitconfig:/home/claude/.gitconfig:ro"
    -w /workdir
    -e HOME=/home/claude                          # ensure $HOME points at the user dir even
                                                  # when the runtime UID has no /etc/passwd entry
    -u "$(id -u):$(id -g)"                        # match host UID/GID so bind-mount writes work
    --network "$NETWORK"
)

# Git worktree (and submodule) support: $PWD/.git is a *file* like
# `gitdir: /host/abs/path/to/.git/worktrees/<name>`. That absolute path is
# outside the worktree bind mount, so git in the container can't follow it.
# Mount the parent .git directory at the same absolute path so the pointer
# still resolves. Mounted rw because git commits write objects there.
if [ -f "$PWD/.git" ]; then
    gitdir="$(sed -n 's/^gitdir: *//p' "$PWD/.git")"
    if [ -n "$gitdir" ]; then
        # Worktrees: <repo>/.git/worktrees/<name>. Submodules: <super>/.git/modules/<name>.
        # Both resolve to <repo-or-super>/.git via two dirname levels.
        parent_git="$(dirname "$(dirname "$gitdir")")"
        if [ -d "$parent_git" ]; then
            docker_args+=(-v "$parent_git:$parent_git")
        fi
    fi
fi

# Optional: mount host ~/.ssh read-only when the user opts in (e.g. for git push over SSH).
if [ "${CLAUDE_SANDBOX_MOUNT_SSH:-0}" = "1" ] && [ -d "$HOME/.ssh" ]; then
    docker_args+=(-v "$HOME/.ssh:/home/claude/.ssh:ro")
fi

# Forward ANTHROPIC_* env vars from the host (API keys, base URLs, model overrides).
while IFS= read -r var; do
    [ -n "$var" ] && docker_args+=(-e "$var")
done < <(env | awk -F= '/^ANTHROPIC_/ {print $1}')

# Forward Superset-injected workspace env vars so the agent knows which
# workspace it's in. Pass by name; docker reads the value from our env.
for var in SUPERSET_WORKSPACE_NAME SUPERSET_ROOT_PATH; do
    if [ -n "${!var:-}" ]; then
        docker_args+=(-e "$var")
    fi
done

# --- go ---------------------------------------------------------------------
exec docker "${docker_args[@]}" "$IMAGE" "${claude_argv[@]}"
