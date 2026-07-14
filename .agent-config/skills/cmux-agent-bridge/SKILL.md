---
name: cmux-agent-bridge
description: Set up or operate the local CMUX transport bridge that lets Codex, Devin, Claude Code, and Cursor CLI hand work to each other through already-open terminal panes. Includes review loop mode for automated Codex/Devin fix cycles. Use when the user asks to coordinate live agents in CMUX, start the review loop automation, send direct handoffs, or repair agent surface routing.
---

# CMUX Agent Bridge

Use this skill to coordinate live agents through CMUX terminal surfaces:

```text
agent handoff -> cmux-agent-send -> CMUX surface -> already-open agent terminal
```

For automatic review loops, use the local queue runner:

```text
agent handoff -> cmux-agent-send --queue -> cmux-agent-triggerd -> CMUX surface
```

This bridge is local-only. It does not start protocol servers, write project queue
state, or run headless agents. It only injects prompts into live CMUX panes.

## Hard Rules

- Terminals may only link/bridge to other terminals in the same CMUX workspace
  unless the user explicitly asks for cross-workspace bridging.
- Use already-open CMUX panes. Do not create new panes or surfaces unless the
  user explicitly asks for new agent surfaces.
- Route `codex-reviewer` to the active Codex pane before sending the first
  handoff. Inside CMUX, get it with `cmux identify` and use the caller
  `surface_ref`.
- Treat injected terminal handoffs as the transport. Do not read
  `queue.jsonl` or `delivered.jsonl` for conversation content. Use status/logs
  only to debug routing or daemon failures.
- The first handoff to an agent that may not know this skill must include its
  agent ID, Codex's agent ID, the exact reply command, and setup instructions.
- If a message does not arrive, fix surface routing and wait for CMUX injection.
  Do not substitute queue-file reads for the missing handoff.
- If work inside a bridged pane needs a sudo/password prompt or any other
  interactive TTY flow (ssh passphrase, login/OAuth device code), spawn a new
  CMUX pane for it (`cmux new-split right|down --workspace <ws> --focus
  false`) rather than attempting it in the current one. Some bridged surfaces
  (e.g. CMUX-native agent integrations) have `tty: null` in `cmux tree --json`
  — no real pseudo-terminal at all — and can't run these interactive programs
  regardless, so this isn't optional for them. Same for long-running work
  (builds, test suites, deploys): move it to a new pane and free the current
  one. Either way, don't let a blocked/busy pane hang bridge coordination — it
  reads as "stuck" to the bridge's own readiness/patience checks.

## Quick Start

From the active Codex CMUX pane, bind Codex to the current surface first:

```bash
cmux identify
/Users/livio/.codex/skills/cmux-agent-bridge/scripts/setup-cmux-agent-bridge.sh \
  --project-root /path/to/project \
  --workspace workspace:1 \
  --codex-surface surface:1 \
  --no-start-agents
```

Use the `workspace_ref` and caller `surface_ref` from `cmux identify`. Add
`--claude-surface`, `--devin-surface`, or `--cursor-surface` only when those
agents already have open panes.

The script:

- opens or reuses a CMUX workspace for the project;
- records existing agent CMUX surfaces;
- optionally starts `devin` and `codex` in those surfaces;
- installs `cmux-agent-send`, `cmux-agent-triggerd`, and `cmux-review-loop-send.sh` in `~/.local/bin`;
- stores surface routing in `~/.local/state/cmux-agent-bridge/state.json`;
- renames the current tab to `<project-name>..<workspace-number>` on first setup (e.g. `usable-git..1`);
- starts the queue runner unless `--no-start-daemon` is passed.

To intentionally create fresh agent panes, opt in:

```bash
/Users/livio/.codex/skills/cmux-agent-bridge/scripts/setup-cmux-agent-bridge.sh \
  --project-root /path/to/project \
  --allow-create-surfaces
```

## Common Commands

Show current bridge state:

```bash
/Users/livio/.codex/skills/cmux-agent-bridge/scripts/setup-cmux-agent-bridge.sh --status
```

Use explicit surfaces:

```bash
/Users/livio/.codex/skills/cmux-agent-bridge/scripts/setup-cmux-agent-bridge.sh \
  --project-root /path/to/project \
  --workspace workspace:1 \
  --devin-surface surface:2 \
  --codex-surface surface:3 \
  --claude-surface surface:4 \
  --no-start-agents
```

Send a one-off handoff directly:

```bash
cmux-agent-send --from codex-reviewer --to devin-implementer --type final_handoff \
  "Final handoff from Codex: <summary, files changed, validation, requested next action>"
```

Queue a handoff for the automated review loop:

```bash
cmux-agent-send --queue --from devin-implementer --to codex-reviewer --type final_handoff \
  "Final handoff from Devin: <summary, files changed, tests run, blockers>"
```

Run the queue runner once for debugging:

```bash
cmux-agent-triggerd --once
```

## Agent IDs

- Short aliases: `codex`, `devin`, `antigravity`
- Codex reviewer/planner: `codex-reviewer`
- Devin implementer: `devin-implementer`
- Claude Code participant: `claude-code-agent`
- Cursor CLI participant: `cursor-agent`
- Antigravity participant: `antigravity-agent`
- Any other agent: works too — see Generic / Live Discovery below.

## Generic / Live Discovery (works regardless of registry)

The bridge is not limited to the four built-in agent IDs above, and it does
not require running setup for a project before it works. `cmux-agent-send`
and `cmux-agent-triggerd` fall back to reading the **live** `cmux tree --all
--json` and classifying every surface's title when an agent id is not in
`state.json` (or has no surface recorded yet). A surface titled
`"...antigravity-bb3a"` resolves to `antigravity-agent` automatically; a
surface with `codex`/`devin`/`claude`/`cursor`/`gemini`/`aider`/`windsurf`/
`opencode` anywhere in its title resolves to that agent; anything else
matching a `"<name>-<hexid>"` tab-title pattern is picked up generically as
`<name>-agent`. Once resolved this way, the registry self-heals — the
discovered surface is written back to `state.json` so the next lookup is
instant.

**Same workspace only, by default.** Discovery and resolution are scoped to
one CMUX workspace — the one explicitly passed, or the caller's own current
workspace (via `cmux identify`) if none was given. This is deliberate: the
whole point of the bridge is agents you can actually see sitting next to
each other in the same workspace. It never silently reaches into an
unrelated workspace to "helpfully" find an agent with a matching name — a
`codex-reviewer` sitting in a different project's workspace will NOT be
picked up unless the user explicitly asks for cross-workspace bridging and
you explicitly point `--workspace` at that workspace.

Inspect what's live without sending anything:

```bash
cmux-agent-send --discover                           # caller's own workspace
cmux-agent-send --discover --workspace workspace:9    # a specific workspace
```

This prints `discovered` (agent id -> surface) and `unmatched_surfaces`
(surfaces that matched no pattern) — nothing is silently dropped.

To bind an arbitrary agent id manually (bypassing discovery, e.g. for an
agent whose title doesn't fit the pattern):

```bash
setup-cmux-agent-bridge.sh --project-root /path/to/project \
  --agent-surface antigravity=surface:30 \
  --no-start-agents
```

`--agent-surface NAME=SURFACE` is repeatable and works for any agent name,
not just the four built-in slots. Setup also runs live discovery by default,
scoped to the target workspace (read-only, never creates panes) and folds
any newly-found agents into `state.json`; pass `--no-auto-discover` to skip
it.

`--status` now cross-references the static registry against the live tree
(`live_discovered_agents` / `live_unmatched_surfaces` in its output) instead
of only reporting what was registered in a prior setup run.

## Auto-Announce to Newly-Discovered Neighbors

When setup discovers an agent in the target workspace for the first time
(one not already recorded with that surface), it sends that agent a one-time
`bridge_announce` handoff — its assigned agent id, how others reach it, and
the reply command — the same information as the First Handoff Template
below, generated automatically instead of hand-typed. This only fires once
per (agent id, surface) pair; re-running setup against an already-known
agent is a no-op. Pass `--no-announce` to skip it.

This is the mechanism for "the first agent to set up the bridge tells its
workspace neighbors about it" — it's a message into their pane, the same
transport as any other handoff; it does not (and cannot) reach into another
tool's process to invoke that tool's own skill system.

## Multi-Line Handoffs Are Typed, Not Pasted Raw

`cmux send`'s own docs say it: a raw newline byte in the text argument is
treated as an Enter keypress (verified directly: `cmux send "echo AAA\necho
BBB"` ran `echo AAA` and `echo BBB` as two separate submitted commands, not
one two-line paste). Every handoff's `format_prompt()` output is multi-line
(header fields, blank lines, then the content), so passing it to `cmux send`
in one call tears it into many separate submissions — a target agent gets a
rapid burst of fragments instead of one coherent message and may reply to
the first fragment before the rest even arrives. `inject()` in
`cmux_agent_common.py` works around this: it types each line separately and
joins them with `send-key shift+enter` (inserts a literal newline into the
compose box without submitting), then sends exactly one trailing `Enter` to
submit the whole block. If you ever touch `inject()`, preserve this — do not
"simplify" it back to a single `cmux send` call with the raw multi-line
string, that reintroduces the fragmentation bug.

## Patience and Stuck Recovery (`cmux-agent-triggerd`)

The queue runner does not hammer a pending message's readiness check every
poll tick. It waits at least `--patience-seconds` (default 20s) between
re-checks of the *same* message — busy means give it time, not check harder.
If a message has been pending longer than `--stuck-seconds` (default 240s /
4 minutes), that usually isn't "still busy" — it more likely means `inject()`
typed the prompt but the follow-up Enter keypress was dropped, so the
message sits typed-but-unsubmitted forever. Past that threshold the daemon
tries exactly one recovery nudge (resend Enter to the surface) before going
back to patient waiting, logged as `stuck-recovery` in `triggerd.log`.

## First Handoff Template

When sending to Claude Code or any agent that may not have loaded this skill,
include this block at the top:

```text
CMUX protocol:
- Your agent ID: claude-code-agent
- My agent ID: codex-reviewer
- Reply with:
  cmux-agent-send --queue --from claude-code-agent --to codex-reviewer --type review_response "<message>"
- If `cmux-agent-send` is unavailable or routing is missing, run from your CMUX pane:
  /Users/livio/.codex/skills/cmux-agent-bridge/scripts/setup-cmux-agent-bridge.sh \
    --project-root <project-root> \
    --workspace <workspace-ref> \
    --claude-surface <your-surface-ref> \
    --codex-surface <codex-surface-ref> \
    --no-start-agents
- Then retry the reply command.
```

## Verification

After setup, verify against real CMUX screens:

```bash
cmux tree --all
cmux-agent-send --status
cmux-agent-triggerd --status
```

Then send one direct message to `devin-implementer` and one to
`codex-reviewer`. The message must appear in the corresponding open CMUX
terminal. For queued delivery, the queue runner may mark a message delivered
only after CMUX injection succeeds.

Verification means observing the injected handoff in the destination terminal.
Status JSON and queue files are diagnostic only; they are not successful
conversation delivery.

## Safety Rules

- Do not use ACPX, `codex exec`, `devin -p`, or a headless agent subprocess for this bridge.
- Do not create panes as a side effect of routine setup. Use
  `--allow-create-surfaces` only when new panes are intended.
- Do not silently drop queued messages. If a surface is missing, unreadable, or busy, fail loudly in direct mode and log a retry in queue mode.
- Do not inspect queue or delivered files for message content during normal
  collaboration. Wait for injected handoffs.
- Keep surface IDs in local runtime state, not repository files.
- Before an agent stops after coordinated work, send a `final_handoff` to the next agent with `cmux-agent-send`; use `--queue` when the review loop should continue automatically.

## Review Loop Mode

The bridge supports a specialized automated review/fix loop between Codex reviewer and Devin/VIN implementer panes:

```text
Codex review findings -> CMUX queue -> Devin fixes -> CMUX queue -> Codex focused re-review
```

This mode uses the same transport as general handoffs but adds workflow-specific rules and a helper script.

### Required setup

1. Run bridge setup first (see Quick Start above).
2. Verify routing with:

```bash
cmux-agent-send --status
cmux-agent-triggerd --status
```

3. Ensure these agent IDs route to live CMUX panes:
   - `codex-reviewer`: current Codex pane doing review.
   - `devin-implementer`: Devin/VIN pane doing implementation.

If either route is missing, run the CMUX bridge setup from the active pane and bind the surfaces before sending review content.

### Reviewer workflow

When Codex has blockers/concerns for Devin:

1. Keep review output findings-first.
2. Include exact file/line references and acceptance criteria.
3. Ask Devin to fix only listed blockers/concerns unless the user broadens scope.
4. Require Devin to reply with a queued `final_handoff`.
5. Send via the helper script (installed to `~/.local/bin` by setup):

```bash
cmux-review-loop-send.sh \
  --from codex-reviewer \
  --to devin-implementer \
  --type review_findings \
  --project-root "$PWD" \
  --file /tmp/codex-review.md
```

For quick use, pipe the review directly:

```bash
cat /tmp/codex-review.md | cmux-review-loop-send.sh
```

The sent message must include:

- Review findings.
- What "fixed" means.
- Verification expected from Devin.
- Exact reply command back to Codex:

```bash
cmux-agent-send --queue --from devin-implementer --to codex-reviewer --type final_handoff "<summary, files changed, validation, blockers>"
```

### Devin implementer instructions

Every handoff to Devin must instruct it to:

- Treat Codex findings as the authoritative fix list.
- Preserve unrelated user changes.
- Fix root cause, not tests/docs only.
- Run relevant verification for the touched behavior when credentials/environment allow.
- If blocked, report the blocker instead of pretending completion.
- Reply with `final_handoff` through `cmux-agent-send --queue`.

### Codex re-review rules

After Devin replies:

1. Review only prior blockers/concerns and tests/docs directly added for those fixes.
2. Allow new findings only if they are P0-P2 and introduced by the fix.
3. Do not broaden into a fresh full review unless the user explicitly asks.
4. In default mode, stop only when no blockers remain and no concerns remain unless the user explicitly accepts/defers a concern.
5. In hardcore mode, stop only when the review has no findings left at all.
6. If not fixed, send a smaller follow-up handoff containing only remaining issues.

### Message template

Use this shape for review handoffs:

```text
CMUX review loop handoff

From: codex-reviewer
To: devin-implementer
Project: <absolute project root>
Round: <n>

Task:
Fix the review findings below. Do not broaden scope. Preserve unrelated work.

Acceptance:
- All blockers fixed at root cause.
- Concerns either fixed or explicitly marked deferred with rationale.
- Relevant verification run and reported.
- Reply through:
  cmux-agent-send --queue --from devin-implementer --to codex-reviewer --type final_handoff "<summary, files changed, validation, blockers>"

Review findings:
<paste Codex review>
```

### Helper script

`scripts/cmux-review-loop-send.sh` wraps `cmux-agent-send` and injects the standard protocol around review text. It accepts `--file` or stdin.

Useful options:

- `--dry-run`: print the final handoff without sending.
- `--direct`: send without queue.
- `--hardcore`: require an empty follow-up review before stopping; concerns, suggestions, questions, and nits keep the loop open.
- `--round N`: label the review loop round.
- `--project-root PATH`: project root to include in the prompt.
- `--type review_findings|final_handoff|review_response`: CMUX message type.

### Stop conditions

Default mode stops when:

- No blockers remain.
- No concerns remain, unless the user explicitly accepts or defers a concern.
- Devin reports a real blocker that needs user input or credentials.
- CMUX routing fails and bridge setup cannot repair it.

Hardcore mode is opt-in with `--hardcore`. In hardcore mode, stop only when there are no review findings left at all: no blockers, concerns, suggestions, questions, nits, or unresolved verification gaps. User cancellation still wins.

Never keep bouncing broad reviews. Each loop should get smaller.
