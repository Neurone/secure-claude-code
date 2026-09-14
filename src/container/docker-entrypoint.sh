#!/bin/sh
# /home/node/.local is a persistent volume, so the native install here
# survives across --rm containers: once updated, a version stays until the
# host moves further ahead, instead of resetting to the image's baked-in
# version on every run.
set -e

CONTAINER_VERSION="$(claude --version 2>/dev/null | awk '{print $1}')"

# HOST_CLAUDE_VERSION is set by claude.sh from the native host install.
# Only update when the container is strictly behind it: a fresh container
# must not drift ahead of whatever version the host is currently on.
if [ -n "${HOST_CLAUDE_VERSION:-}" ] && [ "$CONTAINER_VERSION" != "$HOST_CLAUDE_VERSION" ]; then
  OLDER_VERSION="$(printf '%s\n%s\n' "$CONTAINER_VERSION" "$HOST_CLAUDE_VERSION" | sort -V | head -1)"
  if [ "$OLDER_VERSION" = "$CONTAINER_VERSION" ]; then
    echo "Updating claude ($CONTAINER_VERSION -> $HOST_CLAUDE_VERSION)..." >&2
    claude update || echo "Warning: claude update failed; continuing with existing version ($CONTAINER_VERSION)" >&2
  fi
fi

exec claude "$@"
