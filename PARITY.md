# Feature parity with `behzade/pi`

Target: everything that repo does, with Machline's own engine, a SwiftUI front end, and a build
that stays `swift build` + `Scripts/build-app.sh`. No Nix. Rust only where it earns its place.

Reference: <https://github.com/behzade/pi> · design spec `apps/pi-gpui/UI_DESIGN.md`.

Status vocabulary: **done** · **partial** · **to build** · **not applicable**.

---

## 1. Interface

| Pi capability | Machline | Notes |
| :--- | :--- | :--- |
| Three-pane shell, fixed rail widths, no headers | **done** | `ContentView`, `Theme.Layout`. Rails 272/312pt with hard maxima; extra width goes to the timeline. |
| Gruvbox dark-hard theme | **done** | `Theme.Colors`, ported from `apps/pi-gpui/src/theme.rs`. |
| Sans for prose, mono for technical content | **done** | `Theme.Typography`, the 15/14/13/12/11 scale from §8 of the spec. |
| Left utility header (search + project rows) | **done** | `SessionRailView`. |
| Project grouping in the rail | **partial** | One project per window, so one heading. Recent projects are switchable from the header menu. |
| Session rows: state, title, relative time | **done** | `SessionRow`, over the CLI's recorded sessions. Agents appear beneath in their own subsection when a session has subagents. |
| Archived / quiet bottom section | **done** | Recent approvals occupy that slot. |
| Timeline hierarchy: user › agent › diff › tools | **done** | `TimelineView`. Assistant blocks sharing a message id fold into one prose event. |
| Collapsed tool rows, failures stay open | **done** | `ToolRow`, `ToolResultRow`. |
| Inline diffs with sticky header and counts | **done** | `DiffCard`; `Edit`/`Write`/`MultiEdit` payloads are diffed with an LCS in `LineDiff`. |
| Split diff view | **to build** | Unified only. Split needs a two-column render plan — Pi's `src/diff_plan`, adapted from `@pierre/diffs`. |
| Syntax highlighting in diffs | **to build** | Candidate for the one place Rust pays: a `tree-sitter` static library behind a C ABI. Swift-only fallback is a regex highlighter per language. |
| Compact context ring | **done** | `ContextSummary`. Denominator is a per-model lookup; the exact counts are runtime-reported. |
| Active subagent cards | **done** | `ActiveSubagentsSection`. Role, activity, current tool, tool count, tokens, elapsed. |
| Completed agents, separated and collapsed | **done** | `CompletedAgentsList`. Outcome, never a stale "current tool". |
| Session-wide Changes list | **done** | `ChangesSection`, fed by `GitPanelModel`. Net per file, not a double-counting sum. |
| Full-file diff modal, Esc to close | **done** | `FileDiffModal`. |
| Three-band composer | **done** | `ComposerView`. Status strip carries only runtime-reported facts. |
| Caret reveal on long input | **not applicable** | Pi's bug was in GPUI's editor. `TextEditor` is an `NSTextView` and reveals the caret itself. |
| Responsive: rail collapse, drawer, unified-diff fallback | **to build** | Rails are resizable but do not collapse to overlays yet. |

## 2. Sandboxed execution

Pi's largest subsystem, and the one with a real constraint to settle first.

| Pi capability | Machline | Notes |
| :--- | :--- | :--- |
| Fail-closed approval gate | **done** | `ApprovalBroker` + `harness-approve`, three nested deadlines, denial on every failure path. |
| Per-command OS sandbox (Seatbelt) | **to build** | New `harness-sandbox` helper generating a Seatbelt profile and invoking `/usr/bin/sandbox-exec`. |
| Bubblewrap on Linux | **not applicable** | Machline is macOS-only. |
| Checked-in portable project policy | **to build** | `.machline/sandbox.json`, relative paths only, absolute paths rejected. Mirrors Pi's schema. |
| `request_access` with a bounded diff and explicit approval | **to build** | Extends the existing approval sheet: show only net-new semantic entries, Add-to-policy or Deny. |
| No automatic retries after a denial | **done** | Already the broker's contract. |
| Network blocked by default, one exact host per grant | **to build** | Needs a host-owned proxy; Seatbelt alone cannot express per-hostname rules. |
| Development-cache namespace redirect | **to build** | Environment mapping under `~/.cache/machline-sandbox`. |
| Background jobs with bounded output, status, stop | **to build** | Each job owns its own broker and an immutable policy captured at start. |

**Constraint to resolve first.** Pi owns its own shell tool, so it can wrap every command in a
sandbox. Machline drives the Claude Code CLI, which executes `Bash` itself; the `PreToolUse` hook
sees the command but the runtime, not us, spawns it. Sandboxing therefore needs one of:

1. the hook rewriting the tool input (verify whether the pinned CLI honours `updatedInput` — this
   is exactly the kind of claim `probes/` exists to settle before it is designed around);
2. denying `Bash` outright and exposing a sandboxed `machline_shell` MCP tool the agent uses
   instead — fully under our control, at the cost of the agent's native tool; or
3. a `PATH` shim that routes the shell through the broker.

Option 2 is the one that cannot fail open. Probe first, decide after.

## 3. Agents and sessions

| Pi capability | Machline | Notes |
| :--- | :--- | :--- |
| Agent hierarchy from the frame stream | **done** | `AgentGraph`, a pure reducer. |
| Persistent child sessions with forked or blank context | **to build** | Machline observes subagents the CLI spawns; it cannot start one itself. Needs a `SubagentSupervisor` owning child `AgentSession`s. |
| Steering a child, waiting on it, cancelling it | **partial** | Steering and interrupt exist for the root session only. |
| Per-child model selection | **to build** | Follows from the supervisor. |
| Child completion reprompts the parent | **to build** | |
| Multiple sessions, listed per project | **done** | `SessionHistory` reads the CLI's own transcript store (`~/.claude/projects/<mangled-cwd>/<id>.jsonl`); the rail lists them and `--resume` continues one. |
| Resume a past conversation | **done** | `SessionConfiguration.Resume`. `--resume <id>`, plus `--fork-session` to branch without touching the original transcript. |
| Session titles | **partial** | Taken from the first operator prompt in the transcript, not model-generated. A semantic title would be one cheap call after the first exchange; manual edits should win over both. |
| Concurrent sessions in one window | **to build** | Sessions are listed and switchable, but only one runs at a time — switching stops the running child. Real concurrency needs per-session panel state. |
| Archived sessions | **to build** | Needs an archive flag of our own; the CLI's store has no such concept. |
| Session transfer between projects | **to build** | |
| Work graph | **to build** | Pi ships this as a proposal (`WORK_GRAPH_PROPOSAL.md`), not a finished feature. Lowest priority. |

## 4. Tools and integrations

| Pi capability | Machline | Notes |
| :--- | :--- | :--- |
| MCP server config and per-agent tool grants | **partial** | `MCPToolPolicy`, deny-until-granted — but grants are only sent in sealed mode, since an inherited session's tool surface is not knowable in advance. |
| MCP traffic inspection | **done** | `harness-mcp-proxy`, tees JSON-RPC. |
| Stateless MCP access through a pinned CLI | **partial** | Servers are configured per session; there is no one-shot `mcp-cli` equivalent. |
| Trusted project-scoped tools | **to build** | Pi loads Effect handlers from `.pi/project-tools` into its host process. Swift has no in-process equivalent, so these become sidecar executables the app spawns after project trust. |
| Project trust gate | **to build** | Must land before any project-scoped tool or checked-in policy is honoured. |
| Web search, page extraction, video | **to build** | Small MCP server, shipped in-bundle. |
| Agent-feedback tool writing JSONL | **to build** | Cheap and useful: an MCP tool appending to `~/.machline/agent-feedback.jsonl`, non-blocking. |
| Server-side OpenAI compaction | **not applicable** | Backend is the Claude Code CLI, which compacts itself. |
| Notification / title / session-state hooks | **partial** | Machline installs its own `PreToolUse` hook; in inherited mode the operator's own hooks load too. Extend the installer to the other events. |
| Operator's own commands, skills, and `CLAUDE.md` | **done** | Inherited isolation mode, the default. Sealed remains available per session. |

## 5. Prompts and skills

| Pi capability | Machline | Notes |
| :--- | :--- | :--- |
| `SYSTEM.md` + appended working contract | **to build** | `--append-system-prompt` on the CLI, sourced from a file in the repo. |
| Prompt inspector (`/prompt-report`) | **to build** | Sizes, fingerprints, and the exact assembled prompt in a disposable viewer. |
| `$`-prefixed prompt and skill autocomplete | **to build** | Composer feature; composable in order (`$simplify $commit`). |
| Local skills directory | **to build** | |
| Theme file rather than a compiled palette | **to build** | `Theme.Colors` is compiled in. Loading Pi's theme JSON schema at runtime is a small change and makes the palette swappable. |

## 6. Packaging

| Pi capability | Machline | Notes |
| :--- | :--- | :--- |
| Nix-pinned reproducible builds | **dropped** | Explicitly out of scope. `swift build` plus `Scripts/build-app.sh` stays the whole story. |
| Pinned agent binary | **to build** | The CLI version is probe-verified but not pinned; record the expected version and warn on drift. |
| Third-party licence manifest | **to build** | Only needed once a vendored dependency arrives. |

---

## Beyond pi

| Capability | Machline | Notes |
| :--- | :--- | :--- |
| Embedded shell | **done** | `TerminalPane` over SwiftTerm — a real PTY with the login shell, in the project directory. ⌃` toggles it. Pi has no equivalent; its sandbox work is about *constraining* the agent's shell, not giving the operator one. |
| Syntax-highlighted file viewer | **done** | `SyntaxHighlighter`, a hand-written scanner over 14 languages plus single-file components. Not a parser — that ceiling is where tree-sitter starts. |
| Machline's own `/` commands | **done** | `/status`, `/help`, `/skills`, `/agents`, `/tools`, `/context`, `/cost`, `/permissions`, `/mcp`, `/export`, `/memory`. The CLI never advertises these — they are its terminal client's, not the agent's. |

## Where Rust would actually pay

Two places, and only two:

- **Syntax highlighting** — `tree-sitter` plus its grammars, as a static library behind a C header.
  A Swift package target can link it with no extra build tooling.
- **Diff planning for split view** — only if the Swift `LineDiff` proves too slow on large files,
  which it will not for anything under a few thousand lines.

Everything else is cheaper in Swift, next to the engine that already exists.

## Suggested order

1. **Project trust** — nothing checked into a repository may be honoured before it.
2. **Sandbox probe** — settle the `Bash` interception question; it decides the shape of §2.
3. **Sandbox broker + portable policy + `request_access`** — the substance of the reference repo.
4. **Subagent supervisor** — spawnable, steerable children.
5. **Prompt contract, skills, `$` autocomplete.**
6. **Syntax highlighting and split diffs.**

Session listing and resume are done; concurrent sessions and archiving remain.
