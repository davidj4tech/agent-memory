#!/usr/bin/env bash
# governor_precompact.sh — Claude Code hook that feeds the Memory Governor.
#
# Wired as both a PreCompact and a SessionEnd hook. Reads the transcript path
# from the hook's JSON input on stdin, extracts the last ~2000 words of
# conversation text (user + assistant turns, not the JSONL scaffolding) and
# POSTs it to the Governor's /observe endpoint. /observe is the ONLY input to
# the governor's working memory: without it, working_events stays empty and
# the hourly /consolidate and nightly dream sweep have nothing to promote.
#
# Logs to ~/.local/state/agent-memory/claude-bridge.log and never fails
# loudly — compaction / session end must proceed regardless.

set -u

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-memory"
LOG="${LOG_DIR}/claude-bridge.log"
mkdir -p "$LOG_DIR"

log() { printf '%s observe: %s\n' "$(date -Iseconds)" "$*" >> "$LOG"; }

for f in "$HOME/.config/hippocampus.env" "$HOME/.config/agent-memory.env"; do
  if [[ -r "$f" ]]; then
    set -a; . "$f"; set +a
    break
  fi
done

GOVERNOR_URL="${AGENT_MEMORY_GOVERNOR_URL:-${GOVERNOR_URL:-http://127.0.0.1:54323}}"
API_KEY="${AGENT_MEMORY_API_KEY:-${GOVERNOR_API_KEY:-${HIPPOCAMPUS_API_KEY:-}}}"
USER_ID="${AGENT_MEMORY_USER_ID:-${GOVERNOR_USER_ID:-ryer}}"
PROJECT="$(basename "$PWD")"

# Hook input: a JSON object on stdin (transcript_path + hook_event_name), or
# CLAUDE_TRANSCRIPT env, or $1.
TRANSCRIPT=""
EVENT="precompact"
if [[ -n "${CLAUDE_TRANSCRIPT:-}" ]]; then
  TRANSCRIPT="$CLAUDE_TRANSCRIPT"
elif [[ $# -ge 1 && -r "$1" ]]; then
  TRANSCRIPT="$1"
else
  HOOK_JSON="$(cat || true)"
  if [[ -n "$HOOK_JSON" ]]; then
    read -r TRANSCRIPT EVENT < <(printf '%s' "$HOOK_JSON" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("transcript_path") or d.get("transcript") or "", (d.get("hook_event_name") or "precompact").lower())
except Exception:
    print("", "precompact")' 2>/dev/null)
  fi
fi

if [[ -z "$TRANSCRIPT" || ! -r "$TRANSCRIPT" ]]; then
  log "no readable transcript (arg=$*, env=${CLAUDE_TRANSCRIPT:-}); exit 0"
  exit 0
fi

export USER_ID PROJECT EVENT TRANSCRIPT

# Extract conversation text from the JSONL transcript and build the payload.
# Only user and assistant text blocks count; tool calls, tool results and
# system/meta lines are skipped. Keeps the last 2000 words.
BODY="$(python3 - <<'PY'
import json, os, sys
path = os.environ["TRANSCRIPT"]
words = []
with open(path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        try:
            d = json.loads(line)
        except Exception:
            continue
        role = d.get("type")
        if role not in ("user", "assistant") or d.get("isMeta"):
            continue
        content = (d.get("message") or {}).get("content")
        if isinstance(content, str):
            parts = [content]
        elif isinstance(content, list):
            parts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
        else:
            continue
        text = " ".join(p for p in parts if p).strip()
        if not text or text.startswith("<") and text.endswith(">") and "system-reminder" in text:
            continue
        words.extend((f"[{role}]",) + tuple(text.split()))
tail = " ".join(words[-2000:])
if not tail.strip():
    sys.exit(3)
user = os.environ["USER_ID"]; project = os.environ["PROJECT"]; event = os.environ["EVENT"]
print(json.dumps({
    "source": f"claude-code:{event}",
    "user_id": user,
    "text": tail,
    "scope": {"kind": "project", "id": project,
              "parent": {"kind": "user", "id": user, "parent": None}},
    "metadata": {"origin": "claude-code", "event": event,
                 "session_transcript": os.path.basename(path)},
}))
PY
)"
rc=$?
if [[ $rc -eq 3 ]]; then log "transcript has no conversation text; exit 0"; exit 0; fi
if [[ $rc -ne 0 || -z "$BODY" ]]; then log "body build failed (rc=$rc)"; exit 0; fi

HDRS=(-H "Content-Type: application/json")
[[ -n "$API_KEY" ]] && HDRS+=(-H "X-API-Key: $API_KEY")

if curl -sS --max-time 5 "${HDRS[@]}" -X POST "$GOVERNOR_URL/observe" -d "$BODY" >/dev/null 2>&1; then
  log "posted ${#BODY} bytes event=$EVENT project=$PROJECT user=$USER_ID"
else
  log "POST /observe failed (non-fatal) event=$EVENT"
fi

exit 0
