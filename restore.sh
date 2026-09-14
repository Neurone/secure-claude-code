#!/usr/bin/env bash
# Reverts the changes made by install.sh: removes the ~/.secure-claude-code/bin
# shims and the PATH entry from the shell startup files. The native claude
# install was never touched by install.sh, so there is nothing to restore
# there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WRAPPER_SCRIPT="$SCRIPT_DIR/src/claude.sh"
PATH_UTILS="$SCRIPT_DIR/src/lib/path-utils.sh"
INSTALL_COMMON="$SCRIPT_DIR/src/lib/install-common.sh"

for lib in "$PATH_UTILS" "$INSTALL_COMMON"; do
  if [ ! -f "$lib" ]; then
    echo "Error: could not find required file at $lib" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$lib"
done

require_supported_os

SHIM_DIR="$SECURE_CLAUDE_SHIM_DIR"
SHIM_CLAUDE="$SHIM_DIR/claude"
SHIM_CLAUDE_ORIGINAL="$SHIM_DIR/claude-original"
WRAPPER_REAL="$(resolve_path "$WRAPPER_SCRIPT")"

if [ ! -L "$SHIM_CLAUDE" ] || [ "$(resolve_path "$SHIM_CLAUDE")" != "$WRAPPER_REAL" ]; then
  echo "Error: $SHIM_CLAUDE does not point to the secure-claude-code wrapper ($WRAPPER_SCRIPT)." >&2
  echo "Nothing to restore." >&2
  exit 1
fi

rm -f "$SHIM_CLAUDE"
echo "Removed: $SHIM_CLAUDE"

if [ -e "$SHIM_CLAUDE_ORIGINAL" ]; then
  rm -f "$SHIM_CLAUDE_ORIGINAL"
  echo "Removed: $SHIM_CLAUDE_ORIGINAL"
fi

if [ -d "$SHIM_DIR" ] && [ -z "$(ls -A "$SHIM_DIR")" ]; then
  rmdir "$SHIM_DIR"
  echo "Removed empty directory: $SHIM_DIR"

  SHIM_PARENT_DIR="$(dirname "$SHIM_DIR")"
  if [ -d "$SHIM_PARENT_DIR" ] && [ -z "$(ls -A "$SHIM_PARENT_DIR")" ]; then
    rmdir "$SHIM_PARENT_DIR"
    echo "Removed empty directory: $SHIM_PARENT_DIR"
  fi
fi

echo "Removing PATH entry..."
deconfigure_shell_path

cat <<EOF

Restore complete. The native claude install was never modified. Start a new
shell (or re-source your shell startup files) for 'claude' to resolve to it
again.
EOF
