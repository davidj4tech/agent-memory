# agent-memory healthcheck

`scripts/agent-memory-healthcheck` is a oneshot watcher that runs hourly and
reports on the health of the dream sweep and consolidation pipeline. It is
**user-scoped** on the live deployment: it calls `systemctl --user`, reads
state under `~/.local/state/agent-memory`, and is driven by the units in
[`ops/systemd/user/`](../ops/systemd/user/).

## What it checks

| Check | Severity |
| --- | --- |
| `hippocampus.service` / `memory-governor.service` not active | hard |
| `claude-memory-sync.timer` not scheduled, or its last run failed | hard |
| Newest memory older than `AGENT_MEMORY_HEALTH_STORE_STALE_HOURS` | soft |
| `agent-memory-dream.timer` not listed/active | hard |
| No successful `/consolidate` in the recent journal window | hard |
| Recent `/consolidate` 4xx/5xx failures | hard |
| Newest dream file older than `AGENT_MEMORY_HEALTH_DREAM_STALE_HOURS` (sweep stalled) | hard |
| Dream files missing `promoted_count` frontmatter (malformed output) | hard |
| Zero-promotion streak **with** real input over the window | hard |
| Zero-promotion streak on a **quiet** stream (few/no input events) | soft |

## Soft vs hard: the zero-promotion policy

A run of nights where the dream sweep promotes nothing is only a genuine
incident if the sweep actually had signal to work with. The script gates on the
cumulative `input_event_count` across the streak window:

- `total_inputs >= AGENT_MEMORY_HEALTH_ZERO_PROMOTION_MIN_INPUTS` (default `5`)
  → **hard**: the sweep is overlooking real signal. Fails the unit and alerts.
- `total_inputs <` threshold
  → **soft**: the stream was simply quiet; promoting nothing is the correct
    call. Printed to the journal as a non-failing notice, exit `0`, no page.

This keeps genuine breakage (stalled/missing runs, service down, malformed
output, exceptions, or overlooked signal) loud, while an idle stream stays
quiet instead of failing the unit every hour.

## Why the sync and freshness checks exist

Watching only the long-running services misses the failure that actually
happened: `claude-memory-sync` died on 2026-07-29 and nothing noticed for 30
days, because `hippocampus.service` and `memory-governor.service` stayed
green the whole time while nothing was being ingested.

Two checks close that. `claude-memory-sync` is a **timer-driven oneshot**, so
`is-active` reads `inactive` between runs and tells you nothing — the check
looks at its last `Result` plus the timer still being scheduled, and treats a
failed run as hard. Store freshness is the backstop for the same shape of
failure arriving by another route: everything green, nothing landing. That one
is **soft**, because a genuinely quiet stretch is not an incident.

## Environment knobs

Knobs are read as `AGENT_MEMORY_HEALTH_<NAME>`. The historical `SB_HEALTH_*`
and `SACRED_BRAIN_HEALTH_*` spellings are still honoured as fallbacks, so
overrides set outside this repo keep working; the `AGENT_MEMORY_HEALTH_` name
wins when more than one is set.

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGENT_MEMORY_HEALTH_ZERO_PROMOTION_STREAK` | `3` | Consecutive zero-promotion nights before flagging |
| `AGENT_MEMORY_HEALTH_ZERO_PROMOTION_MIN_INPUTS` | `5` | Cumulative input events over the window that makes a zero streak hard |
| `AGENT_MEMORY_HEALTH_DREAM_STALE_HOURS` | `48` | Newest dream file older than this is a stalled sweep (hard) |
| `AGENT_MEMORY_HEALTH_JOURNAL_WINDOW` | `2 hours ago` | `--since` window for the `/consolidate` journal check |
| `AGENT_MEMORY_HEALTH_ALERT_COOLDOWN_SECONDS` | `21600` | Suppress duplicate Matrix/wall alerts within this window |
| `AGENT_MEMORY_HEALTH_REPORT_ONLY` | unset | If `1`, exit non-zero on hard warnings but skip alerting (dry run) |
| `AGENT_MEMORY_HEALTH_SYNC_UNIT` | `claude-memory-sync.service` | Ingest oneshot whose last result is checked |
| `AGENT_MEMORY_HEALTH_SYNC_TIMER` | `claude-memory-sync.timer` | Timer that must still be scheduled |
| `AGENT_MEMORY_HEALTH_STORE_PATH` | `~/.local/state/agent-memory/hippocampus/hippocampus_memories.sqlite` | Store checked for freshness |
| `AGENT_MEMORY_HEALTH_STORE_STALE_HOURS` | `72` | Newest memory older than this raises a soft notice |
| `DREAMS_OUTPUT_PATH` | `~/.local/state/agent-memory/dreams` | Dream markdown directory |
| `MG_STATE_DIR` | `~/.local/state/agent-memory/governor` | Alert cooldown state |
| `AGENT_MEMORY_HEALTH_MATRIX` | unset | If `1`, send hard warnings to Matrix |
| `AGENT_MEMORY_HEALTH_WALL` | unset | If `1`, `wall` hard warnings to logged-in users |

## User-mode install (live deployment)

The system `Makefile` installs everything to `/etc/systemd/system` under the
`sacred` service user. The live red5 box instead runs the whole stack in
**user mode**, so the healthcheck is deployed by hand:

```bash
# script on PATH
install -m 0755 scripts/agent-memory-healthcheck ~/.local/bin/agent-memory-healthcheck

# user units
install -m 0644 ops/systemd/user/agent-memory-healthcheck.service ~/.config/systemd/user/
install -m 0644 ops/systemd/user/agent-memory-healthcheck.timer   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now agent-memory-healthcheck.timer
```

Run it by hand (dry, no alerts):

```bash
AGENT_MEMORY_HEALTH_REPORT_ONLY=1 AGENT_MEMORY_HEALTH_MATRIX=0 AGENT_MEMORY_HEALTH_WALL=0 \
  ~/.local/bin/agent-memory-healthcheck
```
