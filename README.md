# Secure Claude Code

Runs [Claude Code](https://claude.com/claude-code) inside a Docker sandbox instead of directly on the host, while still behaving like a normal `claude` install: same `~/.claude` config, same git identity (no credentials), same shell workflow. It works standalone, with no native Claude Code install required — see [Requirements](#requirements).

## Why

**Claude Code can read and write anywhere it can reach, and run arbitrary shell commands**. A container puts a hard wall around that: only the project directory and a short, explicit allowlist of mounts are visible inside, a filtered `~/.claude` config, a git identity with its credential helpers stripped out, the host's CA bundle. **Everything else, `~/.aws`, `~/.ssh`, other cloud CLI configs, simply isn't there**. Tokens for services like `gh` or AWS only get in if you explicitly export and pass them through.

It doesn't take malice for that to matter, just a wrong command, or a manipulated one:

- A prompt-injection payload hidden in a dependency, README, or fetched file tells the agent to grab `gh auth token` and slip it into a PR description. On the host, that hands over your GitHub session. In the container, `gh` isn't authenticated, so there's nothing to steal.
- Debugging a failing deploy, Claude runs `aws sts get-caller-identity` and pastes the output into a log or commit to explain what's wrong. On the host, that can leak live AWS keys. In the container, `~/.aws` was never mounted, so there's nothing to leak.

Each run is also disposable and reproducible: `--rm` plus a pinned toolchain (`src/container/Dockerfile.claude-code`) means stray global installs never accumulate on the host or drift between machines. Only the `claude` binary and login itself persist, via dedicated volumes: the binary self-updates, kept in sync with a native host install when there is one; the login is the container's own, independent of the host's (see [How it works](#how-it-works)).

## Requirements

- macOS or Linux
- `bash`
- `jq` (used to read hook scripts out of `~/.claude/settings.json` so they can be mounted into the container)
- [Docker](https://docs.docker.com/get-docker/)

### Optional

- Claude Code installed natively is optional. If `claude` is already on `PATH`, `install.sh` links it as `claude-original` and the sandboxed `claude` stays version-matched with it and seeds its first login from it. Without one, the sandboxed `claude` still works fully standalone: it logs in and self-updates on its own inside the container.

## Install

```bash
./install.sh
```

This will:

1. Check the OS and that Docker is available (warns, doesn't block, if Docker is missing).
2. Locate the native `claude` binary via `PATH`, if there is one.
3. Create `~/.secure-claude-code/bin/`, containing a `claude` symlink to `src/claude.sh`, plus a `claude-original` symlink to the native binary if step 2 found one.
4. Prepend `~/.secure-claude-code/bin` to `PATH` in your shell startup files (whichever of `.zshrc`, `.bashrc`, `.bash_profile`, `.profile` already exist), so it resolves before any native install.
5. Rebuild the `claude-code-sandbox` Docker image from `src/container/Dockerfile.claude-code`.

A native install, if one exists, is never touched, so its own auto-updater keeps working exactly as before. The symlink/PATH setup (steps 2-4) is idempotent and skipped when already installed, but the image rebuild in step 5 always runs. That makes re-running `./install.sh` the supported way to pick up an edit to `Dockerfile.claude-code`: `claude.sh` on its own does not detect Dockerfile changes (see [How it works](#how-it-works)). The script refuses to proceed if it finds a state it can't safely resolve on its own (e.g. a `claude`/`claude-original` in the shim directory that isn't a symlink it manages), explaining what to check.

## Usage

Once installed (and after starting a new shell, so the updated `PATH` takes effect), use `claude` exactly as before:

```bash
claude
```

It now runs sandboxed in Docker, with the project directory, your Claude config, and your git identity mounted in.

If a native install was found at install time, you can invoke the original, **unconstrained** `claude` binary directly:

```bash
claude-original
```

## Restore

```bash
./restore.sh
```

Removes `~/.secure-claude-code/bin` (the `claude` and `claude-original` symlinks) and the `PATH` entry added to your shell startup files. The native install was never modified, so `claude` resolves to it again as soon as you start a new shell.

## How it works

- `src/claude.sh` is a wrapper that mounts the current project directory, your `~/.claude` config, and git identity into the container, and runs the real `claude` binary inside it. It only builds the `claude-code-sandbox` image itself when the image doesn't exist at all (e.g. right after a `docker rmi`); it never detects that `Dockerfile.claude-code` has changed. Re-running `./install.sh` is what rebuilds the image unconditionally (see [Install](#install)), so that's the supported way to pick up a Dockerfile edit.
- `/home/node/.claude` itself is backed by a dedicated Docker volume (`claude-code-sandbox-claude-dir-volume`) that persists across `--rm` containers, with the host's individual `~/.claude` entries (settings.json, agents, etc.) still bind-mounted on top of it as before. This is what lets the container keep its own Anthropic login, independent from the host's: `.credentials.json` is seeded once, on the volume's very first-ever run, from whatever credentials the host has, if any (macOS Keychain or `~/.claude/.credentials.json`); every run after that relies solely on the container's own copy, so a login or an OAuth token refresh performed inside the container actually persists. (A symlink from `.claude/.credentials.json` into a separate credentials-only volume was tried first and doesn't work: Claude Code saves credentials via a temp-file-then-rename, and renaming onto a symlink path replaces the symlink itself with a plain file instead of writing through it, so the save was lost on the next `--rm`.) The practical effect is that `claude` (sandboxed) and `claude-original` (native), when the latter exists, are logged in independently, and each re-authenticates on its own schedule; only `claude-original` writes to the host Keychain/file. When the container has no login at all (no host credentials to seed from, nothing saved yet), `docker-entrypoint.sh` prints a one-line hint to sign in inside the container; after that first login it stays silent.
- Who owns the settings depends on whether a native install exists. Without one, nothing else would ever edit `~/.claude/settings.json`, so it is mounted writable (if the host has the file), or left out so that the container keeps its own writable copy on the `.claude` volume; changes made from inside the container (e.g. `/config`) persist. With a native install, the host's `~/.claude/settings.json` is mounted read-only by default, since the native `claude` manages it — otherwise changes made inside the container would only last for that session and be lost on the next run. The first time this matters, `claude.sh` asks (only when run from a terminal) whether to make it writable instead so container-side changes persist too, at the cost of the container being able to modify settings the native `claude` also uses; answering `always-yes`/`always-no` remembers the choice in `~/.secure-claude-code/settings-mount-mode` so it's never asked again (delete that file to be asked again). A non-interactive run (script, CI) never prompts and keeps the safe read-only default.
  - "Writable" is never a live bind mount of the host file: Claude Code saves settings.json via a temp-file-then-rename, and renaming onto an active bind-mount point fails with `EBUSY` (verified directly against Docker). That silently breaks only *some* settings — e.g. the selected model and its effort/reasoning-level persist in `settings.json` too but apparently go through that atomic path, while a toggle like auto-compact doesn't and still saves fine from inside the container. So when writable is chosen, `claude.sh` mounts the host file read-only at a side path instead, and `docker-entrypoint.sh` copies it into the real (volume-backed, not bind-mounted) `settings.json` once, the first time there is no container copy yet — same seed-once mechanism already used for the login below. After that, the container's own copy is authoritative and safely rename-able, independent of the host's.
- `~/.claude.json` (onboarding, theme, per-project state) is mounted from the host when the file exists. When it doesn't, `claude.sh` creates `~/.secure-claude-code/claude.json` (an empty JSON object, created atomically so wrappers started together can't clobber each other) and mounts that in its place, so the state survives `--rm` without writing into your dotfiles. The two files are independent: a native install added later does not see what the sandbox saved there.
- Any hook script referenced by a `"command"` hook in `~/.claude/settings.json` (e.g. a corporate compliance hook) is read-only bind-mounted into the container at the same path, so hooks configured on the host keep working unchanged inside the sandbox. `claude.sh` reports which hook scripts got mounted, and warns about any it couldn't find on the host.
- A native `claude` install, if one exists, is left completely untouched, so Claude Code's own auto-updater keeps managing it normally. `docker-entrypoint.sh` keeps the in-container copy in sync with whatever version the host is currently on, on every run, so the Docker image itself rarely needs rebuilding. Without a native install to track, the container instead self-updates to latest on every run.
- `install.sh` creates `~/.secure-claude-code/bin/`, with a `claude` symlink to `src/claude.sh` and, if a native install was found, a `claude-original` symlink to it, then prepends that directory to `PATH` in your shell startup files. Because it comes first on `PATH`, typing `claude` anywhere resolves to the sandboxed wrapper instead of any native binary, regardless of what its auto-updater does to it.
- `restore.sh` undoes exactly that: removes the shim directory and the `PATH` entry. It leaves `~/.secure-claude-code/claude.json` in place if it exists, since it holds your saved Claude Code state, and says so.

### Running several instances

Several sandboxed `claude` instances can run at once, on different projects or the same one. They share the `.claude` volume (login, settings, sessions) and the binary volume; Claude Code's own locks live inside those volumes, so updates and credential refreshes don't collide.

One limit remains: Claude Code serializes writes to `~/.claude.json` with a lock file next to it (`/home/node/.claude.json.lock`), and in each container that path is on the container's own throwaway filesystem, so **two containers don't see each other's lock**. When two instances write `~/.claude.json` at the same moment, one write can be lost. In a check with 12 concurrent writes (3 containers at a time) 8 survived, while sequential runs and concurrent processes inside a single container lost none; the file always remained valid JSON. In practice this only affects low-value state (UI preferences, project trust, cached values), and the same applies today when a native `claude` runs next to a sandboxed one. Credentials and settings live on the shared volume and are not affected.

### Tests

```bash
bash tests/test-claude-wrapper.sh
```

Covers the wrapper, `install.sh`, `restore.sh` and `docker-entrypoint.sh` with fake `docker`, `security` and `uname` executables, so it needs no Docker daemon, no macOS keychain and no installed claude. The "no native claude" scenarios strip any real `claude` from `PATH`, so they behave the same on a machine that has one.

### Repository structure

```text
src/
├── claude.sh                       # sandbox wrapper, installed as 'claude'
├── lib/
│   ├── path-utils.sh                # symlink resolution helper
│   └── install-common.sh            # shared helpers for install.sh / restore.sh
└── container/
    ├── Dockerfile.claude-code       # sandbox image definition
    └── docker-entrypoint.sh         # seeds the login, keeps the in-container claude version in sync
tests/
└── test-claude-wrapper.sh          # wrapper, install, restore and entrypoint tests
```

## License

[MIT](LICENSE)
