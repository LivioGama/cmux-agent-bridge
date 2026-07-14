from __future__ import annotations

import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STATE_DIR = Path(os.environ.get("CMUX_AGENT_BRIDGE_STATE_DIR", Path.home() / ".local/state/cmux-agent-bridge")).expanduser()
STATE_PATH = STATE_DIR / "state.json"
QUEUE_PATH = STATE_DIR / "queue.jsonl"
DELIVERED_PATH = STATE_DIR / "delivered.jsonl"
LOG_PATH = Path(os.environ.get("CMUX_AGENT_BRIDGE_LOG", STATE_DIR / "triggerd.log")).expanduser()

DEFAULT_AGENTS = {
    "codex": {"name": "Codex Reviewer", "surface": "surface:3", "alias_for": "codex-reviewer"},
    "codex-reviewer": {"name": "Codex Reviewer", "surface": "surface:3"},
    "devin": {"name": "Devin Implementer", "surface": "surface:2", "alias_for": "devin-implementer"},
    "devin-implementer": {"name": "Devin Implementer", "surface": "surface:2"},
    "claude-code-agent": {"name": "Claude Code", "surface": ""},
    "cursor-agent": {"name": "Cursor CLI", "surface": ""},
    "antigravity": {"name": "Antigravity", "surface": "", "alias_for": "antigravity-agent"},
    "antigravity-agent": {"name": "Antigravity", "surface": ""},
}

# Keyword -> canonical agent id, matched case-insensitively anywhere in a CMUX
# surface title. Extend this list as new named agents show up; it is NOT the
# only way an agent is recognized (see classify_surface_title's generic
# fallback below), so an unlisted agent still works, just under its own id.
AGENT_KEYWORDS: dict[str, str] = {
    "codex": "codex-reviewer",
    "devin": "devin-implementer",
    "claude": "claude-code-agent",
    "cursor": "cursor-agent",
    "antigravity": "antigravity-agent",
    "gemini": "gemini-agent",
    "aider": "aider-agent",
    "windsurf": "windsurf-agent",
    "opencode": "opencode-agent",
}

# CMUX surface titles for agent tabs commonly end in "<name>-<shortid>"
# (e.g. "antigravity-bb3a", "codex-019f32f3-5"). This fallback lets an agent
# that isn't in AGENT_KEYWORDS still get discovered generically.
_SUFFIX_ID_RE = re.compile(r"([a-zA-Z][a-zA-Z0-9]{2,24})-[0-9a-fA-F]{3,}(?:-\d+)?\s*$")
_SKIP_CANDIDATES = {"usable", "agent", "bridge", "cmux"}
_PURE_HEX_RE = re.compile(r"[0-9a-f]+", re.IGNORECASE)


def classify_surface_title(title: str) -> str | None:
    if not title:
        return None
    lowered = title.lower()
    for keyword, canonical in AGENT_KEYWORDS.items():
        if keyword in lowered:
            return canonical
    match = _SUFFIX_ID_RE.search(title.strip())
    if match:
        candidate = match.group(1).lower()
        # Session/workspace UUIDs look identical to this pattern (e.g. the
        # "a2ffd3a9" in "...-a2ffd3a9-a6a0-43"). Real agent names always
        # contain a letter outside a-f (devin, codex, gemini, antigravity);
        # pure hex-charset candidates are UUID fragments, not agent names.
        if candidate not in _SKIP_CANDIDATES and not _PURE_HEX_RE.fullmatch(candidate):
            return f"{candidate}-agent"
    return None


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def ensure_state_dir() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)


def load_state() -> dict[str, Any]:
    if not STATE_PATH.exists():
        return {"agents": DEFAULT_AGENTS.copy(), "projects": {}}
    with STATE_PATH.open("r", encoding="utf-8") as handle:
        state = json.load(handle)
    state.setdefault("agents", {})
    for agent_id, spec in DEFAULT_AGENTS.items():
        state["agents"].setdefault(agent_id, spec.copy())
    state.setdefault("projects", {})
    return state


def save_state(state: dict[str, Any]) -> None:
    ensure_state_dir()
    tmp = STATE_PATH.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2, sort_keys=True)
        handle.write("\n")
    tmp.replace(STATE_PATH)


def log(message: str) -> None:
    ensure_state_dir()
    with LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(f"{now_iso()} {message}\n")


def run_cmux(args: list[str], cwd: str | None = None, timeout: int = 15) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join(
        [
            str(Path.home() / ".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            env.get("PATH", ""),
        ]
    )
    return subprocess.run(
        ["cmux", *args],
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )


def fetch_tree() -> dict[str, Any]:
    result = run_cmux(["tree", "--all", "--json"])
    if result.returncode != 0:
        raise RuntimeError(f"cmux tree failed: {result.stdout.strip()}")
    return json.loads(result.stdout)


def iter_surfaces(tree: dict[str, Any]):
    for window in tree.get("windows", []):
        for workspace in window.get("workspaces", []):
            for pane in workspace.get("panes", []):
                for surface in pane.get("surfaces", []):
                    yield workspace, pane, surface


def current_workspace_ref() -> str | None:
    result = run_cmux(["identify"])
    if result.returncode != 0:
        return None
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    return data.get("caller", {}).get("workspace_ref")


def resolve_scope(workspace_ref: str | None) -> str | None:
    """Same-workspace-only is the default policy: the bridge only pairs
    agents you can actually see next to each other. If no explicit
    workspace_ref is given, scope to the caller's own current workspace
    (via `cmux identify`) rather than searching every open workspace."""
    if workspace_ref:
        return workspace_ref
    return current_workspace_ref()


def discover_agents(workspace_ref: str | None = None, *, scoped: bool = True) -> tuple[dict[str, str], list[dict[str, Any]]]:
    """Classify every live CMUX surface's title against known agent patterns.

    This reads the *live* `cmux tree --all --json` output instead of the
    static state.json registry, so agents that were never registered (or a
    project that was never set up) still resolve. Returns (agent_id -> first
    matching surface ref, [unmatched surface descriptors]) so callers can
    surface unknown surfaces instead of silently dropping them.

    By default (`scoped=True`) this only looks inside one workspace — the
    given `workspace_ref`, or the caller's own current workspace if none was
    given — because the whole point of the bridge is agents that are
    visibly next to each other. If no workspace can be determined, discovery
    returns no live matches instead of searching unrelated workspaces.
    """
    effective_ref = resolve_scope(workspace_ref) if scoped else workspace_ref
    if scoped and not effective_ref:
        return {}, []
    tree = fetch_tree()
    discovered: dict[str, str] = {}
    unmatched: list[dict[str, Any]] = []
    for workspace, pane, surface in iter_surfaces(tree):
        if effective_ref and workspace.get("ref") != effective_ref:
            continue
        title = surface.get("title") or ""
        agent_id = classify_surface_title(title)
        descriptor = {
            "surface": surface.get("ref"),
            "pane": pane.get("ref"),
            "workspace": workspace.get("ref"),
            "title": title,
        }
        if agent_id:
            discovered.setdefault(agent_id, descriptor["surface"])
        else:
            unmatched.append(descriptor)
    return discovered, unmatched


def resolve_agent_surface(
    state: dict[str, Any],
    target: str,
    *,
    workspace_ref: str | None = None,
    persist: bool = True,
) -> str:
    if target.startswith("surface:") or re.fullmatch(r"[0-9a-fA-F-]{36}", target):
        return target

    spec = state.get("agents", {}).get(target)
    if spec and spec.get("surface"):
        return spec["surface"]

    try:
        discovered, _unmatched = discover_agents(workspace_ref=workspace_ref)
    except (RuntimeError, json.JSONDecodeError):
        discovered = {}

    canonical = spec.get("alias_for") if spec else None
    surface = discovered.get(target) or (discovered.get(canonical) if canonical else None)
    if surface:
        if persist:
            agents = state.setdefault("agents", {})
            entry = agents.setdefault(target, {"name": target, "surface": ""})
            entry["surface"] = surface
            save_state(state)
        return surface

    if not spec:
        raise SystemExit(
            f"Unknown CMUX agent target: {target} "
            "(not in registry, and no live surface title matched it in `cmux tree --all`)"
        )
    raise SystemExit(f"No CMUX surface configured for agent: {target}")


def read_surface(surface: str) -> str:
    result = run_cmux(["read-screen", "--surface", surface, "--lines", "40"])
    if result.returncode != 0:
        raise RuntimeError(f"CMUX surface read failed for {surface}: {result.stdout.strip()}")
    return result.stdout


def surface_ready(target: str, surface: str) -> tuple[bool, str]:
    text = read_surface(surface)
    lowered = text.lower()
    if "working (" in lowered or "• working" in lowered:
        return False, "terminal appears busy"
    # "thinking" alone is too broad: Devin CLI's idle footer permanently
    # shows the static hint "Press opt+t to cycle thinking levels", which
    # made every idle Devin pane read as busy forever. Only treat it as a
    # busy signal when it's not that static hint.
    if "thinking" in lowered and "cycle thinking levels" not in lowered:
        return False, "terminal appears busy"
    if target == "codex-reviewer":
        return ("›" in text or "codex" in lowered, "codex prompt visible")
    if target == "devin-implementer":
        return ("ask devin" in lowered or "guide devin" in lowered or "❭" in text or "devin" in lowered, "devin prompt visible")
    return (bool(text.strip()), "surface readable")


def inject(surface: str, prompt: str, cwd: str | None = None) -> None:
    """Type `prompt` into `surface` as one multi-line compose block, then
    submit with a single Enter.

    `cmux send` treats a raw newline byte in its text argument as an Enter
    keypress (confirmed empirically: `cmux send "echo AAA\\necho BBB"` ran
    each line as its own separate submitted command). Every handoff's
    `format_prompt()` output is multi-line (header fields + content), so
    sending it in one `cmux send` call tears it into many separate
    submissions instead of one coherent message — this is exactly what
    fragmented a multi-paragraph handoff into pieces a target agent
    half-processed and replied to prematurely. Fix: type each line
    separately, joined by `send-key shift+enter` (inserts a literal newline
    into the compose box without submitting); only the trailing Enter
    actually sends it.
    """
    lines = prompt.split("\n")
    for i, line in enumerate(lines):
        if line:
            sent = run_cmux(["send", "--surface", surface, "--", line], cwd=cwd)
            if sent.returncode != 0:
                raise RuntimeError(f"CMUX send failed for {surface}: {sent.stdout.strip()}")
        if i < len(lines) - 1:
            newline = run_cmux(["send-key", "--surface", surface, "shift+enter"], cwd=cwd)
            if newline.returncode != 0:
                raise RuntimeError(f"CMUX shift+enter failed for {surface}: {newline.stdout.strip()}")
    entered = run_cmux(["send-key", "--surface", surface, "Enter"], cwd=cwd)
    if entered.returncode != 0:
        raise RuntimeError(f"CMUX enter failed for {surface}: {entered.stdout.strip()}")


def format_prompt(message: dict[str, Any]) -> str:
    return "\n".join(
        [
            "CMUX agent handoff:",
            "",
            f"To: {message['to']}",
            f"From: {message['from']}",
            f"Type: {message['type']}",
            f"Message id: {message['id']}",
            f"Created: {message['created_at']}",
            "",
            "Content:",
            message["content"],
            "",
            "If you act on this handoff, mention the CMUX message id.",
        ]
    )
