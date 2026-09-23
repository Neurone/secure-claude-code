#!/bin/sh
# /home/node/.local is a persistent volume, so the native install here
# survives across --rm containers: once updated, a version stays until the
# host moves further ahead, instead of resetting to the image's baked-in
# version on every run.
set -e

# /home/node/.claude is itself a persistent volume (see claude.sh), holding
# the container's own Anthropic login independent of the host's, plus
# whatever else Claude Code writes there (host entries like settings.json
# or agents/ are still bind-mounted individually on top by claude.sh, as
# before). On its very first-ever run (empty volume) .credentials.json is
# seeded from the host credentials that claude.sh bind-mounted read-only at
# CREDENTIALS_SEED_FILE, if any; every run after that already has a real
# credentials file here and skips the seed, since a login or token refresh
# done inside the container must never be clobbered by a stale host
# credential on the next run.
# A symlink to a credentials volume was tried instead of this and doesn't
# work: Claude Code saves credentials via a temp-file-then-rename, and
# rename() onto a symlink path replaces the symlink itself with a regular
# file rather than writing through it, so the save landed in the
# container's ephemeral layer and vanished on the next --rm.
CREDENTIALS_FILE="/home/node/.claude/.credentials.json"
CREDENTIALS_SEED_FILE="/home/node/.claude-host-credentials-seed.json"

if [ ! -f "$CREDENTIALS_FILE" ] && [ -f "$CREDENTIALS_SEED_FILE" ]; then
  install -m 600 "$CREDENTIALS_SEED_FILE" "$CREDENTIALS_FILE"
fi

CONTAINER_VERSION="$(claude --version 2>/dev/null | awk '{print $1}')"

# HOST_CLAUDE_VERSION is set by claude.sh from the native host install, when
# there is one. If so, only update when the container is strictly behind it:
# a fresh container must not drift ahead of whatever version the host is
# currently on. Without a native host install to track (HOST_CLAUDE_VERSION
# empty, e.g. claude is only ever used sandboxed), there is nothing to stay
# in sync with, so just self-update to latest instead.
if [ -n "${HOST_CLAUDE_VERSION:-}" ]; then
  if [ "$CONTAINER_VERSION" != "$HOST_CLAUDE_VERSION" ]; then
    OLDER_VERSION="$(printf '%s\n%s\n' "$CONTAINER_VERSION" "$HOST_CLAUDE_VERSION" | sort -V | head -1)"
    if [ "$OLDER_VERSION" = "$CONTAINER_VERSION" ]; then
      echo "Updating claude ($CONTAINER_VERSION -> $HOST_CLAUDE_VERSION)..." >&2
      claude update || echo "Warning: claude update failed; continuing with existing version ($CONTAINER_VERSION)" >&2
    fi
  fi
else
  claude update || echo "Warning: claude self-update failed; continuing with existing version ($CONTAINER_VERSION)" >&2
fi

exec claude "$@"
