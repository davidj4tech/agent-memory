"""REM reflection step — nightly narrative dream entry (Task 009).

A small, read-only Haiku call that summarises what the memory system
"experienced" in the last 24h: stream events, today's promotions, and the
top-recalled memories. Writes a narrative entry through
`dream.write_dream_entry` — it never mutates the memory store.

IO lives at the edges:
- `gather_rem_inputs` — read-only; pulls from stream_log + store.
- `build_rem_messages` / `format_dream_entry` — pure string shaping.
- `call_haiku_reflection` — the single HTTP call (LiteLLM gateway).

Everything else is plain data so tests can drive the pipeline without an
LLM.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from typing import Any

import httpx

REM_MODEL = "claude-opus-4-8-liberated"
REM_MAX_TOKENS = 1024
REM_TIMEOUT_S = 30.0

REM_SYSTEM = (
    "You are the reflective layer of a memory system. Each night you read a "
    "sample of the day's activity — stream events, newly promoted memories, "
    "and the most-recalled entries — and write a short narrative that a "
    "human operator can skim to understand what the system is currently "
    "paying attention to. Be concrete: name specific memories or topics. "
    "Do not invent facts that are not in the inputs. If the inputs are "
    "sparse or empty, say so plainly."
)

REM_RUBRIC = (
    "Structure your reflection as 2-4 short paragraphs (~300-500 words total):\n"
    "  1. Themes — what topics dominated today's stream and recalls.\n"
    "  2. New promotions — what the sweep decided to reinforce today, and why\n"
    "     those look sensible (or not) given the recent activity.\n"
    "  3. Tension / gaps — memories that keep getting recalled but never\n"
    "     promoted, or promoted memories that look stale. Optional.\n"
    "If an Oracle block is provided (sky + tarot), let it color the *tone* of\n"
    "the reflection only — it is flavor, not fact. Never invent memory content\n"
    "or events to match the omen; do not state the card or planetary positions\n"
    "as if they caused anything.\n"
    "Write in plain prose. No headings, no bullet lists, no code fences."
)


@dataclass
class RemInputs:
    stream_events: list[dict[str, Any]] = field(default_factory=list)
    promoted_today: list[dict[str, Any]] = field(default_factory=list)
    top_recalled: list[dict[str, Any]] = field(default_factory=list)
    now_ts: int = 0

    @property
    def event_count(self) -> int:
        return len(self.stream_events)

    @property
    def is_empty(self) -> bool:
        return not (self.stream_events or self.promoted_today or self.top_recalled)


def _read_stream_since(path, cutoff_ts: int) -> list[dict[str, Any]]:
    """Read stream_log JSONL and return records with timestamp >= cutoff."""
    try:
        raw = path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError):
        return []
    out: list[dict[str, Any]] = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if int(obj.get("timestamp", 0)) >= cutoff_ts:
            out.append(obj)
    return out


def gather_rem_inputs(
    store,
    stream_log_path,
    since_hours: int = 24,
    top_k: int = 20,
    now_ts: float | None = None,
    exclude_ids: set[str] | None = None,
    text_by_id: dict[str, str] | None = None,
) -> RemInputs:
    """Assemble REM inputs. Read-only on the memory store.

    exclude_ids: memory ids to drop from promotions + top-recalled (e.g. selftest
    canary seeds), so the reflection doesn't fixate on non-real memories.
    text_by_id: memory id -> text, so top-recalled/promoted rows carry content
    (the reflection can reason about themes, not just UUIDs).
    """
    now = int(now_ts if now_ts is not None else time.time())
    cutoff = now - since_hours * 3600
    exclude = set(exclude_ids or ())

    stream_events = _read_stream_since(stream_log_path, cutoff) if stream_log_path else []

    promoted_today: list[dict[str, Any]] = []
    if hasattr(store, "dreamed_within"):
        for mem_id in store.dreamed_within(cutoff):
            if mem_id in exclude:
                continue
            row = store.get_dream_promotion(mem_id)
            if row:
                promoted_today.append(row)

    top_recalled = []
    if hasattr(store, "top_recalled"):
        # Over-fetch so excluded ids don't shrink the list below top_k.
        rows = store.top_recalled(limit=top_k + len(exclude))
        top_recalled = [r for r in rows if r.get("memory_id") not in exclude][:top_k]

    if text_by_id:
        def _add_text(row):
            mid = row.get("memory_id")
            return {**row, "text": text_by_id[mid]} if mid in text_by_id else row
        promoted_today = [_add_text(r) for r in promoted_today]
        top_recalled = [_add_text(r) for r in top_recalled]

    return RemInputs(
        stream_events=stream_events,
        promoted_today=promoted_today,
        top_recalled=top_recalled,
        now_ts=now,
    )


def _summarise_events(events: list[dict[str, Any]], limit: int = 80) -> str:
    """Compact one-line-per-event summary. Oldest first, truncated."""
    if not events:
        return "(none)"
    events = sorted(events, key=lambda e: e.get("timestamp", 0))[-limit:]
    lines = []
    for ev in events:
        kind = ev.get("kind") or ev.get("event") or "event"
        mem_id = ev.get("memory_id") or ev.get("id") or ""
        q = ev.get("query") or ev.get("text") or ""
        q = (q[:120] + "…") if len(q) > 120 else q
        lines.append(f"- {kind} {mem_id} {q}".strip())
    return "\n".join(lines)


def _summarise_promotions(rows: list[dict[str, Any]]) -> str:
    if not rows:
        return "(none)"
    rows = sorted(rows, key=lambda r: r.get("last_score", 0.0), reverse=True)
    lines = []
    for r in rows:
        line = (f"- {r.get('memory_id','?')} score={r.get('last_score',0.0):.3f} "
                f"count={r.get('dream_count',0)}")
        lines.append(line + _text_suffix(r))
    return "\n".join(lines)


def _text_suffix(row: dict[str, Any], limit: int = 160) -> str:
    """`:: <snippet>` if the row carries memory text, else ''."""
    txt = (row.get("text") or "").replace("\n", " ").strip()
    if not txt:
        return ""
    return " :: " + ((txt[:limit] + "…") if len(txt) > limit else txt)


def _summarise_top_recalled(rows: list[dict[str, Any]]) -> str:
    if not rows:
        return "(none)"
    lines = []
    for r in rows:
        line = f"- {r.get('memory_id','?')} recalls={r.get('recall_count',0)}"
        lines.append(line + _text_suffix(r))
    return "\n".join(lines)


def build_rem_messages(
    inputs: RemInputs,
    oracle: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    """Build Anthropic-style messages with cache_control on system + rubric.

    LiteLLM passes `cache_control` through to Anthropic for Claude models.
    System prompt + rubric are stable across nights (cache-friendly);
    the data block is per-night (no cache marker).
    """
    oracle_section = ""
    if oracle:
        from memory_governor.oracle import format_oracle_block
        oracle_section = "# Oracle (tonight's influences)\n" + format_oracle_block(oracle) + "\n\n"

    data_block = (
        oracle_section
        + "# Stream events (last 24h)\n"
        f"{_summarise_events(inputs.stream_events)}\n\n"
        "# Promotions today\n"
        f"{_summarise_promotions(inputs.promoted_today)}\n\n"
        "# Top-recalled memories\n"
        f"{_summarise_top_recalled(inputs.top_recalled)}\n"
    )

    system = [
        {"type": "text", "text": REM_SYSTEM, "cache_control": {"type": "ephemeral"}},
        {"type": "text", "text": REM_RUBRIC, "cache_control": {"type": "ephemeral"}},
    ]
    user = [{"type": "text", "text": data_block}]

    return [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]


def call_haiku_reflection(
    messages: list[dict[str, Any]],
    *,
    litellm_base_url: str,
    litellm_api_key: str | None = None,
    model: str = REM_MODEL,
    max_tokens: int = REM_MAX_TOKENS,
    timeout_s: float = REM_TIMEOUT_S,
) -> str:
    """Call the reflection model through LiteLLM. Returns the text reply."""
    headers = {"Content-Type": "application/json"}
    if litellm_api_key:
        headers["Authorization"] = f"Bearer {litellm_api_key}"
    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
    }
    with httpx.Client(timeout=timeout_s) as client:
        resp = client.post(
            f"{litellm_base_url.rstrip('/')}/v1/chat/completions",
            json=payload,
            headers=headers,
        )
        resp.raise_for_status()
        data = resp.json()
    return data["choices"][0]["message"]["content"]


def format_dream_entry(
    reflection_text: str,
    inputs: RemInputs,
    *,
    model: str = REM_MODEL,
    oracle: dict[str, Any] | None = None,
) -> str:
    """Wrap the model reply with YAML frontmatter."""
    # Local date, not UTC: the sweep runs at 03:00 local, and a UTC name would
    # file it under the previous day (and a daytime re-run would overwrite it).
    date = time.strftime("%Y-%m-%d", time.localtime(inputs.now_ts or time.time()))
    lines = [
        "---",
        f"date: {date}",
        f"promoted_count: {len(inputs.promoted_today)}",
        f"reflection_model: {model}",
        f"input_event_count: {inputs.event_count}",
    ]
    if oracle:
        astro = oracle.get("astro") or {}
        tarot = oracle.get("tarot") or {}
        lines.append(f"astro_mode: {astro.get('mode', 'unavailable')}")
        if astro.get("precision"):
            lines.append(f"astro_precision: {astro['precision']}")
        if astro.get("sun_sign"):
            lines.append(f"sun_sign: {astro['sun_sign']}")
        if astro.get("moon_sign"):
            lines.append(f"moon_sign: {astro['moon_sign']}")
        if astro.get("moon_phase"):
            lines.append(f"moon_phase: {astro['moon_phase']}")
        if tarot.get("card"):
            orient = "reversed" if tarot.get("reversed") else "upright"
            lines.append(f"tarot_card: {tarot['card']} ({orient})")
    lines.append("---\n")
    front = "\n".join(lines) + "\n"
    return front + reflection_text.strip() + "\n"
