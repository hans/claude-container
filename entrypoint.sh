#!/bin/sh
# Container entrypoint. Sources /workdir/.env so per-project env vars are
# visible to the agent (API keys, model overrides, etc.), then execs the
# command passed by `docker run`. Defaults to `claude` via the Dockerfile CMD.
set -eu

if [ -f /workdir/.env ]; then
    set -a
    # shellcheck disable=SC1091
    . /workdir/.env
    set +a
fi

exec "$@"
