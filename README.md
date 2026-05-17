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
| Environment            | `CLAUDE_SANDBOX_NETWORK=bridge` *(example)* |

Superset appends the prompt as argv to "Command (With Prompt)" after the
suffix, which is exactly what `launch.sh` expects.

The **Environment** field is where you set `CLAUDE_SANDBOX_*` variables (see
[Environment variables](#environment-variables) below). Each line in that field
is passed to `launch.sh` as an environment variable before Docker runs. You can
also `export` them in your shell before starting Superset if you prefer a
host-wide default.

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

There are two places variables are consumed, and they require different
placement:

### Host-side variables (read by `launch.sh` before Docker runs)

Set these in **Superset → Settings → Agents → your agent → Environment**, one
per line. Superset injects them into the shell that runs `launch.sh`. You can
also `export` them before starting Superset for a host-wide default.

| Variable                     | Purpose                                                              | Default              |
|------------------------------|----------------------------------------------------------------------|----------------------|
| `CLAUDE_SANDBOX_IMAGE`       | Docker image to run                                                  | `claude-sandbox:latest` |
| `CLAUDE_SANDBOX_NETWORK`     | `--network` value: `bridge` / `host` / `none` / custom network name  | `bridge`             |
| `CLAUDE_SANDBOX_MOUNT_SSH`   | Set to `1` to mount `~/.ssh` read-only (for git push over SSH)       | unset (off)          |
| `CLAUDE_SANDBOX_MOUNT_SYMLINKS`    | Set to `0` to skip the symlink-escape scan (see below)         | `1` (on)             |
| `CLAUDE_SANDBOX_SYMLINK_MOUNTS_RW` | Set to `1` to mount **all** symlink targets read-write          | `0` (read-only)      |
| `CLAUDE_SANDBOX_SYMLINK_RW_PATHS`  | Colon-delimited path prefixes to mount rw; everything else stays ro. E.g. `/data/outputs:/scratch` | unset |
| `CLAUDE_SANDBOX_PROMPT`      | Manual override for the agent's initial prompt                       | unset                |
| `ANTHROPIC_*`                | Any var matching this prefix is forwarded into the container         | inherited from host  |

### Container-side variables (visible to the agent inside Docker)

Put project-specific secrets and config (API keys, model overrides, etc.) in a
`.env` file at the worktree root. The container's `entrypoint.sh` sources it
automatically on every launch, including reattaches. Example:

```
ANTHROPIC_API_KEY=sk-ant-...
SOME_PROJECT_API_KEY=...
```

`setup.sh` copies `../.env` → `./.env` when a new worktree is created (if the
parent has one), so you can keep a single `.env` in the main checkout and have
it propagate automatically.

`ANTHROPIC_*` vars set on the host are also forwarded automatically by
`launch.sh` (see table above), so you can choose whichever approach suits your
secrets workflow.

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

## How symlinks that escape the worktree are handled

It's common to symlink a `results/` (or shared dataset) directory into a
worktree from somewhere else on disk -- another worktree, a scratch dir,
a network mount. Because the container only sees `/workdir` (the worktree
bind mount), any symlink whose target lives outside `$PWD` would otherwise
appear as a broken link inside the container.

`launch.sh` handles this with the same trick used for the `.git` parent
directory: scan the worktree for symlinks, resolve each target, and for
every target outside `$PWD` add a bind mount at the *same absolute host
path* inside the container. The symlink then resolves identically inside
and outside the container.

Behavior:

- **Read-only by default.** Symlinked results are typically inputs you
  read, not write. Two ways to opt specific targets into rw:
  - `CLAUDE_SANDBOX_SYMLINK_MOUNTS_RW=1` — all symlink targets rw.
  - `CLAUDE_SANDBOX_SYMLINK_RW_PATHS=/data/outputs:/scratch` — only targets
    under those prefixes are rw; everything else stays ro. If the same target
    would be mounted both ways (two symlinks, different callers), rw wins.
- **`.git` is pruned from the scan** for speed (lots of files, almost
  never contains external symlinks).
- **Targets inside `$PWD` are skipped** -- they're already covered by
  the `/workdir` mount. The check is symlink-aware on the worktree side
  too (e.g. macOS `/tmp` -> `/private/tmp`).
- **Broken symlinks are skipped** -- docker would refuse the mount.
- **Duplicate targets are deduplicated** -- two symlinks pointing at the
  same directory produce one mount.
- Each mount is logged to stderr at launch (`mounting symlink target ...`)
  so it's visible what's being exposed to the agent.
- The scan walks the full worktree on every launch. If you have a very
  large tree (huge `node_modules`, etc.) and don't need this feature, set
  `CLAUDE_SANDBOX_MOUNT_SYMLINKS=0` to skip it.
- **The scan only runs on the initial `docker run`**, not on reattach
  (`docker exec`). If you add a new external symlink while the container
  is still up, exit and relaunch to pick it up -- mounts can't be added
  to a running container.

Caveat: any directory the agent can reach via a symlink is now writable
on the host (if `_RW=1`) or readable in full (always, if mounted). Treat
this as you would any bind mount -- only symlink in directories you're
fine exposing to the sandbox.

**Docker Desktop on macOS** restricts bind mounts to a configured set of
host paths (default: `/Users`, `/tmp`, `/private`, `/var/folders`,
`/Volumes`). If a symlink target lives outside that allowlist (e.g.
`/opt/data/...`) `docker run` will fail with a "mounts denied" error.
Fix: add the host path under Docker Desktop &rarr; Settings &rarr;
Resources &rarr; File sharing, or move the target under an already-shared
prefix.

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
