# agent-memory

Persistent long-term memory and memory-lifecycle services for AI assistants.

The repo has two main layers:

- **Hippocampus** is the storage and retrieval service. It exposes a small HTTP API over Mem0, with local SQLite/in-memory fallbacks.
- **Memory Governor** is the policy layer in front of it. It decides what should become durable memory, tracks recall and outcome signals, consolidates working observations, and drives the dreaming/reflection lifecycle.

Older docs and service names may still use **Sacred Brain**; that is the historical deployment name, while `agent-memory` is the repository and subsystem boundary.

## Features

- Store and semantically retrieve durable memories with provenance and metadata.
- Observe high-volume agent activity without turning the memory store into a transcript archive.
- Promote, consolidate, rerank, prune, and protect memories using recall, relevance, recency, query diversity, confidence, and outcome signals.
- Keep short-lived working observations separate from durable memory.
- Run nightly dreaming/reflection over recent activity and recalled memories.
- Fall back to local SQLite or in-memory storage when the configured Mem0 backend is unavailable.
- Expose CLI, HTTP, MCP, hook, bot, and file/org integration surfaces without making any one agent harness the source of truth.
- Include pytest coverage for the Hippocampus API, Governor, dreaming, recall statistics, scopes, routing, and related lifecycle behaviour.

## Getting Started

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export HIPPOCAMPUS_CONFIG=config/hippocampus.toml
uvicorn brain.hippocampus.app:app --reload
```

If Mem0 is offline (or not yet installed), the service automatically falls back
to an in-memory store, ensuring Hippocampus keeps accepting requests. You can
also opt into the bundled SQLite backend for persistence if desired.

## Configuration

Configuration is loaded from `config/hippocampus.toml` and can be overridden
with environment variables prefixed by `HIPPOCAMPUS_` (for example,
`HIPPOCAMPUS_MEM0_BACKEND_URL`). See `brain/hippocampus/config.py` for the full
set of options. The default expectation is that you self-host Mem0 on the same
LAN/VPN:

```toml
[auth]
enabled = false
header_name = "X-API-Key"
api_keys = []

[mem0]
enabled = true
backend = "remote"          # or "memory"/"sqlite"
backend_url = "http://localhost:8888"
api_key = ""                # optional, for your self-hosted deployment
```

If `enabled = false` (or the remote host fails), the adapter falls back to the
in-memory store so Hippocampus remains responsive. The SQLite backend is still
available for teams that want persistence without Mem0.

If you have a local LLM (e.g., Ollama), enable the `[mem0].api_key` or
the `HIPPOCAMPUS_MEM0_API_KEY` environment variable so the adapter can initialise
the official `MemoryClient` SDK. Without a key the service automatically falls
back to SQLite or in-memory storage.

## Running Tests

```bash
source .venv/bin/activate
pytest
```

## Ops

- `ops/scripts/dev_run.sh` starts the app with sensible defaults.
- `ops/systemd/hippocampus.service` can be dropped into `/etc/systemd/system`
  as a starting point for Raspberry Pi deployments.
- `ops/systemd/baibot-compose.service` + `ops/compose/baibot/docker-compose.yml`
  run a local TTS/STT helper (see `docs/BAIBOT.md`).
- `ops/mem0/prepare_mem0_source.sh` clones/updates the official Mem0 repo into
  `ext/mem0`. Use the upstream `ext/mem0/server/docker-compose.yaml` to launch
  Mem0 + Postgres + Neo4j (see `docs/MEM0_SELF_HOSTING.md` for commands).

## Mem0 Self-Hosting

To wire Hippocampus to a local Mem0 deployment:

1. `cd ops/mem0 && ./prepare_mem0_source.sh`
2. `cd ext/mem0/server && cp .env.example .env` (set `OPENAI_API_KEY` and optional `MEM0_API_KEY`)
3. `OPENAI_API_KEY=... docker compose up -d` (brings up Mem0 + Postgres + Neo4j on port 8888)
4. Update `config/hippocampus.toml` (or env vars) so `[mem0]` has `enabled = true`
   and `backend_url = "http://127.0.0.1:8888"`.
5. Start Hippocampus via `uvicorn` or the systemd unit.
6. To verify fallback behaviour, stop Mem0 (`docker compose stop`), issue
   API calls (service stays up using in-memory storage), then `docker compose start`
   and confirm the warnings disappear. Mem0’s REST API doesn’t expose a `/health`
   route; use `/docs` or a `/memories` request to confirm it’s responding.

See `docs/MEM0_SELF_HOSTING.md` for the step-by-step walkthrough, health checks,
and troubleshooting tips.

## Summarizer (optional)

Add this block to `config/hippocampus.toml` (or set the corresponding `HIPPOCAMPUS_SUMMARIZER_*` env vars) to enable Litellm/Ollama summaries:

```toml
[summarizer]
enabled = false
provider = "litellm"
model = "ollama:llama3"
base_url = "http://localhost:11434"
api_key = ""
max_tokens = 512
```

When disabled, `/summaries` falls back to the built-in truncation helper.

## Agno agent (optional)

Set `[agno].enabled = true` to wrap Hippocampus in an Agno agent for richer
orchestration (tool calls for memory read/write + summarisation). `/matrix/respond`
will route through the Agno agent when available; otherwise it uses the direct
summariser fallback. You’ll need the model-specific dependencies (e.g., `openai`
or `ollama`) installed for the chosen `[agno].model` provider.

## Sam LLM (optional)

Sam’s LLM client is configured via env vars (see `docs/SAM_LLM.md`). For direct
providers with different model IDs per endpoint, you can set
`SAM_LLM_MODEL_MAP` to a JSON map of `base_url` → `model` (for example,
`{"https://llm.ryer.org/v1":"/content/models/deepseek.gguf"}`). `SAM_LLM_MODEL`
still overrides the map when set.

## Org-roam / Denote bridge

Export all Mem0 memories into Denote-compatible Org files (usable by
org-roam), and import hand-written notes back into Mem0:

```bash
python scripts/mem0_org_sync.py export --dir data/memories-denote --user alice
python scripts/mem0_org_sync.py import --dir data/memories-denote --user alice
```

Files are idempotent and get `:MEM0_ID:`/`:ID:` properties so repeated syncs do
not duplicate. See `docs/MEM0_ORG_ROAM.md` for the format and options.

## Model gateway boundary

`agent-memory` does not own provider routing. Optional LLM-backed summarisation, reflection, and related jobs talk to an OpenAI-compatible endpoint; the fleet's canonical routing and provider ownership live in [`agent-gateway`](https://github.com/davidj4tech/agent-gateway).

Hippocampus and the Governor remain independent services: callers use their memory APIs directly, and changing the model gateway does not change the memory store. Legacy LiteLLM notes remain under `docs/` as deployment/history references.

## Logging to Hippocampus
- Client-agnostic logging examples (curl/Python) are in `docs/LOGGING_TO_HIPPOCAMPUS.md`.
- OpenWebUI-specific auto-logging webhook is removed; use `/ingest`.

## Memory Governor

See `docs/MEMORY_GOVERNOR.md` for the Agno/Mem0-based decision layer in front of Hippocampus, including setup, systemd units, and smoke tests.

## Current edges

- Continue hardening authentication and per-caller access control before broader multi-user deployment.
- Keep the Governor/Hippocampus boundary explicit as lifecycle policy evolves.
- Consolidate older Sacred Brain and LiteLLM-era documentation as the current deployment shape settles.


## Matrix Bot

See `bots/matrix/MENTION_BOT.md` for setup (matrix-nio mention/DM bot with optional TTS/STT).

## Matrix Bridges

Binary installs live in `/opt/mautrix-*` with configs in `/etc/matrix-bridges` and data/logs in
`/var/lib/mautrix-*`. See `docs/MATRIX_BRIDGES.md` for the bridge layout and Synapse integration.
## Codex Session Memory

Use `scripts/codex_log.py` to append major decisions so future Codex sessions can restore context. Example:

```bash
source .venv/bin/activate
python scripts/codex_log.py add "Matrix mention bot deployed via systemd" ops/systemd/matrix-bot.service
python scripts/codex_log.py recent --limit 5
```

When restarting Codex, run `python scripts/codex_log.py recent --limit 5` and paste the output into the prompt. The same entries are also pushed to Mem0 (if `MEM0_API_KEY` is set) for semantic retrieval.

To avoid dragging long transcripts back in, summarise the latest Codex log into `codex/session_memory.md` with:

```bash
python scripts/codex_summarize_session.py --dry-run   # inspect the summary it will write
python scripts/codex_summarize_session.py             # append summary + inferred files
```

This helper scans the most recent `.codex/session-*.log`, pulls out the key bullets, and appends a compact entry so new Codex sessions can start fresh without `codexctl resume`.
`codexctl` now runs this automatically on exit when it finds the helper; set `CODEX_AUTOSUMMARY=0` to skip.

## Git Hooks

Enable automatic Codex session logging after each commit:

```bash
git config core.hooksPath .githooks
```

The `post-commit` hook runs `scripts/codex_log.py add ...` using your commit summary and changed files. This keeps `codex/session_memory.md` and Mem0 in sync without manual commands.
