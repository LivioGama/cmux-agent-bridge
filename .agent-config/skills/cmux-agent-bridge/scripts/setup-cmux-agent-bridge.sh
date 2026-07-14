#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(pwd)"
DEVIN_SURFACE=""
CODEX_SURFACE=""
CLAUDE_SURFACE=""
CURSOR_SURFACE=""
CMUX_WORKSPACE="${CMUX_WORKSPACE_ID:-}"
START_AGENTS=1
START_DAEMON=1
STATUS_ONLY=0
ALLOW_CREATE_SURFACES=0
AUTO_DISCOVER=1
ANNOUNCE=1
declare -a EXTRA_AGENTS=()
STATE_DIR="${CMUX_AGENT_BRIDGE_STATE_DIR:-$HOME/.local/state/cmux-agent-bridge}"
STATE_PATH="$STATE_DIR/state.json"

usage() {
  cat <<'EOF'
Usage: setup-cmux-agent-bridge.sh [options]

Set up CMUX-only live-agent coordination for the current project.

Options:
  --project-root DIR        Project root to coordinate (default: current directory)
  --devin-surface SURFACE   Existing CMUX surface for Devin, e.g. surface:2
  --codex-surface SURFACE   Existing CMUX surface for Codex, e.g. surface:3
  --claude-surface SURFACE  Existing CMUX surface for Claude Code
  --cursor-surface SURFACE  Existing CMUX surface for Cursor CLI
  --agent-surface NAME=SURFACE
                            Bind any agent id (e.g. antigravity=surface:30) to a
                            surface. Repeatable. Use for agents beyond the four
                            built-in slots above.
  --workspace WORKSPACE     Existing CMUX workspace, e.g. workspace:1 or a UUID
  --allow-create-surfaces   Create missing Devin/Codex panes (off by default)
  --no-start-agents         Do not send devin/codex startup commands
  --no-start-daemon         Do not start cmux-agent-triggerd
  --no-auto-discover        Skip live discovery of unregistered agent surfaces
                            (auto-discover is on by default; it only reads
                            `cmux tree --all`, it never creates panes)
  --no-announce             Do not message newly-discovered agents about the
                            bridge (announcing is on by default; only fires
                            once per agent, the first time it's discovered)
  --status                  Print current bridge status, then stop
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --devin-surface)
      DEVIN_SURFACE="$2"
      shift 2
      ;;
    --codex-surface)
      CODEX_SURFACE="$2"
      shift 2
      ;;
    --claude-surface)
      CLAUDE_SURFACE="$2"
      shift 2
      ;;
    --cursor-surface)
      CURSOR_SURFACE="$2"
      shift 2
      ;;
    --agent-surface)
      EXTRA_AGENTS+=("$2")
      shift 2
      ;;
    --no-auto-discover)
      AUTO_DISCOVER=0
      shift
      ;;
    --no-announce)
      ANNOUNCE=0
      shift
      ;;
    --workspace)
      CMUX_WORKSPACE="$2"
      shift 2
      ;;
    --allow-create-surfaces)
      ALLOW_CREATE_SURFACES=1
      shift
      ;;
    --no-start-agents)
      START_AGENTS=0
      shift
      ;;
    --no-start-daemon)
      START_DAEMON=0
      shift
      ;;
    --status)
      STATUS_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

current_cmux_surface() {
  local surface_ref
  surface_ref="$(cmux identify 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("caller", {}).get("surface_ref", ""))' 2>/dev/null || true)"
  if [[ -n "$surface_ref" ]]; then
    echo "$surface_ref"
    return 0
  fi
  echo "${CMUX_SURFACE_ID:-}"
}

install_helpers() {
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$SKILL_DIR/scripts/cmux-agent-send" "$HOME/.local/bin/cmux-agent-send"
  install -m 0755 "$SKILL_DIR/scripts/cmux-agent-triggerd" "$HOME/.local/bin/cmux-agent-triggerd"
  install -m 0755 "$SKILL_DIR/scripts/cmux-review-loop-send.sh" "$HOME/.local/bin/cmux-review-loop-send.sh"
  install -m 0644 "$SKILL_DIR/scripts/cmux_agent_common.py" "$HOME/.local/bin/cmux_agent_common.py"
}

capture_prev_extra_agents() {
  python3 - "$STATE_PATH" "$PROJECT_ROOT" <<'PY'
import json
import sys
from pathlib import Path

state_path, project_root = sys.argv[1], sys.argv[2]
p = Path(state_path)
extra = {}
if p.exists():
    state = json.loads(p.read_text())
    extra = state.get("projects", {}).get(project_root, {}).get("extra_agents", {})
print(json.dumps(extra))
PY
}

detect_self_agent_id() {
  local caller
  caller="$(current_cmux_surface)"
  if [[ -n "$caller" ]]; then
    [[ "$caller" == "$CLAUDE_SURFACE" ]] && { echo "claude-code-agent"; return; }
    [[ "$caller" == "$CODEX_SURFACE" ]] && { echo "codex-reviewer"; return; }
    [[ "$caller" == "$DEVIN_SURFACE" ]] && { echo "devin-implementer"; return; }
    [[ "$caller" == "$CURSOR_SURFACE" ]] && { echo "cursor-agent"; return; }
  fi
  echo "cmux-agent-bridge-setup"
}

write_state() {
  mkdir -p "$STATE_DIR"
  local extra_json="[]"
  if [[ "${#EXTRA_AGENTS[@]}" -gt 0 ]]; then
    extra_json="$(printf '%s\n' "${EXTRA_AGENTS[@]}" | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))')"
  fi
  # NOTE: data must travel via argv, not stdin — this invocation's stdin is
  # already claimed by the heredoc below (python3 - reads its own script
  # from stdin), so anything piped in here would be silently lost.
  python3 - "$STATE_PATH" "$PROJECT_ROOT" "$CMUX_WORKSPACE" "$DEVIN_SURFACE" "$CODEX_SURFACE" "$CLAUDE_SURFACE" "$CURSOR_SURFACE" "$extra_json" <<'PY'
import json
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
project_root, workspace, devin, codex, claude, cursor = sys.argv[2:8]
extra_pairs = json.loads(sys.argv[8])

if state_path.exists():
    state = json.loads(state_path.read_text())
else:
    state = {"agents": {}, "projects": {}}

state.setdefault("agents", {})
for agent_id, name, surface in [
    ("devin", "Devin Implementer", devin),
    ("devin-implementer", "Devin Implementer", devin),
    ("codex", "Codex Reviewer", codex),
    ("codex-reviewer", "Codex Reviewer", codex),
    ("claude-code-agent", "Claude Code", claude),
    ("cursor-agent", "Cursor CLI", cursor),
]:
    current = state["agents"].setdefault(agent_id, {"name": name, "surface": ""})
    current["name"] = name
    if surface:
        current["surface"] = surface

# Generic slot: any agent id (e.g. "antigravity"), not just the four built-ins.
extra_map = {}
for pair in extra_pairs:
    if not pair or "=" not in pair:
        continue
    name, surface = (part.strip() for part in pair.split("=", 1))
    if not name or not surface:
        continue
    current = state["agents"].setdefault(name, {"name": name, "surface": ""})
    current["surface"] = surface
    extra_map[name] = surface

state.setdefault("projects", {})
previous = state["projects"].get(project_root, {})
state["projects"][project_root] = {
    "workspace": workspace,
    "devin_surface": devin or previous.get("devin_surface", ""),
    "codex_surface": codex or previous.get("codex_surface", ""),
    "claude_surface": claude or previous.get("claude_surface", ""),
    "cursor_surface": cursor or previous.get("cursor_surface", ""),
    "extra_agents": {**previous.get("extra_agents", {}), **extra_map},
}
state_path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
PY
}

status() {
  echo "Project: $PROJECT_ROOT"
  echo "State: $STATE_PATH"
  echo
  if command -v cmux >/dev/null 2>&1; then
    echo "CMUX tree:"
    cmux tree --all 2>/dev/null || true
  fi
  echo
  if [[ -x "$HOME/.local/bin/cmux-agent-send" ]]; then
    "$HOME/.local/bin/cmux-agent-send" --status || true
  else
    echo "cmux-agent-send is not installed at ~/.local/bin/cmux-agent-send"
  fi
  echo
  if [[ -x "$HOME/.local/bin/cmux-agent-triggerd" ]]; then
    "$HOME/.local/bin/cmux-agent-triggerd" --status || true
  else
    echo "cmux-agent-triggerd is not installed at ~/.local/bin/cmux-agent-triggerd"
  fi
}

start_daemon() {
  if command -v launchctl >/dev/null 2>&1; then
    local agents_dir="$HOME/Library/LaunchAgents"
    local plist="$agents_dir/com.liviogama.cmux-agent-triggerd.plist"
    mkdir -p "$agents_dir" "$STATE_DIR"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.liviogama.cmux-agent-triggerd</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME/.local/bin/cmux-agent-triggerd</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$PATH</string>
  </dict>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$STATE_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$STATE_DIR/launchd.err.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    launchctl kickstart -k "gui/$(id -u)/com.liviogama.cmux-agent-triggerd" >/dev/null 2>&1 || true
    sleep 0.5
    if launchctl print "gui/$(id -u)/com.liviogama.cmux-agent-triggerd" >/dev/null 2>&1; then
      return 0
    fi
    echo "launchctl did not retain cmux-agent-triggerd; falling back to nohup." >&2
  fi

  nohup "$HOME/.local/bin/cmux-agent-triggerd" >/tmp/cmux-agent-triggerd.stdout 2>&1 &
  trigger_pid="$!"
  sleep 0.5
  if ! kill -0 "$trigger_pid" >/dev/null 2>&1; then
    echo "cmux-agent-triggerd failed to stay running." >&2
    cat /tmp/cmux-agent-triggerd.stdout >&2 || true
    exit 1
  fi
}

if [[ "$STATUS_ONLY" == "1" ]]; then
  status
  exit 0
fi

need cmux
need python3
install_helpers

if [[ -z "$CMUX_WORKSPACE" ]]; then
  cmux "$PROJECT_ROOT" >/tmp/cmux-agent-bridge-launch.log 2>&1 || true
  sleep 1
fi
if [[ -z "$CMUX_WORKSPACE" ]]; then
  CMUX_WORKSPACE="$(cmux current-workspace 2>/dev/null | awk '{print $1; exit}')"
fi
if [[ -z "$CMUX_WORKSPACE" ]]; then
  CMUX_WORKSPACE="workspace:1"
fi

if [[ -z "$CODEX_SURFACE" ]]; then
  CODEX_SURFACE="$(current_cmux_surface)"
fi

if [[ -z "$DEVIN_SURFACE" && "$ALLOW_CREATE_SURFACES" == "1" ]]; then
  DEVIN_SURFACE="$(cmux new-split right --workspace "$CMUX_WORKSPACE" --focus false | awk '{print $2; exit}')"
fi
if [[ -z "$CODEX_SURFACE" && "$ALLOW_CREATE_SURFACES" == "1" ]]; then
  CODEX_SURFACE="$(cmux new-split down --workspace "$CMUX_WORKSPACE" --focus false | awk '{print $2; exit}')"
fi
if [[ -z "$CODEX_SURFACE" ]]; then
  echo "Missing Codex surface. Run from a CMUX pane or pass --codex-surface. Refusing to create panes without --allow-create-surfaces." >&2
  exit 1
fi

if [[ "$AUTO_DISCOVER" == "1" ]] && [[ -x "$HOME/.local/bin/cmux-agent-send" ]]; then
  while IFS='=' read -r name surface; do
    [[ -z "$name" || -z "$surface" ]] && continue
    case "$name" in
      devin|devin-implementer)
        [[ -z "$DEVIN_SURFACE" ]] && DEVIN_SURFACE="$surface" ;;
      codex|codex-reviewer)
        : # Codex surface is already resolved to the caller above; don't override.
        ;;
      claude-code-agent)
        [[ -z "$CLAUDE_SURFACE" ]] && CLAUDE_SURFACE="$surface" ;;
      cursor-agent)
        [[ -z "$CURSOR_SURFACE" ]] && CURSOR_SURFACE="$surface" ;;
      *)
        EXTRA_AGENTS+=("$name=$surface") ;;
    esac
  done < <(
    "$HOME/.local/bin/cmux-agent-send" --discover --workspace "$CMUX_WORKSPACE" 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin).get("discovered",{}); [print(f"{k}={v}") for k,v in d.items()]' 2>/dev/null || true
  )
fi

PREV_EXTRA_JSON="$(capture_prev_extra_agents)"

write_state

declare -a NEW_AGENTS=()
if [[ "${#EXTRA_AGENTS[@]}" -gt 0 ]]; then
  while IFS='=' read -r name surface; do
    [[ -z "$name" || -z "$surface" ]] && continue
    prev_surface="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get(sys.argv[2], ""))' "$PREV_EXTRA_JSON" "$name" 2>/dev/null || echo "")"
    if [[ "$prev_surface" != "$surface" ]]; then
      NEW_AGENTS+=("$name=$surface")
    fi
  done < <(printf '%s\n' "${EXTRA_AGENTS[@]}")
fi

if [[ "$ANNOUNCE" == "1" ]] && [[ "${#NEW_AGENTS[@]}" -gt 0 ]] && [[ -x "$HOME/.local/bin/cmux-agent-send" ]]; then
  SELF_AGENT_ID="$(detect_self_agent_id)"
  for pair in "${NEW_AGENTS[@]}"; do
    name="${pair%%=*}"
    surface="${pair#*=}"
    if "$HOME/.local/bin/cmux-agent-send" --from "$SELF_AGENT_ID" --to "$name" --type bridge_announce --force \
      "CMUX agent bridge is now set up in this workspace ($CMUX_WORKSPACE, project $PROJECT_ROOT). You were discovered live and registered as agent id '$name'. Other agents here reach you with: cmux-agent-send --to $name --from <their-id> \"<message>\". To reply: cmux-agent-send --to $SELF_AGENT_ID --from $name \"<message>\" (add --queue to use the automated delivery loop). This only announces once; no action needed unless you want to reply." \
      >/dev/null 2>&1
    then
      echo "Announced bridge to $name ($surface)"
    else
      echo "Warning: could not announce bridge to $name ($surface) — it may be busy; it is still registered for the next handoff." >&2
    fi
  done
fi

# Rename current tab to <project-name>..<workspace-number> on first setup
CALLER_SURFACE="$(current_cmux_surface)"
if [[ -n "$CALLER_SURFACE" ]] && [[ -n "$PROJECT_ROOT" ]] && [[ -n "$CMUX_WORKSPACE" ]]; then
  FOLDER_NAME="$(basename "$PROJECT_ROOT")"
  WORKSPACE_ID="${CMUX_WORKSPACE#workspace:}"
  WORKSPACE_ID="${WORKSPACE_ID#*:}"  # Handle UUID format if present
  # Extract just the number if it's workspace:N format
  if [[ "$CMUX_WORKSPACE" =~ workspace:([0-9]+) ]]; then
    WORKSPACE_ID="${BASH_REMATCH[1]}"
  fi
  NEW_TAB_NAME="${FOLDER_NAME}..${WORKSPACE_ID}"
  # Check if we've already renamed this surface for this project
  RENAME_KEY="renamed_${CALLER_SURFACE}_${PROJECT_ROOT}"
  ALREADY_RENAMED="$(python3 - "$STATE_PATH" "$RENAME_KEY" <<'PY' 2>/dev/null || echo "0"
import json, sys
state_path, key = sys.argv[1], sys.argv[2]
from pathlib import Path
p = Path(state_path)
if p.exists():
    state = json.loads(p.read_text())
    if state.get("renamed_surfaces", {}).get(key):
        print("1")
        sys.exit(0)
print("0")
PY
)"
  if [[ "$ALREADY_RENAMED" == "0" ]]; then
    # Not renamed yet, do it now
    if cmux rename-surface --surface "$CALLER_SURFACE" "$NEW_TAB_NAME" >/dev/null 2>&1; then
      echo "Renamed current tab to: $NEW_TAB_NAME"
      # Track that we renamed it
      python3 - "$STATE_PATH" "$RENAME_KEY" "$NEW_TAB_NAME" <<'PY'
import json, sys
state_path, key, name = sys.argv[1], sys.argv[2], sys.argv[3]
from pathlib import Path
p = Path(state_path)
if p.exists():
    state = json.loads(p.read_text())
else:
    state = {}
state.setdefault("renamed_surfaces", {})[key] = name
p.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
PY
    else
      echo "Warning: could not rename tab to $NEW_TAB_NAME" >&2
    fi
  fi
fi

if [[ "$START_AGENTS" == "1" ]]; then
  if [[ -n "$DEVIN_SURFACE" ]] && ! cmux read-screen --surface "$DEVIN_SURFACE" --lines 20 2>/dev/null | grep -qi "devin"; then
    cmux send --surface "$DEVIN_SURFACE" "cd '$PROJECT_ROOT' && devin"
    cmux send-key --surface "$DEVIN_SURFACE" Enter
  fi
  if [[ -n "$CODEX_SURFACE" ]] && ! cmux read-screen --surface "$CODEX_SURFACE" --lines 20 2>/dev/null | grep -qi "codex"; then
    cmux send --surface "$CODEX_SURFACE" "cd '$PROJECT_ROOT' && codex"
    cmux send-key --surface "$CODEX_SURFACE" Enter
  fi
fi

if [[ "$START_DAEMON" == "1" ]]; then
  while read -r pid; do
    [[ -z "$pid" || "$pid" == "$$" ]] && continue
    kill "$pid" >/dev/null 2>&1 || true
  done < <(pgrep -f "$HOME/.local/bin/cmux-agent-triggerd" || true)
  start_daemon
fi

echo "CMUX agent bridge ready."
echo "Project: $PROJECT_ROOT"
echo "Workspace: $CMUX_WORKSPACE"
echo "Devin surface: $DEVIN_SURFACE"
echo "Codex surface: $CODEX_SURFACE"
if [[ "${#EXTRA_AGENTS[@]}" -gt 0 ]]; then
  echo "Extra agents bound (live-discovered or --agent-surface):"
  printf '  %s\n' "${EXTRA_AGENTS[@]}"
fi
echo "State: $STATE_PATH"
echo
status
