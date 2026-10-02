#!/usr/bin/env bash
# Integration tests for src/claude.sh (the Docker sandbox wrapper), install.sh,
# restore.sh and src/container/docker-entrypoint.sh, driven with fake `docker`,
# `security` and `uname` executables so no real Docker daemon, macOS keychain
# or installed claude is needed.
#
# Usage: bash tests/test-claude-wrapper.sh
#
# The fake tools are controlled via env vars (documented where they are
# written below). Each scenario gets its own record directory holding the
# args the fake docker saw, plus the script's stdout/stderr.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WRAPPER="$REPO_DIR/src/claude.sh"
INSTALL_SH="$REPO_DIR/install.sh"
RESTORE_SH="$REPO_DIR/restore.sh"
REAL_UNAME="$(command -v uname)"

# PATH with every directory that has its own 'claude' or 'claude-original'
# executable stripped out, so the "no native claude" scenarios are not
# accidentally satisfied by a real install (or a previous install.sh run) on
# the host running these tests.
PATH_WITHOUT_CLAUDE="$(
  IFS=':'
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    [ -x "$dir/claude" ] && continue
    [ -x "$dir/claude-original" ] && continue
    printf '%s:' "$dir"
  done
)"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required to run these tests (it is also a wrapper requirement)." >&2
  exit 1
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

FAILURES=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# Assert an exact line exists in a file.
has_line() {
  if grep -Fxq -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 (missing line: $2)"; fi
}
# Assert an exact line does NOT exist in a file.
has_no_line() {
  if grep -Fxq -- "$2" "$1" 2>/dev/null; then fail "$3 (unexpected line: $2)"; else pass "$3"; fi
}
# Assert at least one line matches an extended regex.
has_pattern() {
  if grep -Eq -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 (no match for: $2)"; fi
}
# Assert no line matches an extended regex.
has_no_pattern() {
  if grep -Eq -- "$2" "$1" 2>/dev/null; then fail "$3 (unexpected match: $2)"; else pass "$3"; fi
}
# Assert an exact line occurs exactly once.
occurs_once() {
  local n
  n="$(grep -Fxc -- "$2" "$1" 2>/dev/null || true)"
  if [ "$n" = "1" ]; then pass "$3"; else fail "$3 (expected exactly 1 occurrence, got ${n:-0})"; fi
}
# Assert a file's (entire) content equals a string.
content_is() {
  local actual
  actual="$(cat "$1" 2>/dev/null || echo __missing__)"
  if [ "$actual" = "$2" ]; then pass "$3"; else fail "$3 (content: '$actual', expected '$2')"; fi
}
# Assert the last exit code ($1) equals the expected one ($2).
exit_code_is() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (exit code $1, expected $2)"; fi
}
# Assert a path exists (symlinks count, even dangling ones).
path_exists() {
  if [ -e "$1" ] || [ -L "$1" ]; then pass "$2"; else fail "$2 (missing: $1)"; fi
}
# Assert a path does not exist (symlinks count, even dangling ones).
path_absent() {
  if [ -e "$1" ] || [ -L "$1" ]; then fail "$2 (unexpected: $1)"; else pass "$2"; fi
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

mkdir -p \
  "$T/bin" \
  "$T/native" \
  "$T/hooks" \
  "$T/project" \
  "$T/record"

# A host that has Claude Code configured: ~/.claude with entries, a
# settings.json declaring a hook, ~/.claude.json and a ~/.gitconfig.
CONFIGURED_HOME="$T/home-configured"
mkdir -p "$CONFIGURED_HOME/.claude/agents"
printf '#!/bin/sh\nexit 0\n' > "$T/hooks/compliance.sh"
chmod +x "$T/hooks/compliance.sh"
cat > "$CONFIGURED_HOME/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "$T/hooks/compliance.sh" } ] }
    ]
  }
}
EOF
echo "# memory" > "$CONFIGURED_HOME/.claude/CLAUDE.md"
echo '{"theme":"dark"}' > "$CONFIGURED_HOME/.claude.json"
cat > "$CONFIGURED_HOME/.gitconfig" <<EOF
[user]
	name = Test User
[credential]
	helper = osxkeychain
EOF

# A host with no Claude Code state at all.
BARE_HOME="$T/home-bare"
mkdir -p "$BARE_HOME"

# --- fake docker -----------------------------------------------------------
# Env:
#   FAKE_DOCKER_RECORD  record dir (required)
#   FAKE_IMAGE_STATE    "present" (default) or "absent" for `image inspect`
# `run` writes one line per argument to run.args, merging `-v X` and `-e Y`
# pairs, and saves the value given to --settings in settings.arg.
cat > "$T/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  image)
    if [ "${2:-}" != "inspect" ]; then
      echo "fake docker: unhandled: $*" >&2
      exit 1
    fi
    if [ "${FAKE_IMAGE_STATE:-present}" = "present" ]; then
      exit 0
    fi
    echo "Error: No such image: claude-code-sandbox" >&2
    exit 1
    ;;
  build)
    printf '%s\n' "$@" >> "${FAKE_DOCKER_RECORD:?}/build.args"
    exit 0
    ;;
  run)
    {
      prev=""
      expecting_settings=0
      for arg in "$@"; do
        if [ "$expecting_settings" = 1 ]; then
          printf '%s' "$arg" > "${FAKE_DOCKER_RECORD:?}/settings.arg"
          expecting_settings=0
          continue
        fi
        if [ "$arg" = "--settings" ]; then
          expecting_settings=1
          continue
        fi
        if [ -n "$prev" ]; then
          if [ "$prev" = "-v" ] || [ "$prev" = "-e" ]; then
            printf '%s\n' "$prev $arg"
            prev=""
          else
            printf '%s\n' "$prev"
            prev="$arg"
          fi
        else
          prev="$arg"
        fi
      done
      [ -n "$prev" ] && printf '%s\n' "$prev"
    } > "${FAKE_DOCKER_RECORD:?}/run.args"
    exit 0
    ;;
  *)
    echo "fake docker: unhandled: $*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$T/bin/docker"

# --- fake security (macOS keychain) ------------------------------------------
# Env:
#   FAKE_KEYCHAIN_CREDS  credentials JSON to return; empty means "not found"
#   FAKE_CERTS_FAIL      "1" to make the certificate export fail
cat > "$T/bin/security" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  find-generic-password)
    if [ -n "${FAKE_KEYCHAIN_CREDS:-}" ]; then
      printf '%s\n' "$FAKE_KEYCHAIN_CREDS"
      exit 0
    fi
    exit 44
    ;;
  find-certificate)
    [ "${FAKE_CERTS_FAIL:-0}" = "1" ] && exit 1
    printf -- '-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n'
    exit 0
    ;;
  *)
    echo "fake security: unhandled: $*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$T/bin/security"

# --- fake uname ----------------------------------------------------------------
# Always reports Darwin for `uname -s` so the keychain and CA-bundle branches
# (served by the fake `security`) run identically on any host running the tests.
cat > "$T/bin/uname" <<FAKE
#!/usr/bin/env bash
if [ "\${1:-}" = "-s" ]; then echo Darwin; else exec "$REAL_UNAME" "\$@"; fi
FAKE
chmod +x "$T/bin/uname"

# --- fake native claude (for host-version and install.sh tests) ----------------
write_fake_native_claude() {
  local path="$1" body="$2"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$path"
  chmod +x "$path"
}
write_fake_native_claude "$T/native/claude" 'echo "2.1.0 (Claude Code)"'

# ---------------------------------------------------------------------------
# Run helpers
# ---------------------------------------------------------------------------

# run_wrapper <record-dir> <home-dir> <extra-path-dir-or-empty> [wrapper args...]
# Runs the wrapper from the fixture project dir with a controlled environment.
# FAKE_* env vars set by the caller are forwarded.
run_wrapper() {
  local record="$1" home_dir="$2" extra_path="$3"
  shift 3
  mkdir -p "$record"
  rm -f "$record"/run.args "$record"/build.args "$record"/settings.arg \
        "$record"/stdout.txt "$record"/stderr.txt
  (
    cd "$T/project" || exit 99
    env HOME="$home_dir" \
        SHELL=/bin/zsh \
        TZ=Europe/Rome \
        FAKE_DOCKER_RECORD="$record" \
        PATH="$T/bin:${extra_path:+$extra_path:}$PATH_WITHOUT_CLAUDE" \
        bash "$WRAPPER" "$@" >"$record/stdout.txt" 2>"$record/stderr.txt" </dev/null
  )
}

# run_install <record-dir> <home-dir> <extra-path-dir-or-empty>
run_install() {
  local record="$1" home_dir="$2" extra_path="$3"
  mkdir -p "$record" "$home_dir"
  rm -f "$record"/build.args "$record"/stdout.txt "$record"/stderr.txt
  env HOME="$home_dir" \
      SHELL=/bin/zsh \
      FAKE_DOCKER_RECORD="$record" \
      PATH="$T/bin:${extra_path:+$extra_path:}$PATH_WITHOUT_CLAUDE" \
      bash "$INSTALL_SH" >"$record/stdout.txt" 2>"$record/stderr.txt"
}

# run_restore <record-dir> <home-dir>
run_restore() {
  local record="$1" home_dir="$2"
  mkdir -p "$record" "$home_dir"
  env HOME="$home_dir" \
      SHELL=/bin/zsh \
      PATH="$T/bin:$PATH_WITHOUT_CLAUDE" \
      bash "$RESTORE_SH" >"$record/stdout.txt" 2>"$record/stderr.txt"
}

# ---------------------------------------------------------------------------
# W1: no native claude, nothing configured on the host
# ---------------------------------------------------------------------------
echo "=== W1: no native claude, bare host ==="
REC="$T/record/w1"
run_wrapper "$REC" "$BARE_HOME" ""
rc=$?
exit_code_is "$rc" 0 "wrapper succeeds"
path_absent "$REC/build.args" "no image build (image present)"
has_line "$REC/run.args" "-v claude-code-sandbox-volume:/home/node/.local" "binary volume mounted"
has_line "$REC/run.args" "-v claude-code-sandbox-claude-dir-volume:/home/node/.claude" ".claude volume mounted"
has_line "$REC/run.args" "-e HOST_CLAUDE_VERSION=" "no host version passed"
has_no_pattern "$REC/run.args" '^-v .*:/home/node/\.claude/' "no ~/.claude entry mounted"
has_no_pattern "$REC/run.args" ':/home/node/\.gitconfig' "no gitconfig mounted"
has_line "$REC/run.args" "-e TZ=Europe/Rome" "TZ forwarded"
has_line "$REC/run.args" "claude-code-sandbox" "image reference"

# ---------------------------------------------------------------------------
# W2: native claude present -> its version is passed to the container
# ---------------------------------------------------------------------------
echo "=== W2: native claude present ==="
REC="$T/record/w2"
run_wrapper "$REC" "$CONFIGURED_HOME" "$T/native"
rc=$?
exit_code_is "$rc" 0 "wrapper succeeds"
has_line "$REC/run.args" "-e HOST_CLAUDE_VERSION=2.1.0" "host version passed"

# ---------------------------------------------------------------------------
# W3: image build only when the image is absent
# ---------------------------------------------------------------------------
echo "=== W3: image absent -> build ==="
REC="$T/record/w3"
FAKE_IMAGE_STATE=absent run_wrapper "$REC" "$BARE_HOME" ""
rc=$?
exit_code_is "$rc" 0 "wrapper succeeds"
has_pattern "$REC/build.args" 'claude-code-sandbox' "image built under the sandbox name"
path_exists "$REC/run.args" "container run proceeded"

# ---------------------------------------------------------------------------
# W4: credentials seed mounted only when the keychain has credentials
# ---------------------------------------------------------------------------
echo "=== W4: credentials seed ==="
REC="$T/record/w4a"
FAKE_KEYCHAIN_CREDS='{"claudeAiOauth":{}}' run_wrapper "$REC" "$BARE_HOME" ""
has_pattern "$REC/run.args" '^-v /[^:]+:/home/node/\.claude-host-credentials-seed\.json:ro$' "seed mounted read-only when credentials exist"
REC="$T/record/w4b"
FAKE_KEYCHAIN_CREDS= run_wrapper "$REC" "$BARE_HOME" ""
has_no_pattern "$REC/run.args" 'claude-host-credentials-seed' "no seed mount without credentials"
has_no_pattern "$REC/stderr.txt" 'credentials' "no per-run credentials warning (the container keeps its own login)"

# ---------------------------------------------------------------------------
# W5: configured host -> per-entry mounts, settings read-only, hooks mounted
# ---------------------------------------------------------------------------
echo "=== W5: configured host ==="
REC="$T/record/w5"
run_wrapper "$REC" "$CONFIGURED_HOME" "$T/native"
rc=$?
exit_code_is "$rc" 0 "wrapper succeeds"
has_line "$REC/run.args" "-v $CONFIGURED_HOME/.claude/agents:/home/node/.claude/agents" "~/.claude/agents mounted"
has_line "$REC/run.args" "-v $CONFIGURED_HOME/.claude/CLAUDE.md:/home/node/.claude/CLAUDE.md" "~/.claude/CLAUDE.md mounted"
has_line "$REC/run.args" "-v $CONFIGURED_HOME/.claude/settings.json:/home/node/.claude/settings.json:ro" "settings.json read-only with a native claude"
has_line "$REC/run.args" "-v $CONFIGURED_HOME/.claude.json:/home/node/.claude.json" "~/.claude.json mounted"
has_line "$REC/run.args" "-v $T/hooks/compliance.sh:$T/hooks/compliance.sh:ro" "hook script mounted read-only"
has_pattern "$REC/run.args" '^-v /[^:]+:/home/node/\.gitconfig:ro$' "filtered gitconfig mounted read-only"
if jq -e --arg hook "$T/hooks/compliance.sh" '.companyAnnouncements[0] | contains($hook)' "$REC/settings.arg" >/dev/null 2>&1; then
  pass "announcement lists the mounted hook"
else
  fail "announcement lists the mounted hook"
fi

# ---------------------------------------------------------------------------
# W6: a native claude whose --version fails must not break the wrapper
# ---------------------------------------------------------------------------
echo "=== W6: native claude with a failing --version ==="
BROKEN_NATIVE="$T/native-broken"
mkdir -p "$BROKEN_NATIVE"
write_fake_native_claude "$BROKEN_NATIVE/claude" 'echo "boom" >&2; exit 1'
REC="$T/record/w6"
run_wrapper "$REC" "$BARE_HOME" "$BROKEN_NATIVE"
rc=$?
exit_code_is "$rc" 0 "wrapper still succeeds"
has_line "$REC/run.args" "-e HOST_CLAUDE_VERSION=" "version left empty so the container self-updates"
has_pattern "$REC/stderr.txt" 'could not read the host claude version' "failure is reported on stderr"

# ---------------------------------------------------------------------------
# W7: no CA bundle exported -> empty arg arrays must not trip `set -u`
# (bash 3.2, the macOS default, rejects expanding an empty array)
# ---------------------------------------------------------------------------
echo "=== W7: CA export fails ==="
REC="$T/record/w7"
FAKE_CERTS_FAIL=1 run_wrapper "$REC" "$BARE_HOME" ""
rc=$?
exit_code_is "$rc" 0 "wrapper still succeeds"
path_exists "$REC/run.args" "container run proceeded"
has_no_pattern "$REC/run.args" 'ca-certificates\.crt' "no CA bundle mount"

# ---------------------------------------------------------------------------
# W8: the status line is only configured when its script exists on the host
# ---------------------------------------------------------------------------
echo "=== W8: status line ==="
STATUSLINE_HOME="$T/home-statusline"
STATUSLINE_DIR="$STATUSLINE_HOME/.claude/customizations/custom-claude-code-settings/bin"
mkdir -p "$STATUSLINE_DIR"
printf '#!/bin/sh\necho status\n' > "$STATUSLINE_DIR/statusline-command.sh"
chmod +x "$STATUSLINE_DIR/statusline-command.sh"
REC="$T/record/w8a"
run_wrapper "$REC" "$STATUSLINE_HOME" ""
if jq -e '.statusLine.command == "/home/node/.claude/customizations/custom-claude-code-settings/bin/statusline-command.sh"' "$REC/settings.arg" >/dev/null 2>&1; then
  pass "statusLine configured when the script exists"
else
  fail "statusLine configured when the script exists"
fi
REC="$T/record/w8b"
run_wrapper "$REC" "$BARE_HOME" ""
if jq -e 'has("statusLine") | not' "$REC/settings.arg" >/dev/null 2>&1; then
  pass "no statusLine when the script is absent"
else
  fail "no statusLine when the script is absent"
fi
if jq -e '.companyAnnouncements | length == 1' "$REC/settings.arg" >/dev/null 2>&1; then
  pass "announcement still present"
else
  fail "announcement still present"
fi

# ---------------------------------------------------------------------------
# W9: settings.json is read-only only when a native claude manages it;
# without one it must be editable from the container
# ---------------------------------------------------------------------------
echo "=== W9: settings.json mount mode ==="
REC="$T/record/w9a"
run_wrapper "$REC" "$CONFIGURED_HOME" ""
has_line "$REC/run.args" "-v $CONFIGURED_HOME/.claude/settings.json:/home/node/.claude/settings.json" "no native claude: host settings.json mounted read-write"
has_no_line "$REC/run.args" "-v $CONFIGURED_HOME/.claude/settings.json:/home/node/.claude/settings.json:ro" "no native claude: settings.json not read-only"
REC="$T/record/w9b"
run_wrapper "$REC" "$BARE_HOME" ""
has_no_pattern "$REC/run.args" 'settings\.json' "no native claude, no host settings.json: nothing mounted (the volume's copy is writable)"

# ---------------------------------------------------------------------------
# W10: ~/.claude.json persists even when the host has none
# ---------------------------------------------------------------------------
echo "=== W10: ~/.claude.json fallback ==="
FRESH_HOME="$T/home-fresh"
mkdir -p "$FRESH_HOME"
FALLBACK_CLAUDE_JSON="$FRESH_HOME/.secure-claude-code/claude.json"
REC="$T/record/w10a"
run_wrapper "$REC" "$FRESH_HOME" ""
rc=$?
exit_code_is "$rc" 0 "wrapper succeeds"
content_is "$FALLBACK_CLAUDE_JSON" "{}" "fallback file created with an empty JSON object"
has_line "$REC/run.args" "-v $FALLBACK_CLAUDE_JSON:/home/node/.claude.json" "fallback file mounted as ~/.claude.json"
echo '{"theme":"dark"}' > "$FALLBACK_CLAUDE_JSON"
REC="$T/record/w10b"
run_wrapper "$REC" "$FRESH_HOME" ""
content_is "$FALLBACK_CLAUDE_JSON" '{"theme":"dark"}' "second run keeps the saved state"
REC="$T/record/w10c"
run_wrapper "$REC" "$CONFIGURED_HOME" ""
has_line "$REC/run.args" "-v $CONFIGURED_HOME/.claude.json:/home/node/.claude.json" "host ~/.claude.json wins when present"
path_absent "$CONFIGURED_HOME/.secure-claude-code" "no fallback created when the host file exists"

# ---------------------------------------------------------------------------
# W11: wrappers started together must not clobber the fallback file
# ---------------------------------------------------------------------------
echo "=== W11: concurrent wrappers share one fallback file ==="
RACE_HOME="$T/home-race"
mkdir -p "$RACE_HOME"
run_wrapper "$T/record/w11a" "$RACE_HOME" "" &
run_wrapper "$T/record/w11b" "$RACE_HOME" "" &
run_wrapper "$T/record/w11c" "$RACE_HOME" "" &
wait
content_is "$RACE_HOME/.secure-claude-code/claude.json" "{}" "single valid fallback file"
LEFTOVER_COUNT="$(find "$RACE_HOME/.secure-claude-code" -type f | wc -l | tr -d ' ')"
if [ "$LEFTOVER_COUNT" = "1" ]; then pass "no temp files left behind"; else fail "no temp files left behind (found $LEFTOVER_COUNT files)"; fi
for run in w11a w11b w11c; do
  path_exists "$T/record/$run/run.args" "$run reached docker run"
done

# ---------------------------------------------------------------------------
# W12: settings.json mount mode is remembered via SETTINGS_MOUNT_MODE_FILE,
# and a non-interactive run (stdin not a terminal, as above) never prompts
# and never writes a preference by itself.
# ---------------------------------------------------------------------------
echo "=== W12: settings-mount-mode preference ==="
PREF_HOME="$T/home-pref"
mkdir -p "$PREF_HOME/.claude"
cp "$CONFIGURED_HOME/.claude/settings.json" "$PREF_HOME/.claude/settings.json"
PREF_FILE="$PREF_HOME/.secure-claude-code/settings-mount-mode"

REC="$T/record/w12a"
run_wrapper "$REC" "$PREF_HOME" "$T/native"
has_line "$REC/run.args" "-v $PREF_HOME/.claude/settings.json:/home/node/.claude/settings.json:ro" "no saved preference: still defaults to read-only"
path_absent "$PREF_FILE" "no preference file written by a non-interactive run"

mkdir -p "$PREF_HOME/.secure-claude-code"
printf 'rw\n' > "$PREF_FILE"
REC="$T/record/w12b"
run_wrapper "$REC" "$PREF_HOME" "$T/native"
has_line "$REC/run.args" "-v $PREF_HOME/.claude/settings.json:/home/node/.claude-host-settings-seed.json:ro" "saved 'rw' preference: host file mounted read-only at the seed path"
has_no_pattern "$REC/run.args" "/home/node/\.claude/settings\.json" "saved 'rw' preference: not bind-mounted directly onto settings.json (EBUSY on rename otherwise)"

printf 'ro\n' > "$PREF_FILE"
REC="$T/record/w12c"
run_wrapper "$REC" "$PREF_HOME" "$T/native"
has_line "$REC/run.args" "-v $PREF_HOME/.claude/settings.json:/home/node/.claude/settings.json:ro" "saved 'ro' preference: still mounted read-only"

# ---------------------------------------------------------------------------
# I1-I3: install.sh
# ---------------------------------------------------------------------------
echo "=== I1: install without a native claude ==="
REC="$T/record/i1"
INSTALL_HOME="$T/home-install-none"
run_install "$REC" "$INSTALL_HOME" ""
rc=$?
exit_code_is "$rc" 0 "install succeeds"
if [ -L "$INSTALL_HOME/.secure-claude-code/bin/claude" ] \
   && [ "$(readlink "$INSTALL_HOME/.secure-claude-code/bin/claude")" = "$WRAPPER" ]; then
  pass "claude shim points at the wrapper"
else
  fail "claude shim points at the wrapper"
fi
path_absent "$INSTALL_HOME/.secure-claude-code/bin/claude-original" "no claude-original shim"
has_pattern "$INSTALL_HOME/.zshrc" 'secure-claude-code PATH' "PATH block added to .zshrc"
path_exists "$REC/build.args" "image built"

echo "=== I2: install with a native claude ==="
REC="$T/record/i2"
INSTALL_HOME_NATIVE="$T/home-install-native"
run_install "$REC" "$INSTALL_HOME_NATIVE" "$T/native"
rc=$?
exit_code_is "$rc" 0 "install succeeds"
if [ "$(readlink "$INSTALL_HOME_NATIVE/.secure-claude-code/bin/claude-original")" = "$T/native/claude" ]; then
  pass "claude-original points at the native claude"
else
  fail "claude-original points at the native claude"
fi
path_exists "$INSTALL_HOME_NATIVE/.secure-claude-code/bin/claude" "claude shim present"

echo "=== I3: re-running install is idempotent ==="
REC="$T/record/i3"
run_install "$REC" "$INSTALL_HOME" ""
rc=$?
exit_code_is "$rc" 0 "re-install succeeds"
has_pattern "$REC/stdout.txt" 'Already installed' "reports already installed"
occurs_once "$INSTALL_HOME/.zshrc" "# >>> secure-claude-code PATH (managed by install.sh, see restore.sh) >>>" "PATH block not duplicated"

# ---------------------------------------------------------------------------
# R1-R2: restore.sh
# ---------------------------------------------------------------------------
echo "=== R1: restore after install ==="
REC="$T/record/r1"
run_restore "$REC" "$INSTALL_HOME"
rc=$?
exit_code_is "$rc" 0 "restore succeeds"
path_absent "$INSTALL_HOME/.secure-claude-code" "shim directories removed"
has_no_pattern "$INSTALL_HOME/.zshrc" 'secure-claude-code PATH' "PATH block removed"

echo "=== R3: restore removes a dangling claude-original ==="
REC="$T/record/r3"
DANGLING_HOME="$T/home-dangling"
DANGLING_NATIVE="$T/native-dangling"
mkdir -p "$DANGLING_NATIVE"
write_fake_native_claude "$DANGLING_NATIVE/claude" 'echo "2.1.0 (Claude Code)"'
run_install "$REC" "$DANGLING_HOME" "$DANGLING_NATIVE"
rm -f "$DANGLING_NATIVE/claude"
run_restore "$REC" "$DANGLING_HOME"
rc=$?
exit_code_is "$rc" 0 "restore succeeds"
path_absent "$DANGLING_HOME/.secure-claude-code" "shim directories removed, including the dangling symlink"

echo "=== R4: restore keeps the saved Claude Code state ==="
REC="$T/record/r4"
KEEP_HOME="$T/home-keep"
run_install "$REC" "$KEEP_HOME" ""
run_wrapper "$REC" "$KEEP_HOME" ""
run_restore "$REC" "$KEEP_HOME"
rc=$?
exit_code_is "$rc" 0 "restore succeeds"
content_is "$KEEP_HOME/.secure-claude-code/claude.json" "{}" "claude.json left in place"
path_absent "$KEEP_HOME/.secure-claude-code/bin" "shim directory removed"
has_pattern "$REC/stdout.txt" 'claude\.json' "restore says the file was kept"

echo "=== R5: restore keeps the saved settings-mount-mode preference ==="
REC="$T/record/r5"
MOUNT_MODE_HOME="$T/home-mount-mode"
run_install "$REC" "$MOUNT_MODE_HOME" ""
mkdir -p "$MOUNT_MODE_HOME/.secure-claude-code"
printf 'rw\n' > "$MOUNT_MODE_HOME/.secure-claude-code/settings-mount-mode"
run_restore "$REC" "$MOUNT_MODE_HOME"
rc=$?
exit_code_is "$rc" 0 "restore succeeds"
content_is "$MOUNT_MODE_HOME/.secure-claude-code/settings-mount-mode" "rw" "settings-mount-mode left in place"
has_pattern "$REC/stdout.txt" 'settings-mount-mode' "restore says the preference file was kept"

echo "=== R2: restore without an install ==="
REC="$T/record/r2"
run_restore "$REC" "$T/home-restore-none"
rc=$?
exit_code_is "$rc" 1 "restore refuses"
has_pattern "$REC/stderr.txt" 'Nothing to restore' "explains there is nothing to restore"

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# E1: docker-entrypoint.sh (credentials seed, login hint, version sync)
# ---------------------------------------------------------------------------
# Runs the entrypoint with HOME pointing at a fixture dir and a fake `claude`
# that records what it is asked to do.
ENTRYPOINT="$REPO_DIR/src/container/docker-entrypoint.sh"
mkdir -p "$T/entrypoint-bin"
cat > "$T/entrypoint-bin/claude" <<'FAKE'
#!/usr/bin/env bash
# Env: FAKE_CLAUDE_VERSION (version reported), FAKE_CLAUDE_CALLS (call log file)
case "${1:-}" in
  --version) echo "${FAKE_CLAUDE_VERSION:?} (Claude Code)" ;;
  update) echo "update" >> "${FAKE_CLAUDE_CALLS:?}" ;;
  *) echo "run $*" >> "${FAKE_CLAUDE_CALLS:?}" ;;
esac
FAKE
chmod +x "$T/entrypoint-bin/claude"

# run_entrypoint <record-dir> <home-dir> <container-version> <host-version-or-empty> [claude args...]
run_entrypoint() {
  local record="$1" home_dir="$2" container_version="$3" host_version="$4"
  shift 4
  mkdir -p "$record" "$home_dir/.claude"
  rm -f "$record"/claude.calls "$record"/stdout.txt "$record"/stderr.txt
  env HOME="$home_dir" \
      HOST_CLAUDE_VERSION="$host_version" \
      FAKE_CLAUDE_VERSION="$container_version" \
      FAKE_CLAUDE_CALLS="$record/claude.calls" \
      PATH="$T/entrypoint-bin:$PATH" \
      sh "$ENTRYPOINT" "$@" >"$record/stdout.txt" 2>"$record/stderr.txt"
}

echo "=== E1a: first run seeds the credentials ==="
REC="$T/record/e1a"
E_HOME="$T/ehome-a"
mkdir -p "$E_HOME"
echo '{"seed":true}' > "$E_HOME/.claude-host-credentials-seed.json"
run_entrypoint "$REC" "$E_HOME" 2.1.0 2.1.0 -p hello
rc=$?
exit_code_is "$rc" 0 "entrypoint succeeds"
content_is "$E_HOME/.claude/.credentials.json" '{"seed":true}' "credentials seeded from the host"
has_no_pattern "$REC/stderr.txt" 'sign in' "no login hint when credentials exist"
has_line "$REC/claude.calls" "run -p hello" "arguments passed through to claude"

echo "=== E1b: the container's own login is never overwritten ==="
REC="$T/record/e1b"
E_HOME="$T/ehome-b"
mkdir -p "$E_HOME/.claude"
echo '{"seed":true}' > "$E_HOME/.claude-host-credentials-seed.json"
echo '{"own":true}' > "$E_HOME/.claude/.credentials.json"
run_entrypoint "$REC" "$E_HOME" 2.1.0 2.1.0
content_is "$E_HOME/.claude/.credentials.json" '{"own":true}' "existing credentials kept"

echo "=== E1c: no credentials anywhere -> login hint ==="
REC="$T/record/e1c"
run_entrypoint "$REC" "$T/ehome-c" 2.1.0 2.1.0
rc=$?
exit_code_is "$rc" 0 "entrypoint still starts claude"
has_pattern "$REC/stderr.txt" 'sign in inside the container' "hint printed"
path_exists "$REC/claude.calls" "claude launched"

echo "=== E2a: settings.json seeded from the host only when the container has none ==="
REC="$T/record/e2a"
E_HOME="$T/ehome-settings-a"
mkdir -p "$E_HOME"
echo '{"model":"opus"}' > "$E_HOME/.claude-host-settings-seed.json"
run_entrypoint "$REC" "$E_HOME" 2.1.0 2.1.0
rc=$?
exit_code_is "$rc" 0 "entrypoint succeeds"
content_is "$E_HOME/.claude/settings.json" '{"model":"opus"}' "settings.json seeded from the host"

echo "=== E2b: the container's own settings.json is never overwritten ==="
REC="$T/record/e2b"
E_HOME="$T/ehome-settings-b"
mkdir -p "$E_HOME/.claude"
echo '{"model":"opus"}' > "$E_HOME/.claude-host-settings-seed.json"
echo '{"model":"sonnet"}' > "$E_HOME/.claude/settings.json"
run_entrypoint "$REC" "$E_HOME" 2.1.0 2.1.0
content_is "$E_HOME/.claude/settings.json" '{"model":"sonnet"}' "existing settings.json kept, host seed ignored"

echo "=== E2c: no seed file -> no settings.json created ==="
REC="$T/record/e2c"
E_HOME="$T/ehome-settings-c"
run_entrypoint "$REC" "$E_HOME" 2.1.0 2.1.0
rc=$?
exit_code_is "$rc" 0 "entrypoint still succeeds"
path_absent "$E_HOME/.claude/settings.json" "no settings.json created without a seed (read-only mode: claude.sh bind-mounts it directly instead)"

echo "=== E1d-g: version sync ==="
REC="$T/record/e1d"
run_entrypoint "$REC" "$T/ehome-d" 2.1.0 ""
has_line "$REC/claude.calls" "update" "no host version: self-update"
REC="$T/record/e1e"
run_entrypoint "$REC" "$T/ehome-e" 2.1.0 2.1.0
has_no_line "$REC/claude.calls" "update" "same version: no update"
REC="$T/record/e1f"
run_entrypoint "$REC" "$T/ehome-f" 2.1.0 2.2.0
has_line "$REC/claude.calls" "update" "container behind the host: update"
REC="$T/record/e1g"
run_entrypoint "$REC" "$T/ehome-g" 2.1.0 2.0.0
has_no_line "$REC/claude.calls" "update" "container ahead of the host: no update"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All tests passed."
else
  echo "$FAILURES test(s) FAILED."
  exit 1
fi
