# Runtime notes

How Machline drives the Claude Code CLI, and the CLI behaviours the design depends on. Code
comments cite this file — `docs/RUNTIME.md, Finding 4` and so on. Everything here came from probe
runs against the real binary, and each item is guarded by a test.

The app drives the CLI as a child process over duplex `stream-json` rather than calling an LLM API
directly. It never handles credentials: sessions authenticate as whoever is signed in to the CLI,
and the CLI's own credential-override environment variables are removed from the child so billing
cannot silently move to the API.

Verified against CLI **2.1.237**. Before moving the version pin, run the live suite — it is the
canary for frame-schema drift.

## Behaviours the design depends on

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
  `--settings`, which is independent of setting sources.
- stdout is **not** strictly JSONL — a library log line can appear mid-stream — so a line that fails
  to parse is reported and skipped, never fatal.
- Variadic flags (`--tools`, `--allowedTools`, `--disallowedTools`, `--add-dir`) **swallow the next
  flag** when emitted with no values, so isolation flags are ordered ahead of them and an empty tool
  set is spelled `--tools ""`.
- MCP tools are **denied until granted**, unlike Bash, so the tool policy grants rather than
  restricts and an empty policy is a closed one.

## Findings

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
9. **A killed subagent says only `killed`/`stopped`.** Interrupting a session mid-task produced
   `task_updated` with `patch.status: "killed"` and `task_notification` with `status: "stopped"` —
   and nothing else. Matching the statuses already seen (`completed`, `failed`, `cancelled`) left a
   dead agent reading "Thinking" for the rest of the session, so the *running* words are what is
   enumerated now and every other status ends the agent. `background_tasks_changed` backs this up:
   the CLI drops a task from that list one frame before its status arrives, so absence is a verdict
   only once it has outlived a second snapshot and a turn boundary.

## Files the agent may read

A session is launched with the project directory plus the attachment store on `--add-dir`. A file
dragged into the composer from outside the project — a screenshot, most often — is copied into that
store first: macOS hands a dragged screenshot over in a directory scoped to the receiving app, so
the CLI child cannot open it where it lies no matter what it is granted.
