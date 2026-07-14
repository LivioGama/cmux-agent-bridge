#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
from="codex-reviewer"
to="devin-implementer"
type="review_findings"
project_root="${PWD}"
round="1"
queue="1"
dry_run="0"
input_file=""
hardcore="0"

usage() {
  cat <<'USAGE'
Usage:
  cmux-review-loop-send.sh [options] [message]
  cat review.md | cmux-review-loop-send.sh [options]

Options:
  --from AGENT          Sender agent ID (default: codex-reviewer)
  --to AGENT            Receiver agent ID (default: devin-implementer)
  --type TYPE           Message type (default: review_findings)
  --project-root PATH   Project root included in handoff (default: $PWD)
  --round N             Review loop round label (default: 1)
  --file PATH           Read review text from file
  --direct              Send direct instead of queued
  --hardcore            Require an empty review before stopping the loop
  --dry-run             Print message instead of sending
  -h, --help            Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      from="${2:?missing value for --from}"
      shift 2
      ;;
    --to)
      to="${2:?missing value for --to}"
      shift 2
      ;;
    --type)
      type="${2:?missing value for --type}"
      shift 2
      ;;
    --project-root)
      project_root="${2:?missing value for --project-root}"
      shift 2
      ;;
    --round)
      round="${2:?missing value for --round}"
      shift 2
      ;;
    --file)
      input_file="${2:?missing value for --file}"
      shift 2
      ;;
    --direct)
      queue="0"
      shift
      ;;
    --hardcore)
      hardcore="1"
      shift
      ;;
    --dry-run)
      dry_run="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ -n "$input_file" ]]; then
  if [[ ! -f "$input_file" ]]; then
    echo "Input file not found: $input_file" >&2
    exit 2
  fi
  review_text="$(cat "$input_file")"
elif [[ $# -gt 0 ]]; then
  review_text="$*"
else
  review_text="$(cat)"
fi

if [[ -z "${review_text//[[:space:]]/}" ]]; then
  echo "No review text provided" >&2
  exit 2
fi

reply_from="$to"
reply_to="$from"

if [[ "$hardcore" == "1" ]]; then
  stop_mode="- Hardcore mode: keep fixing until the follow-up review has no findings left at all. Suggestions, questions, nits, and verification gaps keep the loop open unless the user cancels."
else
  stop_mode="- Default mode: stop when blockers are gone and concerns are gone, unless the user explicitly accepts or defers a concern."
fi

message="$(cat <<EOF
CMUX review loop handoff

From: ${from}
To: ${to}
Project: ${project_root}
Round: ${round}

Task:
Fix the review findings below. Do not broaden scope. Preserve unrelated work.

Acceptance:
- All blockers fixed at root cause.
- Concerns either fixed or explicitly marked deferred with rationale.
- Relevant verification run and reported.
${stop_mode}
- Reply through:
  cmux-agent-send --queue --from ${reply_from} --to ${reply_to} --type final_handoff "<summary, files changed, validation, blockers>"

Review findings:
${review_text}
EOF
)"

if [[ "$dry_run" == "1" ]]; then
  printf '%s\n' "$message"
  exit 0
fi

if ! command -v cmux-agent-send >/dev/null 2>&1; then
  echo "cmux-agent-send not found. Run setup-cmux-agent-bridge.sh first (from $SKILL_DIR/scripts/)." >&2
  exit 127
fi

args=(--from "$from" --to "$to" --type "$type")
if [[ "$queue" == "1" ]]; then
  args=(--queue "${args[@]}")
fi

cmux-agent-send "${args[@]}" "$message"
