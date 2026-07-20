# Task: agent-memory compatibility rename (done)

## Context
Sacred Brain is the live memory plane, but the cross-agent fleet is converging on the neutral name `agent-memory`. The rename should be additive first: keep Sacred Brain commands, env vars, service names, config paths, and state paths working while adding neutral aliases.

## Goal
Operators and coding agents can use `agent-memory-*` commands and `AGENT_MEMORY_*` env vars without breaking existing Sacred Brain deployments.

## Requirements
- Add user-facing `agent-memory` aliases; do not remove `sacred-*` commands.
- Prefer `AGENT_MEMORY_*` env vars when present, with legacy `HIPPOCAMPUS_*`, `GOVERNOR_*`, and `SACRED_MCP_*` names as fallbacks.
- Do not rename systemd units, state directories, config directories, Python package names, or API endpoints in this task.
- Keep `/observe`, `/recall`, `/outcome`, and `/memories` wire contracts stable.
- Update agent-facing docs so new sessions learn `agent-memory-search` first and `sacred-search` as a legacy alias.

## Suggested Steps
1. Add `scripts/agent-memory-search` as a thin alias to `scripts/sacred-search`.
2. Teach shell/Python helpers to read `AGENT_MEMORY_HIPPOCAMPUS_URL`, `AGENT_MEMORY_GOVERNOR_URL`, `AGENT_MEMORY_API_KEY`, and `AGENT_MEMORY_USER_ID` before legacy names.
3. Update MCP stdio config to accept the same neutral env aliases.
4. Update `AGENTS.md` and search docs to mention `agent-memory-search` first.
5. Smoke-test syntax and the search alias.

## Validation
- `bash -n scripts/agent-memory-search scripts/sacred-search scripts/governor_context.sh scripts/governor_precompact.sh scripts/_outcome_drain.sh scripts/sacred-mcp-stdio`
- `python3 -m py_compile memory_governor/config.py services/sacred_mcp/stdio.py scripts/memory_sync.py scripts/natal_to_sacred_brain.py scripts/prune_auto_memories.py scripts/sync_claude_memory.py scripts/sacred-brain-explain`
- `AGENT_MEMORY_HIPPOCAMPUS_URL=http://127.0.0.1:54321 scripts/agent-memory-search test sam 1`

## References
- `AGENTS.md`
- `docs/SACRED_SEARCH.md`
- `scripts/sacred-search`
- `services/sacred_mcp/stdio.py`
- `memory_governor/config.py`
