#!/usr/bin/env bash
# Installs the secure-claude-code sandbox wrapper so that 'claude' resolves to it.
#
# The native Claude Code install is left completely untouched, so its own
# auto-updater keeps working exactly as before. Instead, this creates a
# dedicated directory (~/.secure-claude-code/bin) containing:
#   - claude          -> src/claude.sh (the Docker sandbox wrapper)
#   - claude-original -> the native binary (whatever it currently resolves to)
# and prepends that directory to PATH via the shell startup files, so
# 'claude' always resolves to the sandbox wrapper first.
#
# Run restore.sh to undo this.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WRAPPER_SCRIPT="$SCRIPT_DIR/src/claude.sh"
PATH_UTILS="$SCRIPT_DIR/src/lib/path-utils.sh"
INSTALL_COMMON="$SCRIPT_DIR/src/lib/install-common.sh"
CONTAINER_DIR="$SCRIPT_DIR/src/container"
DOCKERFILE="$CONTAINER_DIR/Dockerfile.claude-code"

for lib in "$PATH_UTILS" "$INSTALL_COMMON"; do
  if [ ! -f "$lib" ]; then
    echo "Error: could not find required file at $lib" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$lib"
done

require_supported_os

if [ ! -f "$WRAPPER_SCRIPT" ]; then
  echo "Error: could not find wrapper script at $WRAPPER_SCRIPT" >&2
  exit 1
fi
chmod +x "$WRAPPER_SCRIPT"

if [ ! -f "$DOCKERFILE" ]; then
  echo "Error: could not find Dockerfile at $DOCKERFILE" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Warning: docker not found in PATH. The sandboxed 'claude' command requires Docker to run; install it before using claude." >&2
fi

SHIM_DIR="$SECURE_CLAUDE_SHIM_DIR"
SHIM_CLAUDE="$SHIM_DIR/claude"
SHIM_CLAUDE_ORIGINAL="$SHIM_DIR/claude-original"
WRAPPER_REAL="$(resolve_path "$WRAPPER_SCRIPT")"

SHIM_DIR_REAL="$SHIM_DIR"
if [ -d "$SHIM_DIR" ]; then
  SHIM_DIR_REAL="$(cd "$SHIM_DIR" && pwd -P)"
fi

# Already fully installed: report and exit without touching anything.
if [ -L "$SHIM_CLAUDE" ] && [ "$(resolve_path "$SHIM_CLAUDE")" = "$WRAPPER_REAL" ] \
   && [ -L "$SHIM_CLAUDE_ORIGINAL" ] && any_rc_has_path_block; then
  echo "Already installed:"
  echo "  $SHIM_CLAUDE -> $WRAPPER_SCRIPT"
  echo "  $SHIM_CLAUDE_ORIGINAL -> $(readlink "$SHIM_CLAUDE_ORIGINAL")"
  echo "PATH entry already present in shell startup files."
  rebuild_sandbox_image "$DOCKERFILE" "$CONTAINER_DIR"
  exit 0
fi

# Don't clobber anything at these two paths that we don't manage ourselves.
if [ -e "$SHIM_CLAUDE" ] && [ ! -L "$SHIM_CLAUDE" ]; then
  echo "Error: $SHIM_CLAUDE exists and is not a symlink managed by this installer. Inspect and remove it manually before re-running install.sh." >&2
  exit 1
fi
if [ -e "$SHIM_CLAUDE_ORIGINAL" ] && [ ! -L "$SHIM_CLAUDE_ORIGINAL" ]; then
  echo "Error: $SHIM_CLAUDE_ORIGINAL exists and is not a symlink managed by this installer. Inspect and remove it manually before re-running install.sh." >&2
  exit 1
fi

if ! NATIVE_CLAUDE_PATH="$(find_native_claude "$SHIM_DIR_REAL")"; then
  echo "Error: no native 'claude' command found in PATH (outside of $SHIM_DIR)." >&2
  echo "Install the native Claude Code CLI first, then re-run this script." >&2
  exit 1
fi

if ! mkdir -p "$SHIM_DIR" 2>/dev/null; then
  echo "Error: could not create $SHIM_DIR. Check permissions on $HOME." >&2
  exit 1
fi

echo "Found native claude at: $NATIVE_CLAUDE_PATH"

ln -sf "$NATIVE_CLAUDE_PATH" "$SHIM_CLAUDE_ORIGINAL"
echo "  -> linked: $SHIM_CLAUDE_ORIGINAL -> $NATIVE_CLAUDE_PATH"

ln -sf "$WRAPPER_SCRIPT" "$SHIM_CLAUDE"
echo "  -> linked: $SHIM_CLAUDE -> $WRAPPER_SCRIPT"

if [ "$(resolve_path "$SHIM_CLAUDE")" != "$WRAPPER_REAL" ]; then
  echo "Error: verification failed, '$SHIM_CLAUDE' does not resolve to $WRAPPER_SCRIPT after linking." >&2
  exit 1
fi

echo "Configuring PATH..."
configure_shell_path

rebuild_sandbox_image "$DOCKERFILE" "$CONTAINER_DIR"

cat <<EOF

Install complete. The native claude install at $NATIVE_CLAUDE_PATH is untouched,
so its own updates keep working normally.

  $SHIM_CLAUDE          -> $WRAPPER_SCRIPT (sandboxed, runs in Docker)
  $SHIM_CLAUDE_ORIGINAL -> $NATIVE_CLAUDE_PATH (native binary)

Start a new shell (or run 'source <rc file>' / 'export PATH="$SHIM_DIR:\$PATH"') for
'claude' to resolve to the sandbox wrapper in your current session.

Run '$SCRIPT_DIR/restore.sh' at any time to undo this.
EOF
