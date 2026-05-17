# claude-sandbox

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions
inside a per-workspace Docker container, launched by
[Superset](https://superset.sh). Each workspace gets an isolated sandbox; the
worktree is bind-mounted at `/workdir`, so all state -- code, git history,
diffs -- lives on the host and is visible to Superset's diff viewer as usual.

This is deliberately *not* a Container Use (`cu`) setup. The Superset worktree
is the single source of truth; the container is just an execution sandbox for
the agent's bash tool.

## Prerequisites

- macOS or Linux host with Docker (Docker Desktop on macOS, Docker Engine on Linux).
- [Superset](https://superset.sh) installed.
- Claude Code installed on the host and logged in: `claude /login`. This is
  what creates the `~/.claude` directory that the container mounts.

## Build the image

From this repo's root:

```
docker build -t claude-sandbox:latest .
```

The image only needs to be rebuilt when you change the `Dockerfile`. Per-project
customization (extra Python deps, etc.) is handled separately -- see [Per-project
extension](#per-project-extension) below.

## Configure Superset

In Superset: **Settings &rarr; Agents &rarr; New agent** (or duplicate the
built-in `claude` preset and edit it).

Fill the agent fields like this:

| Field                  | Value                                       |
|------------------------|---------------------------------------------|
| Command (No Prompt)    | `.superset/launch.sh`                       |
| Command (With Prompt)  | `.superset/launch.sh`                       |
| Prompt Command Suffix  | *(empty)*                                   |
| Task Prompt Template   | *(default is fine)*                         |

Superset appends the prompt as argv to "Command (With Prompt)" after the
suffix, which is exactly what `launch.sh` expects.

> Superset doesn't define a `SUPERSET_PROMPT` env var; the env-var and stdin
> paths in `launch.sh` are manual-use fallbacks (handy when invoking the
> script directly from a terminal), not Superset-driven transports.

## Per-project extension

The global `claude-sandbox` image stays generic. Two ways to add per-project
tools:

**Quick (one-off)** -- `docker exec` into the running container and install
ad-hoc. Anything you install lands in the container's writable layer and is
lost when claude exits (because we run with `--rm`). Useful for trying a tool
out.

**Persistent** -- create a project-local `Dockerfile.project`:

```dockerfile
FROM claude-sandbox:latest
RUN pip install --break-system-packages mne nibabel
```

Build it:

```
docker build -t claude-sandbox-myproj -f Dockerfile.project .
```

Then point `launch.sh` at it via env var when starting Superset (or set it in
the agent's environment):

```
export CLAUDE_SANDBOX_IMAGE=claude-sandbox-myproj
```

## Environment variables

These are read by `launch.sh` on the host:

| Variable                     | Purpose                                                              | Default              |
|------------------------------|----------------------------------------------------------------------|----------------------|
| `CLAUDE_SANDBOX_IMAGE`       | Docker image to run                                                  | `claude-sandbox:latest` |
| `CLAUDE_SANDBOX_NETWORK`     | `--network` value: `bridge` / `host` / `none` / custom network name  | `bridge`             |
| `CLAUDE_SANDBOX_MOUNT_SSH`   | Set to `1` to mount `~/.ssh` read-only (for git push over SSH)       | unset (off)          |
| `CLAUDE_SANDBOX_PROMPT`      | Manual override for the agent's initial prompt                       | unset                |
| `ANTHROPIC_*`                | Any env var matching this prefix is forwarded into the container     | inherited            |

Network mode tradeoffs:
- `bridge` (default): container gets its own NAT'd network. Outbound is fine;
  the agent can't reach `localhost`-bound services on the host.
- `host`: container shares the host network. The agent can hit `localhost`
  services (handy when you're testing a local API). No isolation from host
  ports.
- `none`: no network. Useful when you want a hermetic sandbox.

## How git worktrees are handled

Superset workspaces are git worktrees. In a worktree, `.git` is a *file* like
`gitdir: /abs/path/to/main-repo/.git/worktrees/<name>` -- an absolute host
path that points outside the worktree directory. If only the worktree is
bind-mounted, git inside the container can't follow that pointer and every
git command fails with "not a git repository".

`launch.sh` reads `$PWD/.git`, walks up two directories to find the
common `.git` dir (`<repo>/.git`), and bind-mounts it at the same absolute
path inside the container so the pointer resolves. The mount is read-write
because commits need to write objects and refs there. This is also what makes
submodules work (same gitdir-pointer pattern).

If your project uses a non-standard git layout (custom `GIT_DIR`, etc.),
you may need to extend `launch.sh`.

## Troubleshooting

**`permission denied` writing into the worktree or `~/.claude`.** `launch.sh`
runs the container as `-u $(id -u):$(id -g)`, which works on macOS (host UID
501) and Linux out of the box. If you've hardcoded `-u 1000:1000` for some
reason and the host UID isn't 1000, bind-mount writes will fail. Revert to
the default UID flag.

**`credentials not found` / Claude Code asks you to log in inside the
container.** The container mounts both `~/.claude` (directory) and the
sibling `~/.claude.json` (config file). If either is missing, run `claude
/login` on the host first.

On macOS, the OAuth tokens themselves live in the system keychain (not in
any file), so the bind-mounts alone aren't enough. `launch.sh` extracts the
`Claude Code-credentials` keychain entry on every launch and stages it at
`~/.claude/.credentials.json`, which Linux Claude reads natively. **Side
effect:** when Claude inside the container refreshes its access token, the
host keychain's refresh token may be invalidated, and you'll need to
re-`claude /login` on the host the next time you use Claude there. Refresh
tokens last weeks, so this is infrequent.

**`Claude configuration file not found at: /home/claude/.claude.json` after
the host config was edited.** Bind-mounted single files are pinned to the
inode at mount time. Some atomic-write tools (and Claude Code's own backup
flow) replace the file rather than truncating it, which breaks the mount.
Exit the container and re-launch to pick up the new file.

**Container name collision** (`docker: Error response from daemon: Conflict.
The container name "/claude-sandbox-..." is already in use`). Rare -- the name
includes a hash of the worktree path. If it happens, an old container is
still running:

```
docker rm -f claude-sandbox-<basename>-<hash>
```

**Closing the laptop killed my session.** `launch.sh` uses `--rm`, so when
the `claude` process inside the container exits (or its TTY drops), the
container is removed. Reattach works *while* the container is still up;
it's not a way to survive arbitrary disconnections. If you need
sleep-survives sessions, a long-lived `tmux` inside the container is the
usual workaround.

## What this deliberately doesn't do

- **No Container Use.** No nested branch namespace, no auto-commits to a
  separate remote. Git history lives on the host worktree.
- **No multi-agent orchestration.** One agent = one container. Superset
  handles running multiple workspaces in parallel; each gets its own
  container via this script.
- **No GPU passthrough.** Local sandbox is CPU-only by design.
- **No Windows support.** macOS + Linux only.
