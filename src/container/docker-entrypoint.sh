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
CREDENTIALS_FILE="${HOME:?}/.claude/.credentials.json"
CREDENTIALS_SEED_FILE="${HOME:?}/.claude-host-credentials-seed.json"

if [ ! -f "$CREDENTIALS_FILE" ] && [ -f "$CREDENTIALS_SEED_FILE" ]; then
  install -m 600 "$CREDENTIALS_SEED_FILE" "$CREDENTIALS_FILE"
fi

# Same seed-once pattern as credentials just above, for the same reason: when
# claude.sh's resolve_settings_mount_mode chose "rw", settings.json is
# writable from inside the container, but it can't be a live bind mount of
# the host file, since Claude Code saves it via a temp-file-then-rename and
# rename(2) onto an active bind-mount point fails with EBUSY (confirmed: it
# silently breaks model/effort selection, while simpler flag toggles like
# autoCompactEnabled apparently use a different, non-atomic write and still
# go through). So claude.sh instead mounts the host file read-only at
# SETTINGS_SEED_FILE, and it is copied into the real, volume-backed
# settings.json here, once: after that the container's own copy is
# authoritative and safely renameable, independent of the host's (same
# divergence as the login above).
SETTINGS_FILE="${HOME:?}/.claude/settings.json"
SETTINGS_SEED_FILE="${HOME:?}/.claude-host-settings-seed.json"

if [ ! -f "$SETTINGS_FILE" ] && [ -f "$SETTINGS_SEED_FILE" ]; then
  install -m 644 "$SETTINGS_SEED_FILE" "$SETTINGS_FILE"
fi

# Only this script knows whether the volume already holds a login: claude.sh
# just passes along a seed when the host happens to have credentials.
if [ ! -f "$CREDENTIALS_FILE" ]; then
  echo "No saved login found: sign in inside the container; it will be remembered for the next runs." >&2
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
