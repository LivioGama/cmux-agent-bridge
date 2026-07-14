# CMUX Agent Bridge

![Status](https://img.shields.io/badge/status-production%20ready-1f883d)
![Transport](https://img.shields.io/badge/transport-CMUX%20terminal%20panes-black)
![Agents](https://img.shields.io/badge/agents-Codex%20%7C%20Devin%20%7C%20Claude%20Code%20%7C%20Cursor%20CLI-blue)

<a href="https://liviogama.github.io/agent-config/redirect.html?url=https://raw.githubusercontent.com/LivioGama/cmux-agent-bridge/main/.agent-config/skills/cmux-agent-bridge/SKILL.md"><img src="https://raw.githubusercontent.com/LivioGama/agent-config/main/assets/install-badge-small.jpg" alt="Install cmux-agent-bridge skill" height="40" /></a>

### Coordinate live agents through CMUX terminal panes

`cmux-agent-bridge` enables seamless handoff coordination between Codex, Devin, Claude Code, and Cursor CLI through already-open CMUX terminal surfaces. It provides a local-only transport bridge that injects prompts directly into live agent panes, supporting both one-off handoffs and automated review loops.

## 🎯 What It Is For

Coding agents need to coordinate work without launching headless subprocesses or managing complex protocol servers. The CMUX agent bridge provides a simple, terminal-based transport that:

- **Direct injection**: Handoffs appear as typed prompts in live agent panes
- **Queue-based automation**: Optional daemon for automated review cycles
- **Workspace-scoped**: Agents only bridge within the same CMUX workspace
- **Agent-agnostic**: Works with any agent through live discovery
- **Review loop mode**: Specialized workflow for Codex/Devin fix cycles

## 🚀 Quick Start

From the active Codex CMUX pane, bind Codex to the current surface:

```bash
cmux identify
/Users/livio/.codex/skills/cmux-agent-bridge/scripts/setup-cmux-agent-bridge.sh \
  --project-root /path/to/project \
  --workspace workspace:1 \
  --codex-surface surface:1 \
  --no-start-agents
```

The script:
- Opens or reuses a CMUX workspace for the project
- Records existing agent CMUX surfaces
- Installs `cmux-agent-send`, `cmux-agent-triggerd`, and helper scripts
- Stores surface routing in `~/.local/state/cmux-agent-bridge/state.json`
- Starts the queue runner for automated delivery

## 📊 Features

### Direct Handoffs

Send one-off messages between agents:

```bash
cmux-agent-send --from codex-reviewer --to devin-implementer --type final_handoff \
  "Final handoff from Codex: <summary, files changed, validation, requested next action>"
```

### Queue-Based Automation

Queue handoffs for automated delivery:

```bash
cmux-agent-send --queue --from devin-implementer --to codex-reviewer --type final_handoff \
  "Final handoff from Devin: <summary, files changed, tests run, blockers>"
```

### Review Loop Mode

Specialized workflow for automated Codex/Devin fix cycles:

```bash
cmux-review-loop-send.sh \
  --from codex-reviewer \
  --to devin-implementer \
  --type review_findings \
  --project-root "$PWD" \
  --file /tmp/codex-review.md
```

### Live Agent Discovery

The bridge automatically discovers agents in the workspace by analyzing CMUX surface titles:

```bash
cmux-agent-send --discover                           # caller's own workspace
cmux-agent-send --discover --workspace workspace:9    # specific workspace
```

## 🏗️ Architecture

```text
agent handoff -> cmux-agent-send -> CMUX surface -> already-open agent terminal
```

For automated review loops:

```text
agent handoff -> cmux-agent-send --queue -> cmux-agent-triggerd -> CMUX surface
```

The bridge is **local-only**:
- Does not start protocol servers
- Does not write project queue state
- Does not run headless agents
- Only injects prompts into live CMUX panes

## 🔐 Safety Rules

- Terminals may only link/bridge to other terminals in the same CMUX workspace
- Use already-open CMUX panes; do not create new panes unless explicitly requested
- Route `codex-reviewer` to the active Codex pane before sending the first handoff
- Treat injected terminal handoffs as the transport; do not read queue files for conversation content
- Interactive TTY flows (sudo/password prompts) require new CMUX panes
- Never substitute queue-file reads for missing handoffs

## 🧪 Verification

After setup, verify against real CMUX screens:

```bash
cmux tree --all
cmux-agent-send --status
cmux-agent-triggerd --status
```

Send test messages to verify routing:
- One direct message to `devin-implementer`
- One direct message to `codex-reviewer`
- Observe the injected handoff in destination terminals

## 🚀 Agent-First Usage

Install the skill through the `agent-config` deeplink handler:

<a href="https://liviogama.github.io/agent-config/redirect.html?url=https://raw.githubusercontent.com/LivioGama/cmux-agent-bridge/main/.agent-config/skills/cmux-agent-bridge/SKILL.md"><img src="https://raw.githubusercontent.com/LivioGama/agent-config/main/assets/install-badge-small.jpg" alt="Install cmux-agent-bridge skill" height="40" /></a>

Install URL:

```text
https://liviogama.github.io/agent-config/redirect.html?url=https://raw.githubusercontent.com/LivioGama/cmux-agent-bridge/main/.agent-config/skills/cmux-agent-bridge/SKILL.md
```

Raw skill URL:

```text
https://raw.githubusercontent.com/LivioGama/cmux-agent-bridge/main/.agent-config/skills/cmux-agent-bridge/SKILL.md
```

## 📋 Agent IDs

- Short aliases: `codex`, `devin`, `antigravity`
- Codex reviewer/planner: `codex-reviewer`
- Devin implementer: `devin-implementer`
- Claude Code participant: `claude-code-agent`
- Cursor CLI participant: `cursor-agent`
- Antigravity participant: `antigravity-agent`
- Any other agent: works through live discovery

## 🔄 Review Loop Workflow

The bridge supports automated review/fix cycles between Codex reviewer and Devin implementer:

1. **Codex review findings** → CMUX queue → **Devin fixes** → CMUX queue → **Codex re-review**
2. Each loop focuses only on prior blockers/concerns
3. Stop when no blockers remain (default) or no findings at all (hardcore mode)
4. Preserve unrelated user changes
5. Require verification for touched behavior

## 🛠️ Common Commands

Show current bridge state:

```bash
cmux-agent-send --status
```

Run queue runner once for debugging:

```bash
cmux-agent-triggerd --once
```

Use explicit surfaces:

```bash
setup-cmux-agent-bridge.sh \
  --project-root /path/to/project \
  --workspace workspace:1 \
  --devin-surface surface:2 \
  --codex-surface surface:3 \
  --claude-surface surface:4 \
  --no-start-agents
```

## 📖 Full Documentation

See [SKILL.md](.agent-config/skills/cmux-agent-bridge/SKILL.md) for complete documentation including:
- Hard rules and safety boundaries
- Multi-line handoff handling
- Patience and stuck recovery
- First handoff template
- Review loop detailed workflow
- Helper script options
