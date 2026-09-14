#!/usr/bin/env bash
set -euo pipefail

# Resolve this script's real location, following symlinks: once install.sh
# runs, 'claude' is a symlink to this file, so BASH_SOURCE[0] alone would
# point at the symlink's directory instead of this repo's src/ directory.
# path-utils.sh (which has a general resolve_path helper) cannot be sourced
# yet, since its own path is derived from SCRIPT_DIR, hence this inline loop.
SELF_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SELF_SOURCE" ]; do
  SELF_SOURCE_DIR="$(cd -P "$(dirname "$SELF_SOURCE")" && pwd)"
  SELF_SOURCE="$(readlink "$SELF_SOURCE")"
  [[ "$SELF_SOURCE" = /* ]] || SELF_SOURCE="$SELF_SOURCE_DIR/$SELF_SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SELF_SOURCE")" && pwd -P)"
CONTAINER_DIR="$SCRIPT_DIR/container"
DOCKERFILE="$CONTAINER_DIR/Dockerfile.claude-code"
PATH_UTILS="$SCRIPT_DIR/lib/path-utils.sh"
INSTALL_COMMON="$SCRIPT_DIR/lib/install-common.sh"

find_host_claude_binary() {
  local self_real="$1"
  local candidate_path

  for host_command in claude-original claude; do
    if ! command -v "$host_command" >/dev/null 2>&1; then
      continue
    fi

    candidate_path="$(command -v "$host_command")"
    if [ -x "$candidate_path" ] && [ "$(resolve_path "$candidate_path")" != "$self_real" ]; then
      printf '%s\n' "$candidate_path"
      return 0
    fi
  done

  return 1
}

append_mount_if_file() {
  local source_path="$1"
  local target_path="$2"
  local mode="${3:-}"

  if [ ! -f "$source_path" ]; then
    return 0
  fi

  if [ -n "$mode" ]; then
    MOUNT_ARGS+=(-v "$source_path:$target_path:$mode")
  else
    MOUNT_ARGS+=(-v "$source_path:$target_path")
  fi
}

# Every hook script referenced by settings.json's "command" hooks must be
# reachable at the same absolute path inside the container, since that's the
# path Claude Code will invoke. Paths already under $CLAUDE_DIR_SRC or
# $PROJECT_DIR are covered by mounts set up elsewhere, so they are reported
# as mounted without being bind-mounted a second time (Docker Desktop's
# virtiofs backend rejects overlapping mounts from different sources).
collect_hook_mounts() {
  local settings_file="$1"
  local hook_command hook_path

  if [ ! -f "$settings_file" ]; then
    return 0
  fi

  while IFS= read -r hook_command; do
    [ -z "$hook_command" ] && continue
    hook_path="${hook_command%% *}"

    case "$hook_path" in
      /*) ;;
      *) continue ;;
    esac

    case "$hook_path" in
      "$CLAUDE_DIR_SRC"/* | "$PROJECT_DIR"/*)
        HOOK_FILES_MOUNTED+=("$hook_path")
        continue
        ;;
    esac

    if [ -f "$hook_path" ]; then
      append_mount_if_file "$hook_path" "$hook_path" "ro"
      HOOK_FILES_MOUNTED+=("$hook_path")
    else
      HOOK_FILES_MISSING+=("$hook_path")
    fi
  done < <(jq -r '(.hooks // {}) | to_entries[] | .value[]? | .hooks[]? | select(.type == "command") | .command' "$settings_file" | sort -u)
}

print_hook_mount_manifest() {
  if [ "${#HOOK_FILES_MISSING[@]}" -gt 0 ]; then
    echo "Warning: hook scripts referenced in $CLAUDE_DIR_SRC/settings.json were not found on the host and will not run in the container:" >&2
    local hook_file
    for hook_file in "${HOOK_FILES_MISSING[@]}"; do
      echo "  - $hook_file" >&2
    done
  fi
}

# Hook availability is informational, not a warning, so it is surfaced via the
# same companyAnnouncements banner as the DOCKER SANDBOX notice (see
# CONTAINER_SETTINGS below) instead of a separate stderr line before the
# Claude Code banner renders. Claude Code only displays one entry of
# companyAnnouncements per session, picked at random when the array has more
# than one, so all lines are joined into a single array entry with embedded
# newlines rather than appended as separate entries.
build_company_announcement() {
  ANNOUNCEMENT_LINES=("🐳  DOCKER SANDBOX — this is the containerized Claude Code, not the native install")

  if [ "${#HOOK_FILES_MOUNTED[@]}" -gt 0 ]; then
    ANNOUNCEMENT_LINES+=("Hook scripts linked in the container (from $CLAUDE_DIR_SRC/settings.json):")
    local hook_file
    for hook_file in "${HOOK_FILES_MOUNTED[@]}"; do
      ANNOUNCEMENT_LINES+=("  - $hook_file")
    done
  fi
}

if [ ! -f "$PATH_UTILS" ]; then
  echo "Error: could not find path utils at $PATH_UTILS" >&2
  exit 1
fi

# shellcheck source=lib/path-utils.sh
source "$PATH_UTILS"

if [ ! -f "$INSTALL_COMMON" ]; then
  echo "Error: could not find install-common helpers at $INSTALL_COMMON" >&2
  exit 1
fi

# shellcheck source=lib/install-common.sh
source "$INSTALL_COMMON"

OS="$(uname -s)"

if [ ! -f "$DOCKERFILE" ]; then
  echo "Error: could not find Dockerfile at $DOCKERFILE" >&2
  exit 1
fi

# Needed to read the "command" hooks out of ~/.claude/settings.json so their
# scripts can be mounted into the container (see collect_hook_mounts).
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required to mount hook scripts declared in ~/.claude/settings.json. Install jq and try again." >&2
  exit 1
fi

declare -a HOOK_FILES_MOUNTED=()
declare -a HOOK_FILES_MISSING=()

# ---------------------------------------------------------------------------
# The image only needs building once: claude itself is kept in sync with the
# host inside the container (see docker-entrypoint.sh) on a persistent
# volume, so a new claude release never requires rebuilding the whole image.
# ---------------------------------------------------------------------------
if ! docker image inspect "$SECURE_CLAUDE_IMAGE_NAME" >/dev/null 2>&1; then
  echo "Building $SECURE_CLAUDE_IMAGE_NAME..." >&2
  docker build -t "$SECURE_CLAUDE_IMAGE_NAME" -f "$DOCKERFILE" "$CONTAINER_DIR"
fi

# ---------------------------------------------------------------------------
# Locate the native claude install. install.sh never touches it: it puts a
# 'claude-original' symlink to it (kept in sync with whatever the native
# auto-updater does) in ~/.secure-claude-code/bin alongside this wrapper, which is
# prepended to PATH as 'claude'. We prefer claude-original and only fall back
# to claude when the repository has not been installed yet.
# ---------------------------------------------------------------------------
SELF_REAL="$(resolve_path "${BASH_SOURCE[0]}")"
HOST_CLAUDE_VERSION=""
if HOST_CLAUDE_PATH="$(find_host_claude_binary "$SELF_REAL")"; then
  HOST_CLAUDE_VERSION="$($HOST_CLAUDE_PATH --version 2>/dev/null | awk '{print $1}')"
fi

# ---------------------------------------------------------------------------
# Timezone. The base image has no local timezone configured, so without this
# the container clock defaults to UTC while the host shows local time.
# ---------------------------------------------------------------------------
TZ_VALUE="${TZ:-}"
if [ -z "$TZ_VALUE" ] && [ -f /etc/timezone ]; then
  TZ_VALUE="$(< /etc/timezone)"
fi
if [ -z "$TZ_VALUE" ] && [ -e /etc/localtime ]; then
  TZ_VALUE="$(readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p')"
fi
TZ_ARGS=()
if [ -n "$TZ_VALUE" ]; then
  TZ_ARGS=(-e "TZ=$TZ_VALUE")
else
  echo "Warning: could not determine host timezone; container clock will show UTC" >&2
fi

CLAUDE_DIR_SRC="$HOME/.claude"

TMPDIR_RUN="$(mktemp -d)"
CREDS_TMP="$TMPDIR_RUN/.credentials.json"
GITCONFIG_TMP="$TMPDIR_RUN/gitconfig"
CA_BUNDLE_TMP="$TMPDIR_RUN/ca-certificates.crt"
cleanup() { rm -rf "$TMPDIR_RUN"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Credentials. macOS keeps them in the login Keychain; Linux normally keeps
# them in ~/.claude/.credentials.json (unless a system keyring is in use, in
# which case there is nothing to copy and the user logs in inside the
# container).
# ---------------------------------------------------------------------------
case "$OS" in
  Darwin)
    if security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w >"$CREDS_TMP" 2>/dev/null; then
      chmod 600 "$CREDS_TMP"
    else
      rm -f "$CREDS_TMP"
      echo "Warning: no credentials found in Keychain for 'Claude Code-credentials'; you'll need to log in inside the container" >&2
    fi
    ;;
  *)
    if [ -f "$CLAUDE_DIR_SRC/.credentials.json" ]; then
      install -m 600 "$CLAUDE_DIR_SRC/.credentials.json" "$CREDS_TMP"
    else
      rm -f "$CREDS_TMP"
      echo "Warning: no $CLAUDE_DIR_SRC/.credentials.json found; you'll need to log in inside the container" >&2
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# CA certificates. The image has no ca-certificates package, so without this
# every HTTPS request inside the container fails with curl exit 77 ("error
# setting certificate file"). The host's trust store is mounted in rather
# than installing a generic one, so the container also trusts whatever
# corporate root CA (e.g. a TLS-inspecting proxy) the host already trusts.
# ---------------------------------------------------------------------------
CA_BUNDLE_ARGS=()
case "$OS" in
  Darwin)
    if { security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain
         security find-certificate -a -p /Library/Keychains/System.keychain; } >"$CA_BUNDLE_TMP" 2>/dev/null \
       && [ -s "$CA_BUNDLE_TMP" ]; then
      CA_BUNDLE_ARGS=(-v "$CA_BUNDLE_TMP:/etc/ssl/certs/ca-certificates.crt:ro")
    else
      rm -f "$CA_BUNDLE_TMP"
      echo "Warning: could not export CA certificates from the macOS keychain; HTTPS requests inside the container may fail" >&2
    fi
    ;;
  *)
    for candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
      if [ -s "$candidate" ]; then
        CA_BUNDLE_ARGS=(-v "$candidate:/etc/ssl/certs/ca-certificates.crt:ro")
        break
      fi
    done
    if [ "${#CA_BUNDLE_ARGS[@]}" -eq 0 ]; then
      echo "Warning: no host CA bundle found; HTTPS requests inside the container may fail" >&2
    fi
    ;;
esac

PROJECT_DIR="$(pwd)"
CONTAINER_WORKDIR="$PROJECT_DIR"

# On SELinux hosts (Fedora/RHEL and derivatives) bind mounts are inaccessible
# without relabelling. Only the project mount gets :z — the flag relabels the
# host files recursively, which must not happen to ~/.claude or /etc/aim.
MOUNT_SUFFIX=""
if [ "$OS" = "Linux" ] && command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  MOUNT_SUFFIX=":z"
fi

MOUNT_ARGS=(-v "$PROJECT_DIR:$CONTAINER_WORKDIR$MOUNT_SUFFIX")

# Named volume (not a host bind mount) holding the native claude install.
# It persists across --rm containers, so an update applied by
# docker-entrypoint.sh carries forward from run to run instead of resetting
# to the version baked into the image every time.
MOUNT_ARGS+=(-v "claude-code-sandbox-volume:/home/node/.local")

# Mount each entry of ~/.claude individually (siblings), instead of the whole
# directory: Docker Desktop's virtiofs backend cannot mount a path from a
# different host source on top of a path already covered by another bind
# mount, so settings.json/.credentials.json can't be overlaid on a single
# whole-directory mount of ~/.claude.
if [ -d "$CLAUDE_DIR_SRC" ]; then
  shopt -s nullglob dotglob
  for entry in "$CLAUDE_DIR_SRC"/*; do
    name="$(basename "$entry")"
    case "$name" in
      settings.json | .credentials.json) continue ;;
    esac
    MOUNT_ARGS+=(-v "$entry:/home/node/.claude/$name")
  done
  shopt -u nullglob dotglob
else
  echo "Warning: $CLAUDE_DIR_SRC not found, container will start with an empty ~/.claude" >&2
fi

append_mount_if_file "$CLAUDE_DIR_SRC/settings.json" "/home/node/.claude/settings.json" "ro"
append_mount_if_file "$CREDS_TMP" "/home/node/.claude/.credentials.json" "ro"
append_mount_if_file "$HOME/.claude.json" "/home/node/.claude.json"

# Carry the host git identity and aliases into the container. A filtered copy
# is mounted rather than the original: credential helpers configured on the
# host (osxkeychain, libsecret) do not exist inside the image and would make
# any authenticating git command fail.
if [ -f "$HOME/.gitconfig" ]; then
  cp "$HOME/.gitconfig" "$GITCONFIG_TMP"
  git config --file "$GITCONFIG_TMP" --remove-section credential 2>/dev/null || true
  MOUNT_ARGS+=(-v "$GITCONFIG_TMP:/home/node/.gitconfig:ro")
fi

# Mount every hook script settings.json's "command" hooks point to (e.g. a
# corporate compliance hook like aim.security's), so the container is
# monitored the same way the host session is.
collect_hook_mounts "$CLAUDE_DIR_SRC/settings.json"
print_hook_mount_manifest

# Container-only overrides: injected as an extra settings layer via --settings,
# not written to any host/shared file, so they never affect native runs.
# CLI flags outrank ~/.claude/settings.json, so the statusLine path here wins
# over the host one. The script itself needs no dedicated mount — the loop
# above already maps every ~/.claude entry to /home/node/.claude/.
declare -a ANNOUNCEMENT_LINES=()
build_company_announcement
IFS=$'\n' COMPANY_ANNOUNCEMENT="${ANNOUNCEMENT_LINES[*]}"
unset IFS

CONTAINER_SETTINGS="$(jq -n \
  --arg announcement "$COMPANY_ANNOUNCEMENT" \
  '{
    companyAnnouncements: [$announcement],
    statusLine: {
      type: "command",
      command: "/home/node/.claude/customizations/custom-claude-code-settings/bin/statusline-command.sh"
    }
  }')"

# --user keeps files created in the project mount owned by the invoking user
# (which matters on Linux, where there is no UID remapping layer).
# --group-add 0 grants access to /home/node, whose contents are owned by
# node:0 with group permissions mirroring the owner's.
docker run -it --rm \
  --user "$(id -u):$(id -g)" \
  --group-add 0 \
  -e HOME=/home/node \
  "${MOUNT_ARGS[@]}" \
  -w "$CONTAINER_WORKDIR" \
  -e ANTHROPIC_API_KEY \
  -e ANTHROPIC_MODEL \
  -e HOST_CLAUDE_VERSION="$HOST_CLAUDE_VERSION" \
  "${TZ_ARGS[@]}" \
  "${CA_BUNDLE_ARGS[@]}" \
  "$SECURE_CLAUDE_IMAGE_NAME" \
  --settings "$CONTAINER_SETTINGS" \
  "$@"