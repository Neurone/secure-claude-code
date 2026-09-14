# Secure Claude Code

Runs [Claude Code](https://claude.com/claude-code) inside a Docker sandbox instead of directly on the host, while still behaving like a normal `claude` install: same credentials, same `~/.claude` config, same git identity, same shell workflow.

## Why

**Claude Code can read and write anywhere it can reach, and run arbitrary shell commands**. A container puts a hard wall around that: only the project directory and a short, explicit allowlist of mounts are visible inside, a filtered `~/.claude` config, a git identity with its credential helpers stripped out, the host's CA bundle. **Everything else, `~/.aws`, `~/.ssh`, other cloud CLI configs, simply isn't there**. Tokens for services like `gh` or AWS only get in if you explicitly export and pass them through.

It doesn't take malice for that to matter, just a wrong command, or a manipulated one:

- A prompt-injection payload hidden in a dependency, README, or fetched file tells the agent to grab `gh auth token` and slip it into a PR description. On the host, that hands over your GitHub session. In the container, `gh` isn't authenticated, so there's nothing to steal.
- Debugging a failing deploy, Claude runs `aws sts get-caller-identity` and pastes the output into a log or commit to explain what's wrong. On the host, that can leak live AWS keys. In the container, `~/.aws` was never mounted, so there's nothing to leak.

Each run is also disposable and reproducible: `--rm` plus a pinned toolchain (`src/container/Dockerfile.claude-code`) means stray global installs never accumulate on the host or drift between machines. Only the `claude` binary itself persists, via a dedicated volume kept in sync with the host (see [How it works](#how-it-works)).

## Requirements

- macOS or Linux
- `bash`
- `jq` (used to read hook scripts out of `~/.claude/settings.json` so they can be mounted into the container)
- [Docker](https://docs.docker.com/get-docker/)
- Claude Code already installed natively (`claude` available in `PATH`)

## Install

```bash
./install.sh
```

This will:

1. Check the OS and that Docker is available (warns, doesn't block, if Docker is missing).
2. Locate the native `claude` binary via `PATH`.
3. Create `~/.secure-claude-code/bin/`, containing a `claude-original` symlink to the native binary and a `claude` symlink to `src/claude.sh`.
4. Prepend `~/.secure-claude-code/bin` to `PATH` in your shell startup files (whichever of `.zshrc`, `.bashrc`, `.bash_profile`, `.profile` already exist), so it resolves before the native install.
5. Rebuild the `claude-code-sandbox` Docker image from `src/container/Dockerfile.claude-code`.

The native install itself is never touched, so its own auto-updater keeps working exactly as before. The symlink/PATH setup (steps 2-4) is idempotent and skipped when already installed, but the image rebuild in step 5 always runs. That makes re-running `./install.sh` the supported way to pick up an edit to `Dockerfile.claude-code`: `claude.sh` on its own does not detect Dockerfile changes (see [How it works](#how-it-works)). The script refuses to proceed if it finds a state it can't safely resolve on its own (e.g. a `claude`/`claude-original` in the shim directory that isn't a symlink it manages), explaining what to check.

## Usage

Once installed (and after starting a new shell, so the updated `PATH` takes effect), use `claude` exactly as before:

```bash
claude
```

It now runs sandboxed in Docker, with the project directory, your Claude config, and your git identity mounted in.

To use the original, natively installed and **unconstrained** `claude` binary, invoke `claude-original` directly:

```bash
claude-original
```

## Restore

```bash
./restore.sh
```

Removes `~/.secure-claude-code/bin` (the `claude` and `claude-original` symlinks) and the `PATH` entry added to your shell startup files. The native install was never modified, so `claude` resolves to it again as soon as you start a new shell.

## How it works

- `src/claude.sh` is a wrapper that mounts the current project directory, your `~/.claude` config, git identity, and credentials into the container, and runs the real `claude` binary inside it. It only builds the `claude-code-sandbox` image itself when the image doesn't exist at all (e.g. right after a `docker rmi`); it never detects that `Dockerfile.claude-code` has changed. Re-running `./install.sh` is what rebuilds the image unconditionally (see [Install](#install)), so that's the supported way to pick up a Dockerfile edit.
- Any hook script referenced by a `"command"` hook in `~/.claude/settings.json` (e.g. a corporate compliance hook) is read-only bind-mounted into the container at the same path, so hooks configured on the host keep working unchanged inside the sandbox. `claude.sh` reports which hook scripts got mounted, and warns about any it couldn't find on the host.
- The native `claude` install is left completely untouched, so Claude Code's own auto-updater keeps managing it normally. `docker-entrypoint.sh` keeps the in-container copy in sync with whatever version the host is currently on, on every run, so the Docker image itself rarely needs rebuilding.
- `install.sh` creates `~/.secure-claude-code/bin/`, with a `claude-original` symlink to the native binary and a `claude` symlink to `src/claude.sh`, then prepends that directory to `PATH` in your shell startup files. Because it comes first on `PATH`, typing `claude` anywhere resolves to the sandboxed wrapper instead of the native binary, regardless of what the native auto-updater does to it.
- `restore.sh` undoes exactly that: removes the shim directory and the `PATH` entry.

### Repository structure

```text
src/
├── claude.sh                       # sandbox wrapper, installed as 'claude'
├── lib/
│   ├── path-utils.sh                # symlink resolution helper
│   └── install-common.sh            # shared helpers for install.sh / restore.sh
└── container/
    ├── Dockerfile.claude-code       # sandbox image definition
    └── docker-entrypoint.sh         # keeps in-container claude version in sync with the host
```

## License

[MIT](LICENSE)
