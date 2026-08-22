# Machline

A developer-first agent execution workspace for macOS Apple Silicon, giving human-in-the-loop
control over multi-agent runs, terminal command approval, MCP tool permissions, and Git commit
preparation.

## Status

The headless engine is complete and verified end to end. `AgentSession` composes all three layers
and is the type a UI binds to.

- **Control plane** — frame model, permissive JSONL decoder, line reassembly, launch configuration,
  session supervisor.
- **Interception** — Unix-socket approval broker, policy store with allow/deny rules, advisory risk
  classifier, and the `harness-approve` hook helper.
- **Agent tree** — a pure reducer folding the frame stream into a hierarchy of agents with states,
  transcripts, and per-subagent telemetry.
- **Git workbench** — status and diff parsing, hunk-level staging/unstaging/discarding, commit
  composition with Conventional Commits, and AI-drafted messages. Untracked files sit on the
  unstaged side alongside edited ones, diffed against nothing, since `git diff` alone would leave a
  newly written file invisible.
- **MCP hub** — server configuration, per-agent tool grants, advisory write-capability
  classification, and a stdio proxy that tees JSON-RPC to a traffic inspector.
- **macOS app** — a three-pane SwiftUI workspace over the engine: a session rail holding the agent
  tree, a chronological event timeline with a three-band composer, and a run panel carrying context
  usage, active agents, session-wide changes, and the Git workbench, MCP hub, and diagnostics.
  Images pasted into a prompt are shown as the picture rather than as the CLI's `[Image: source:
  …]` path text, in both the live timeline and a resumed session's replay.

See [`PARITY.md`](PARITY.md) for what is still missing against the reference setup this interface
is modelled on.

322 tests: 309 offline (archived CLI transcripts, real throwaway repositories, and a bundled
JSON-RPC server), 13 opt-in live tests that drive the real binary. **The engine is tested; the UI
is not** — the views compile and the app launches, but no automated test exercises them.

## Layout

| Path | Contents |
| :--- | :--- |
| `Sources/HarnessCore` | Engine: frame decoding, process supervision, approval broker, agent graph |
| `Sources/HarnessCore/Git` | Git workbench: status, diffs, hunk staging, commit composition |
| `Sources/harness-approve` | `PreToolUse` hook helper binary (fails closed) |
| `Sources/harness-mcp-proxy` | stdio MCP inspection proxy (fails open, by design) |
| `Sources/harness-echo-mcp` | Minimal MCP server used as a test fixture |
| `Sources/Machline` | SwiftUI application |
| `Sources/Machline/TerminalPane.swift` | Embedded shell; the only file that touches SwiftTerm |
| `Sources/Machline/PastedImage.swift` | Renders pasted-image references in a message as the image |
| `Scripts/build-app.sh` | Assembles `Machline.app` from the SPM products |
| `Scripts/release.sh` | Verifies, tags, and pushes a release |
| `Scripts/make-dmg.sh` | Packages the app into a disk image |
| `Scripts/clean-draft-sessions.sh` | Deletes commit-draft transcripts older builds left behind |
| `Scripts/make-icon.swift` | Draws the app icon; rendered to `.icns` at bundle time |
| `Tests/HarnessCoreTests` | Fixture-driven contract tests plus opt-in live tests |

## Building

```sh
swift build
swift test                        # fixture suites only — fast, free, offline
HARNESS_LIVE_TESTS=1 swift test   # adds end-to-end tests that spawn the real `claude` binary
```

One third-party dependency: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT), for the
embedded shell. Pinned to an exact tag rather than a range — its 2.0 API exists on `main` but is
untagged, so a range would eventually pull a breaking change in on a routine update. It is reached
from exactly one file, `TerminalPane.swift`, so replacing it later is a rewrite of one type.

The alternative considered was [libghostty](https://ghostty.org), which is the better emulator but
requires an exact Zig toolchain to build, publishes a prebuilt macOS artifact only on its rolling
nightly, ships no PTY, renderer, or view, and states its embedding API is not yet stable.

## Running the app

SwiftPM cannot emit an application bundle, so a script assembles one. It also copies in the helper
binaries the app spawns at runtime.

```sh
./Scripts/build-app.sh            # or: ./Scripts/build-app.sh release
open .build/Machline.app
```

Use **Open Project…** (⌘O) to pick a directory. The left rail then lists every conversation the
CLI has recorded for it; clicking one resumes it in its own window, so several sessions run at
once. **New Window** (⌘N) opens an empty one.

## Releasing

Versions come from git tags — nothing in the repo to keep in sync, and any build traces back to the
tag that produced it.

```sh
Scripts/release.sh minor     # or patch / major / an explicit 0.2.0
```

It refuses a dirty tree, runs the tests and a release build first, then tags and pushes — so a
failure costs seconds rather than a published tag that has to be deleted from two places.

`.github/workflows/release.yml` then runs the tests, builds the app with that version stamped into
its `Info.plist`, packages a DMG, and attaches it to a GitHub Release. `.github/workflows/ci.yml`
runs `swift test` on pull requests and on `main`.

Build a DMG locally with:

```sh
MACHLINE_VERSION=0.2.0 ./Scripts/build-app.sh release
MACHLINE_VERSION=0.2.0 ./Scripts/make-dmg.sh
```

**Releases are ad-hoc signed and not notarized.** There is no Apple Developer ID behind them, so
macOS refuses them on first launch anywhere but the machine that built them — right-click → Open,
once per version. The release notes say so.

That is also why there is no in-app updater. Self-replacement is only safe when the download can be
verified against an identity the system trusts; without one, an updater would swap the running app
for a bundle nothing vouched for. **Check for Updates…** in the application menu — or the version badge in the title bar — instead
reports what exists and opens the release page. It is the app's only outbound network request and
runs only when asked. It reads
[`Ehsan200/Machline`](https://github.com/Ehsan200/Machline) by default; `MACHLINE_REPOSITORY` at
build time points a fork elsewhere.

## Runtime

The app drives the Claude Code CLI as a child process over duplex `stream-json` rather than calling
an LLM API directly. It never handles credentials: sessions authenticate as whoever is signed in to
the CLI, and the CLI's own credential-override environment variables are removed from the child so
billing cannot silently move to the API. Verified against CLI **2.1.237**. Three behaviours the design depends on, all
probe-verified and guarded by tests:

- A `result` frame is a **turn boundary, not EOF** — one run can emit several, and the process stays
  alive awaiting input.
- Steering is **queued to the next turn boundary**, not a mid-turn interrupt.
- `PreToolUse` hooks **fail open on timeout** — the runtime cancels the hook and runs the command.
  The gate is therefore built on three nested deadlines (runtime > helper > broker), so the helper
  always ends the wait with an explicit denial before the runtime can cancel it. Every failure path
  — crashed broker, unreachable socket, unparseable payload, missing configuration — denies.
- `--setting-sources ""` does **not** isolate MCP servers, so `--strict-mcp-config` is its
  companion — but both are emitted only in **sealed** mode. Sessions default to **inherited**,
  where `~/.claude` loads exactly as it would in a terminal and ambient MCP servers join
  unannounced. The approval gate is unaffected either way: the `PreToolUse` hook goes in through
  `--settings`, which is independent of setting sources. See `PARITY.md` and PRD §3.2.
- stdout is **not** strictly JSONL — a library log line can appear mid-stream — so a line that fails
  to parse is reported and skipped, never fatal.
- Variadic flags (`--tools`, `--allowedTools`, `--disallowedTools`) **swallow the next flag** when
  emitted with no values, so isolation flags are ordered ahead of them and an empty tool set is
  spelled `--tools ""`.
- MCP tools are **denied until granted**, unlike Bash, so the tool policy grants rather than
  restricts and an empty policy is a closed one.

Before moving the CLI version pin, run the live suite: it is the canary for frame-schema drift.

### Findings

Code comments cite these by number. They came from probe runs against the real CLI, and each one
is guarded by a test.

1. **`PreToolUse` hooks fail open on timeout.** The runtime cancels the hook and runs the command.
   Hence three nested deadlines, innermost first.
2. **`result` is a turn boundary, not EOF.** One run emitted two `result` frames when a background
   subagent finished after the parent's turn ended. Session teardown keys off process exit.
3. **`--disallowedTools` is a hard static gate.** The only enforcement that survives this app
   dying, which is why it defaults to non-empty.
4. **`--setting-sources ""` does not isolate MCP servers.** A run with settings isolation and no
   `--strict-mcp-config` connected nine ambient MCP servers and ~250 tools into a session meant to
   be sealed. Both flags are emitted together, and only in sealed mode — sessions default to
   inheriting `~/.claude`, which accepts that trade knowingly.
5. **A bare variadic flag swallows the flag that follows it.** `--tools` with no values consumed
   `--strict-mcp-config`. The empty tool set is spelled `--tools ""`.
6. **`-p` is not required for duplex `stream-json`,** and the handshake carries more without it —
   `terminal_slash_commands`, `plugins`, `capabilities`, and `memory_paths` are absent under `-p`.
7. **An environment variable outranks the signed-in account.** A stray `ANTHROPIC_API_KEY` moves
   billing to the API silently, so subscription mode removes it from the child's environment.
8. **The CLI writes to a transcript when a session is opened,** so its modification time is not
   when the conversation last had a message in it.
