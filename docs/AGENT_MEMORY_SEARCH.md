# `agent-memory-search` / `sacred-search` — on-demand memory search for coding agents

Thin CLI over Hippocampus's `GET /memories/{user_id}` endpoint. Lets any shell-capable agent (Claude Code, Codex, OpenCode, etc.) pull specific memories mid-session instead of relying on the pre-session context dump.

## Usage

```
agent-memory-search <query> [user_id] [limit]
sacred-search <query> [user_id] [limit]  # legacy alias
```

Defaults: `user_id=ryer,sam`, `limit=5`.

`user_id` accepts a comma-separated list. The default searches both assistant
namespaces and interleaves the hits round-robin before truncating to `limit`
(Hippocampus scores nearly every hit at 1.00, so without the interleave the
first namespace would crowd the others out). `AGENT_MEMORY_SEARCH_USERS`
overrides the default list.

## Examples

```
agent-memory-search "raspberry pi setup"
agent-memory-search "matrix bridge config" ryer 10   # live namespace only
agent-memory-search "xmpp bot" david     # ChatGPT-extracted memories (user:david)
```

## What it hits

- Endpoint: `GET $AGENT_MEMORY_HIPPOCAMPUS_URL/memories/{user_id}?query=...&limit=...` or legacy `GET $HIPPOCAMPUS_URL/memories/{user_id}?query=...&limit=...`
- Port 54321 (Hippocampus), **not** the Governor's `/recall` on 54323.
- This is deliberate: ChatGPT archive memories (source `chatgpt_export` / `chatgpt-export`) are suppressed by the Governor's archive filter when called via `/recall`. Hitting Hippocampus directly bypasses that, which is the point — agents often *want* the archive.

## Environment

Loaded from `~/.config/hippocampus.env` or `~/.config/agent-memory.env`:

| Var | Legacy alias | Default | Notes |
|-----|--------------|---------|-------|
| `AGENT_MEMORY_HIPPOCAMPUS_URL` | `HIPPOCAMPUS_URL` | `http://127.0.0.1:54321` | On non-homer machines, point at homer via Tailscale: `http://100.125.48.108:54321` |
| `AGENT_MEMORY_API_KEY` | `HIPPOCAMPUS_API_KEY` | — | Required when Hippocampus auth is enabled (it is, on homer). |

## user_id cheatsheet

| `user_id` | What's there |
|-----------|--------------|
| `ryer` | **The live namespace.** Everything written since mid-July 2026, when `GOVERNOR_USER_ID`/`SACRED_MCP_DEFAULT_USER_ID` were set to `ryer` in `~/.config/hippocampus.env`. Source `claude-code:sync`. |
| `sam` | The same assistant identity before the host rename; frozen since 2026-07-14. Sam persona memories, incl. raw ChatGPT conversation exports (cron-imported by `chatgpt_export_to_hippocampus.py` at src=`chatgpt_export`) |
| `david` | Memories extracted from ChatGPT history by `scripts/import_chatgpt.py` — typed (`preference`, `project`, `decision`, `fact`, `todo`, etc.) with confidences |
| `mel` | Mel persona |

If you're looking for "that thing I discussed with ChatGPT", try both `sam` (raw transcript chunks) and `david` (distilled structured memories).

## Install

Already installed on homer as `agent-memory-search` and `sacred-search`. For other machines:

```
ln -sf /usr/local/bin/agent-memory-search ~/.local/bin/agent-memory-search
ln -sf /usr/local/bin/sacred-search ~/.local/bin/sacred-search
```

…or include `/usr/local/bin/` in your `$PATH`.

## How agents discover it

The pointer line in the repo-root `AGENTS.md` tells any reading agent (Codex, OpenCode, Claude Code) that `agent-memory-search` exists and when to use it. `sacred-search` remains a compatibility alias.

## Troubleshooting

- **`401 Unauthorized`** — `AGENT_MEMORY_API_KEY` / `HIPPOCAMPUS_API_KEY` missing or wrong. Check `~/.config/hippocampus.env`.
- **`Connection refused`** — Hippocampus isn't running, or `AGENT_MEMORY_HIPPOCAMPUS_URL` / `HIPPOCAMPUS_URL` points at the wrong host. On homer: `systemctl --user status hippocampus` or `curl ${AGENT_MEMORY_HIPPOCAMPUS_URL:-${HIPPOCAMPUS_URL:-http://127.0.0.1:54321}}/health`.
- **No memories found** — try a different `user_id` (see cheatsheet), broaden the query, or increase the limit.

## Related

- `docs/API.md` §`GET /memories/{user_id}` — the underlying endpoint
- `docs/CHATGPT_IMPORT.md` — how ChatGPT memories get into Hippocampus
- `scripts/hippocampus_query.sh` in `sam-runtime` / `openclaw/workspace` — prior art this was adapted from
