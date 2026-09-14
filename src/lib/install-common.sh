#!/usr/bin/env bash

# Shared helpers, constants, and shell-rc machinery for install.sh and
# restore.sh. claude.sh also sources this file, but only for
# SECURE_CLAUDE_IMAGE_NAME.
#
# Design: rather than replacing the native 'claude' in place, we keep it
# completely untouched (so Claude Code's own auto-updater is free to manage
# it however it likes) and instead put our own 'claude' symlink in a
# dedicated directory that we prepend to PATH. Because it comes first in
# PATH, it always wins over whatever the native install currently looks
# like, regardless of what the auto-updater does to it.

SECURE_CLAUDE_SHIM_DIR="$HOME/.secure-claude-code/bin"
SECURE_CLAUDE_IMAGE_NAME="claude-code-sandbox"

SECURE_CLAUDE_RC_FILES=(
  "$HOME/.zshrc"
  "$HOME/.bashrc"
  "$HOME/.bash_profile"
  "$HOME/.profile"
)

SECURE_CLAUDE_PATH_MARKER_START="# >>> secure-claude-code PATH (managed by install.sh, see restore.sh) >>>"
SECURE_CLAUDE_PATH_MARKER_END="# <<< secure-claude-code PATH <<<"

require_supported_os() {
  local os
  os="$(uname -s)"
  case "$os" in
    Darwin | Linux) ;;
    *)
      echo "Error: unsupported OS '$os' (only macOS and Linux are supported)" >&2
      return 1
      ;;
  esac
}

# Finds the first 'claude' executable on PATH, ignoring any entry that
# resolves to $1. Used to locate the native install while ignoring our own
# shim directory (which may itself already be on PATH from a previous run).
find_native_claude() {
  local exclude_dir="$1"
  local old_ifs="$IFS"
  local -a path_dirs
  IFS=':' read -r -a path_dirs <<< "$PATH"
  IFS="$old_ifs"

  local dir resolved_dir
  for dir in "${path_dirs[@]}"; do
    [ -n "$dir" ] || continue
    resolved_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || continue
    [ "$resolved_dir" = "$exclude_dir" ] && continue
    if [ -f "$dir/claude" ] && [ -x "$dir/claude" ]; then
      printf '%s\n' "$dir/claude"
      return 0
    fi
  done
  return 1
}

path_block_present() {
  local rc_file="$1"
  [ -f "$rc_file" ] && grep -qF "$SECURE_CLAUDE_PATH_MARKER_START" "$rc_file"
}

any_rc_has_path_block() {
  local rc_file
  for rc_file in "${SECURE_CLAUDE_RC_FILES[@]}"; do
    path_block_present "$rc_file" && return 0
  done
  return 1
}

add_path_block_to_rc_file() {
  local rc_file="$1"
  {
    echo ""
    echo "$SECURE_CLAUDE_PATH_MARKER_START"
    # shellcheck disable=SC2016 # '$PATH' must stay literal, expanded on shell startup, not now
    printf 'export PATH="%s:$PATH"\n' "$SECURE_CLAUDE_SHIM_DIR"
    echo "$SECURE_CLAUDE_PATH_MARKER_END"
  } >> "$rc_file"
}

remove_path_block_from_rc_file() {
  local rc_file="$1"
  local tmp_file
  tmp_file="$(mktemp "${rc_file}.secure-claude-code.XXXXXX")"
  awk -v start="$SECURE_CLAUDE_PATH_MARKER_START" -v end="$SECURE_CLAUDE_PATH_MARKER_END" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    skip != 1 { print }
  ' "$rc_file" > "$tmp_file"
  mv "$tmp_file" "$rc_file"
}

# Adds the PATH block to every existing candidate rc file, or, if none of
# them exist yet, creates the one matching $SHELL. No-op if the block is
# already present anywhere (idempotent).
configure_shell_path() {
  if any_rc_has_path_block; then
    echo "  PATH entry already present in shell startup files."
    return 0
  fi

  local rc_file touched=0
  for rc_file in "${SECURE_CLAUDE_RC_FILES[@]}"; do
    [ -f "$rc_file" ] || continue
    add_path_block_to_rc_file "$rc_file"
    echo "  -> added PATH entry to: $rc_file"
    touched=1
  done

  if [ "$touched" -eq 0 ]; then
    local default_rc
    case "$(basename "${SHELL:-}")" in
      zsh) default_rc="$HOME/.zshrc" ;;
      bash) default_rc="$HOME/.bash_profile" ;;
      *) default_rc="$HOME/.profile" ;;
    esac
    add_path_block_to_rc_file "$default_rc"
    echo "  -> created and updated: $default_rc"
  fi
}

# Removes the PATH block from every rc file that has it. No-op if absent.
deconfigure_shell_path() {
  local rc_file found=0
  for rc_file in "${SECURE_CLAUDE_RC_FILES[@]}"; do
    if path_block_present "$rc_file"; then
      remove_path_block_from_rc_file "$rc_file"
      echo "  -> removed PATH entry from: $rc_file"
      found=1
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "  No PATH entry found in shell startup files."
  fi
}

# Rebuilds the sandbox image unconditionally, so a Dockerfile edit made since
# the last install is picked up without a manual 'docker build'. claude.sh,
# by contrast, only builds the image when it doesn't exist at all (see its
# own comment), so this is the supported way to apply a Dockerfile change.
# No-op if Docker isn't installed; install.sh already warns about that
# separately.
rebuild_sandbox_image() {
  local dockerfile="$1"
  local build_context="$2"

  command -v docker >/dev/null 2>&1 || return 0

  echo "Rebuilding $SECURE_CLAUDE_IMAGE_NAME..." >&2
  docker build -t "$SECURE_CLAUDE_IMAGE_NAME" -f "$dockerfile" "$build_context"
}
