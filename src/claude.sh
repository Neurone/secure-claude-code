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

# Creates the file with the given content unless it already exists. The
# content is written to a temp file and hard-linked into place: ln fails if
# the target exists, so concurrent wrappers can never truncate each other's
# file, and the first writer wins.
ensure_file_with_content() {
  local target_path="$1"
  local initial_content="$2"
  local temp_path

  [ -f "$target_path" ] && return 0

  mkdir -p "$(dirname "$target_path")"
  temp_path="$(mktemp "$target_path.XXXXXX")"
  printf '%s\n' "$initial_content" > "$temp_path"
  if ! ln "$temp_path" "$target_path" 2>/dev/null && [ ! -f "$target_path" ]; then
    rm -f "$temp_path"
    echo "Error: could not create $target_path" >&2
    return 1
  fi
  rm -f "$temp_path"
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

# Whether $CLAUDE_DIR_SRC/settings.json is bind-mounted read-only or writable
# when a native claude manages it (see resolve_settings_mount_mode below) is
# remembered here after the first answer, so the question is only ever asked
# once. Delete this file to be asked again on the next run.
SETTINGS_MOUNT_MODE_FILE="$SECURE_CLAUDE_HOME_DIR/settings-mount-mode"

# Decides whether the host's settings.json is mounted "ro" (default: the
# native claude stays the sole owner) or "rw" (lets changes made inside the
# container persist, at the cost of the container being able to modify
# settings the native claude also uses). A saved answer in
# $SETTINGS_MOUNT_MODE_FILE short-circuits the prompt entirely. Otherwise,
# only asked when stdin is a terminal: a non-interactive invocation (a
# script, CI, the test suite) must never block on a prompt, so it silently
# keeps the safe read-only default instead.
resolve_settings_mount_mode() {
  local saved_mode answer

  if [ -f "$SETTINGS_MOUNT_MODE_FILE" ]; then
    saved_mode="$(<"$SETTINGS_MOUNT_MODE_FILE")"
    case "$saved_mode" in
      ro | rw)
        printf '%s\n' "$saved_mode"
        return 0
        ;;
    esac
  fi

  if [ ! -t 0 ]; then
    printf 'ro\n'
    return 0
  fi

  echo "WARNING: a native claude install is managing $CLAUDE_DIR_SRC/settings.json." >&2
  echo "For this reason, it will be mounted read-only and changes to the settings made inside the container will be lost." >&2
  echo "" >&2
  read -r -p "Mount the settings file writable instead, so changes persist across restart? [y/N/always-yes/always-no]: " answer

  case "$answer" in
    always-yes)
      mkdir -p "$SECURE_CLAUDE_HOME_DIR"
      printf 'rw\n' > "$SETTINGS_MOUNT_MODE_FILE"
      echo "Saved: settings.json will be mounted writable from now on. Delete $SETTINGS_MOUNT_MODE_FILE to be asked again." >&2
      printf 'rw\n'
      ;;
    always-no)
      mkdir -p "$SECURE_CLAUDE_HOME_DIR"
      printf 'ro\n' > "$SETTINGS_MOUNT_MODE_FILE"
      echo "Saved: settings.json will be mounted read-only from now on. Delete $SETTINGS_MOUNT_MODE_FILE to be asked again." >&2
      printf 'ro\n'
      ;;
    [Yy] | [Yy][Ee][Ss])
      printf 'rw\n'
      ;;
    *)
      printf 'ro\n'
      ;;
  esac
}

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
  if host_version_output="$("$HOST_CLAUDE_PATH" --version 2>/dev/null)"; then
    HOST_CLAUDE_VERSION="${host_version_output%% *}"
  else
    echo "Warning: could not read the host claude version from $HOST_CLAUDE_PATH; the container will self-update instead" >&2
  fi
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
# Credentials seed. The container keeps its own login, persisted across runs
# on the claude-code-sandbox-claude-dir-volume backing /home/node/.claude
# (see docker-entrypoint.sh): it is a separate Anthropic session from the
# host's, so a token refresh or a fresh login done inside the container can
# actually be written back
# (the host Keychain/file has no such write-back path, since the container
# has no access to the macOS Keychain and any file mount is gone once the
# --rm container exits). This extraction only ever seeds that volume once,
# on its first-ever run when it's still empty; every run after that ignores
# it and relies solely on the container's own persisted credentials.
# macOS keeps host credentials in the login Keychain; Linux normally keeps
# them in ~/.claude/.credentials.json (unless a system keyring is in use, in
# which case there is nothing to seed from and the user logs in inside the
# container instead). A missing seed is not reported here: only the
# container's entrypoint knows whether its volume already holds a login.
# ---------------------------------------------------------------------------
case "$OS" in
  Darwin)
    if security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w >"$CREDS_TMP" 2>/dev/null; then
      chmod 600 "$CREDS_TMP"
    else
      rm -f "$CREDS_TMP"
    fi
    ;;
  *)
    if [ -f "$CLAUDE_DIR_SRC/.credentials.json" ]; then
      install -m 600 "$CLAUDE_DIR_SRC/.credentials.json" "$CREDS_TMP"
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

# Named volume backing /home/node/.claude itself, so that whatever Claude
# Code writes there directly (chiefly .credentials.json, via a
# temp-file-then-rename that must land on a real, persistent filesystem
# entry rather than through a symlink, see docker-entrypoint.sh) survives
# across --rm containers, independent of the host's own credentials. Host
# entries are still bind-mounted individually on top of it below, same as
# before; a named volume as the base is not the "different host source over
# an existing bind mount" case virtiofs rejects, since it's not a bind mount
# from the host at all.
MOUNT_ARGS+=(-v "claude-code-sandbox-claude-dir-volume:/home/node/.claude")

# Mount each entry of ~/.claude individually (siblings), instead of the whole
# directory: Docker Desktop's virtiofs backend cannot mount a path from a
# different host source on top of a path already covered by another bind
# mount, so settings.json/.credentials.json can't be overlaid on a single
# whole-directory bind mount of ~/.claude sourced from the host. (This is
# unrelated to the volume mount above, which is not a host bind mount.)
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

# A native claude owns the host settings.json, so by default the container
# only reads it (see resolve_settings_mount_mode). Without a native install
# nothing else manages it, and the container must be able to change settings
# itself: mount it writable (or, if there is none, leave the volume's own
# copy in charge).
#
# The "writable" case can NOT be a live bind mount of the host file straight
# onto /home/node/.claude/settings.json, even though that's what it sounds
# like: Claude Code saves settings via a temp-file-then-rename, the same
# atomic pattern noted for .credentials.json below, and rename(2) onto an
# active bind-mount point fails with EBUSY. That silently breaks every
# settings write that goes through that path (confirmed: model/effort
# selection does, simple flag toggles like autoCompactEnabled apparently
# don't, hence some settings "stick" from inside the container and some
# don't). So "writable" is handled exactly like the credentials seed below
# instead: the host file is mounted read-only at a side path and
# docker-entrypoint.sh copies it into the (volume-backed, not bind-mounted)
# settings.json the first time only, after which the container's own copy on
# the persistent .claude volume is authoritative and safely renameable. This
# means a container allowed to write settings.json diverges from the host's
# copy after that first seed, same as the independent login described above.
SETTINGS_MOUNT_MODE="ro"
if [ -z "$HOST_CLAUDE_PATH" ]; then
  SETTINGS_MOUNT_MODE=""
elif [ -f "$CLAUDE_DIR_SRC/settings.json" ]; then
  SETTINGS_MOUNT_MODE="$(resolve_settings_mount_mode)"
fi
if [ "$SETTINGS_MOUNT_MODE" = "rw" ]; then
  append_mount_if_file "$CLAUDE_DIR_SRC/settings.json" "/home/node/.claude-host-settings-seed.json" "ro"
else
  append_mount_if_file "$CLAUDE_DIR_SRC/settings.json" "/home/node/.claude/settings.json" "$SETTINGS_MOUNT_MODE"
fi
append_mount_if_file "$CREDS_TMP" "/home/node/.claude-host-credentials-seed.json" "ro"

# ~/.claude.json holds onboarding, theme and per-project state. Without a
# host copy it would live in the container's throwaway layer and be lost on
# every run, so a file kept in this tool's own directory stands in for it.
CLAUDE_JSON_SRC="$HOME/.claude.json"
if [ ! -f "$CLAUDE_JSON_SRC" ]; then
  CLAUDE_JSON_SRC="$SECURE_CLAUDE_HOME_DIR/claude.json"
  ensure_file_with_content "$CLAUDE_JSON_SRC" "{}"
fi
append_mount_if_file "$CLAUDE_JSON_SRC" "/home/node/.claude.json"

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

# Only set when the script exists on the host: it comes from a personal
# ~/.claude/customizations directory that a fresh host does not have.
STATUSLINE_SCRIPT_SUBPATH="customizations/custom-claude-code-settings/bin/statusline-command.sh"
STATUSLINE_COMMAND=""
if [ -f "$CLAUDE_DIR_SRC/$STATUSLINE_SCRIPT_SUBPATH" ]; then
  STATUSLINE_COMMAND="/home/node/.claude/$STATUSLINE_SCRIPT_SUBPATH"
fi

CONTAINER_SETTINGS="$(jq -n \
  --arg announcement "$COMPANY_ANNOUNCEMENT" \
  --arg statusline_command "$STATUSLINE_COMMAND" \
  '{ companyAnnouncements: [$announcement] }
   + (if $statusline_command == "" then {} else { statusLine: { type: "command", command: $statusline_command } } end)')"

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
  ${TZ_ARGS[@]+"${TZ_ARGS[@]}"} \
  ${CA_BUNDLE_ARGS[@]+"${CA_BUNDLE_ARGS[@]}"} \
  "$SECURE_CLAUDE_IMAGE_NAME" \
  --settings "$CONTAINER_SETTINGS" \
  "$@"