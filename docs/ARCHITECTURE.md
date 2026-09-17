# Architecture

`agent-memory` is the **durable memory plane** for the agent fleet. It owns the
lifecycle after an observation becomes a memory candidate: decide what is worth
keeping, store it, consolidate it, recall it, learn from use, and eventually
prune or protect it.

It deliberately does **not** own transcript history, model/provider routing,
workspace UX, or harness configuration.

## Shape

```text
agent harnesses / agent-config hooks / agent-sessions
                         │
                         │ observe / remember / recall
                         ▼
                 Memory Governor
          policy, working memory, lifecycle
                         │
                         ▼
                    Hippocampus
             storage + semantic retrieval
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
            Mem0             SQLite / memory
         (preferred)           (fallback)

optional LLM-backed jobs ──> OpenAI-compatible endpoint
                            (owned by agent-gateway in the fleet)
```

## Boundary with other repos

- **`agent-sessions`** preserves raw history and normalized provenance. It may
  emit selected `/observe` candidates; it does not decide what becomes durable
  memory.
- **`agent-config`** installs and wires hooks, MCP surfaces, recall helpers, and
  harness-specific integration. It does not own the memory store or policy.
- **`agent-gateway`** owns model/provider routing. Memory components may use its
  OpenAI-compatible endpoint for summarisation or reflection, but provider
  routing is not part of this repo.
- **`agent-workspace`** owns human/harness workspace UX.
- **`agent-media`** owns speech, visuals, and media/device behaviour.

Interfaces across those boundaries should stay coarse: HTTP/MCP calls, files,
CLI commands, and explicit hooks rather than cross-repo Python imports.

## Hippocampus (`brain.hippocampus`)

Hippocampus is the durable storage/retrieval service. `brain.hippocampus.app`
defines the FastAPI surface; `brain.hippocampus.mem0_adapter` hides backend
details behind a predictable interface.

The preferred deployment can use a self-hosted Mem0 backend. If it is
unavailable, the adapter can fall back to local SQLite or in-memory storage so
callers do not have to understand backend failure modes.

Configuration is loaded from TOML plus `HIPPOCAMPUS_*` environment overrides.
Pydantic models keep the external API explicit.

## Memory Governor (`memory_governor`)

The Governor owns memory policy rather than storage mechanics. Its
responsibilities include:

- accepting observations and explicit remembers
- separating short-lived working observations from durable candidates
- salience/promotion decisions and consolidation
- recall reranking and recall-use statistics
- outcome/confidence feedback
- scope handling and provenance
- lifecycle signals used by pruning and dreaming

Hippocampus should remain useful without the Governor; the Governor should
depend on Hippocampus through its public memory interface rather than backend
internals.

## Dreaming and background lifecycle

`agent-memory-dream` scores memories from multiple signals such as recall
frequency, relevance, query diversity, recency, consolidation, and conceptual
richness. Promotions are recorded in a Governor-side ledger rather than
mutating the semantic store in place.

The optional reflection pass reads recent stream activity, promotions, and
high-use memories and writes a narrative dream artifact. Timers and pruning
jobs form part of the same lifecycle, but they remain operational consumers of
the Governor/Hippocampus APIs rather than a second source of truth.

See `DREAMING.md`, `MEMORY_GOVERNOR.md`, and `MEMORY_GOVERNOR_v2.md` for the
detailed policies and evolution notes.

## Model calls

Some optional jobs use an LLM. They are configured against an OpenAI-compatible
endpoint and should not know how the fleet obtains a model. In David's
deployment, that concern belongs to `agent-gateway`. A different installation
can point the same jobs at any compatible endpoint.

## Operations and tests

`ops/` contains service/deployment helpers and systemd units. Console scripts in
`pyproject.toml` provide stable entry points for deployed services and lifecycle
jobs.

`tests/` covers storage behaviour, API routes, Governor scoring/recall/outcomes,
dreaming/reflection, scopes, routing, and operational helpers. Backend fallbacks
allow most of this to run deterministically without network services.
