# Machline

A macOS workspace for running Claude Code with your hands on the controls.

Machline drives the Claude Code CLI as a child process and puts a real interface around it: the tree
of agents a run spawns, a chronological timeline of what each one did, an approval gate in front of
every command, a Git workbench for turning the result into a commit, and an embedded shell for the
things you would rather do yourself.

Apple Silicon, macOS 14 or later. You need the `claude` CLI installed and signed in — Machline never
handles credentials and never calls an LLM API directly.

## Install

Download the DMG from [Releases](https://github.com/Ehsan200/Machline/releases), drag the app to
Applications, then **right-click → Open** the first time you run each version.

Builds are ad-hoc signed and not notarized, so macOS refuses them on first launch anywhere but the
machine that built them. That is also why there is no self-updater: **Check for Updates…** in the
application menu — or the version badge beside the tabs — tells you what exists, downloads the disk
image, and leaves installing it to you.

To build it yourself, see [Developing](#developing).

## Using it

**Open a project** with ⌘O. The left rail then lists every conversation the CLI has recorded for
that directory; click one to resume it. ⌘N opens another window, and each window holds one project's
tabs, so several sessions run at once.

**Type in the composer** at the foot of the timeline. Drop files onto it to `@`-mention them, and
paste or drag a screenshot in to send the picture — it is copied somewhere the agent can read it and
shown in the transcript as the image rather than as a path.

**Approve or deny commands** as they come up. Every tool call passes through a `PreToolUse` gate
before it runs; the sheet says what the command is and what it will touch. Rules you set are
remembered per project, and everything that failed the gate stays visible in the run panel. A
handful of destructive patterns are refused outright, whether or not Machline is running.

**Watch the run** in the right-hand panel: context usage, active agents, every file the session has
changed, the MCP hub with its per-agent tool grants and traffic inspector, and diagnostics.

**Commit from the Git workbench.** Stage by hunk, write the message yourself or have one drafted
from the staged diff, then commit and push. Untracked files sit alongside edited ones rather than
disappearing until they are added.

**Open the shell** with ⌃` for the things that are quicker done by hand.

## Developing

```sh
swift build
swift test                        # fixture suites — fast, offline, free
HARNESS_LIVE_TESTS=1 swift test   # adds tests that spawn the real `claude` binary
```

SwiftPM cannot emit an application bundle, so a script assembles one and copies in the helper
binaries the app spawns:

```sh
./Scripts/build-app.sh            # or: ./Scripts/build-app.sh release
open .build/Machline.app
```

One third-party dependency: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT), for the
embedded shell, reached from exactly one file.

| Path | Contents |
| :--- | :--- |
| `Sources/HarnessCore` | Engine: frame decoding, process supervision, approval broker, agent graph |
| `Sources/HarnessCore/Git` | Git workbench: status, diffs, hunk staging, commit composition |
| `Sources/harness-approve` | `PreToolUse` hook helper binary |
| `Sources/harness-mcp-proxy` | stdio MCP inspection proxy |
| `Sources/harness-echo-mcp` | Minimal MCP server used as a test fixture |
| `Sources/Machline` | SwiftUI application |
| `Scripts/` | Bundle assembly, icon, DMG packaging, release |
| `Tests/HarnessCoreTests` | Fixture-driven contract tests plus opt-in live tests |

The engine is tested; the UI is not — the views compile and the app launches, but no automated test
exercises them.

[`docs/RUNTIME.md`](docs/RUNTIME.md) records how the app drives the CLI and the CLI behaviours the
design depends on. Code comments cite it by number.

## Releasing

Versions come from git tags.

```sh
Scripts/release.sh minor     # or patch / major / an explicit 0.2.0
```

It refuses a dirty tree and runs the tests and a release build before tagging. GitHub Actions then
builds the app with that version stamped into its `Info.plist`, packages a DMG, and attaches it to a
release.

Locally:

```sh
MACHLINE_VERSION=0.2.0 ./Scripts/build-app.sh release
MACHLINE_VERSION=0.2.0 ./Scripts/make-dmg.sh
```

The update check reads [`Ehsan200/Machline`](https://github.com/Ehsan200/Machline); set
`MACHLINE_REPOSITORY` at build time to point a fork elsewhere.
