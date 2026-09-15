#!/usr/bin/env bash
# governor_precompact.sh — Claude Code hook that feeds the Memory Governor.
#
# Wired as a Stop, PreCompact and SessionEnd hook. Reads the transcript path
# from the hook's JSON input on stdin, extracts the conversation text (user +
# assistant turns, not the JSONL scaffolding) added since this script last
# posted for that transcript, and POSTs it to the Governor's /observe endpoint.
# /observe is the ONLY input to the governor's working memory: without it,
# working_events stays empty and the hourly /consolidate and nightly dream
# sweep have nothing to promote.
#
# Delta tracking: ~/.local/state/agent-memory/bridge-state/<transcript>.json
# records the transcript line count + time of the last successful post, so
# Stop (every turn), PreCompact and SessionEnd never re-post the same text.
# The first post for a transcript sends the last ~2000 words, as before.
#
# Stop is throttled: at most one post per GOVERNOR_STOP_MIN_INTERVAL seconds
# (default 900) per transcript, and only when at least GOVERNOR_STOP_MIN_WORDS
# (default 150) new words have accumulated. Long tmux sessions that never end
# or compact still feed the governor this way. PreCompact/SessionEnd are not
# throttled and post any delta of GOVERNOR_END_MIN_WORDS (default 20) words.
#
# Logs to ~/.local/state/agent-memory/claude-bridge.log and never fails
# loudly — a turn, compaction or session end must proceed regardless.

set -u

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-memory"
LOG="${LOG_DIR}/claude-bridge.log"
mkdir -p "$LOG_DIR"

log() { printf '%s observe: %s\n' "$(date -Iseconds)" "$*" >> "$LOG"; }

STATE_DIR="${LOG_DIR}/bridge-state"
mkdir -p "$STATE_DIR"
STOP_MIN_INTERVAL="${GOVERNOR_STOP_MIN_INTERVAL:-900}"
STOP_MIN_WORDS="${GOVERNOR_STOP_MIN_WORDS:-150}"
END_MIN_WORDS="${GOVERNOR_END_MIN_WORDS:-20}"

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

export USER_ID PROJECT EVENT TRANSCRIPT STATE_DIR STOP_MIN_INTERVAL STOP_MIN_WORDS END_MIN_WORDS

# Extract conversation text from the JSONL transcript and build the payload.
# Only user and assistant text blocks count; tool calls, tool results and
# system/meta lines are skipped. Only lines after the last posted line count
# (per-transcript state file) are considered; a first post keeps the last
# 2000 words. Exit codes: 3 = nothing (new) to post, 4 = throttled.
BODY="$(python3 - <<'PY'
import json, os, sys, time
path = os.environ["TRANSCRIPT"]
event = os.environ["EVENT"]
state_path = os.path.join(os.environ["STATE_DIR"], os.path.basename(path) + ".json")
try:
    with open(state_path, encoding="utf-8") as fh:
        state = json.load(fh)
except Exception:
    state = {}
start_line = int(state.get("lines") or 0)
last_ts = float(state.get("ts") or 0)
now = time.time()
if event == "stop" and now - last_ts < float(os.environ["STOP_MIN_INTERVAL"]):
    sys.exit(4)
min_words = int(os.environ["STOP_MIN_WORDS"] if event == "stop" else os.environ["END_MIN_WORDS"])

words = []
n = 0
with open(path, encoding="utf-8", errors="replace") as fh:
    for n, line in enumerate(fh, 1):
        if n <= start_line:
            continue
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
if n < start_line:          # transcript was truncated/replaced: start over
    start_line = 0
if len(words) < min_words:
    sys.exit(3)
tail = " ".join(words[-2000:])
user = os.environ["USER_ID"]; project = os.environ["PROJECT"]
print(json.dumps({
    "source": f"claude-code:{event}",
    "user_id": user,
    "text": tail,
    "scope": {"kind": "project", "id": project,
              "parent": {"kind": "user", "id": user, "parent": None}},
    "metadata": {"origin": "claude-code", "event": event,
                 "session_transcript": os.path.basename(path),
                 "transcript_lines": [start_line + 1, n], "delta_words": len(words)},
}))
# Provisional state; the shell rewrites it only after a successful POST.
with open(state_path + ".next", "w", encoding="utf-8") as fh:
    json.dump({"lines": n, "ts": now}, fh)
PY
)"
rc=$?
STATE_FILE="$STATE_DIR/$(basename "$TRANSCRIPT").json"
if [[ $rc -eq 4 ]]; then exit 0; fi   # stop: throttled, silent
if [[ $rc -eq 3 ]]; then
  [[ "$EVENT" != "stop" ]] && log "no new conversation text since last post event=$EVENT; exit 0"
  rm -f "$STATE_FILE.next"; exit 0
fi
if [[ $rc -ne 0 || -z "$BODY" ]]; then log "body build failed (rc=$rc)"; rm -f "$STATE_FILE.next"; exit 0; fi

HDRS=(-H "Content-Type: application/json")
[[ -n "$API_KEY" ]] && HDRS+=(-H "X-API-Key: $API_KEY")

if curl -sS --max-time 5 "${HDRS[@]}" -X POST "$GOVERNOR_URL/observe" -d "$BODY" >/dev/null 2>&1; then
  mv -f "$STATE_FILE.next" "$STATE_FILE" 2>/dev/null || true
  log "posted ${#BODY} bytes event=$EVENT project=$PROJECT user=$USER_ID"
else
  rm -f "$STATE_FILE.next"
  log "POST /observe failed (non-fatal) event=$EVENT"
fi

exit 0
