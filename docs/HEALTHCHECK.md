# Sacred Brain healthcheck

`scripts/sacred-brain-healthcheck` is a oneshot watcher that runs hourly and
reports on the health of the dream sweep and consolidation pipeline. It is
**user-scoped** on the live deployment: it calls `systemctl --user`, reads
state under `~/.local/state/sacred-brain`, and is driven by the units in
[`ops/systemd/user/`](../ops/systemd/user/).

## What it checks

| Check | Severity |
| --- | --- |
| `hippocampus.service` / `memory-governor.service` not active | hard |
| `sacred-brain-dream.timer` not listed/active | hard |
| No successful `/consolidate` in the recent journal window | hard |
| Recent `/consolidate` 4xx/5xx failures | hard |
| Newest dream file older than `SB_HEALTH_DREAM_STALE_HOURS` (sweep stalled) | hard |
| Dream files missing `promoted_count` frontmatter (malformed output) | hard |
| Zero-promotion streak **with** real input over the window | hard |
| Zero-promotion streak on a **quiet** stream (few/no input events) | soft |

## Soft vs hard: the zero-promotion policy

A run of nights where the dream sweep promotes nothing is only a genuine
incident if the sweep actually had signal to work with. The script gates on the
cumulative `input_event_count` across the streak window:

- `total_inputs >= SB_HEALTH_ZERO_PROMOTION_MIN_INPUTS` (default `5`)
  → **hard**: the sweep is overlooking real signal. Fails the unit and alerts.
- `total_inputs <` threshold
  → **soft**: the stream was simply quiet; promoting nothing is the correct
    call. Printed to the journal as a non-failing notice, exit `0`, no page.

This keeps genuine breakage (stalled/missing runs, service down, malformed
output, exceptions, or overlooked signal) loud, while an idle stream stays
quiet instead of failing the unit every hour.

## Environment knobs

| Variable | Default | Meaning |
| --- | --- | --- |
| `SB_HEALTH_ZERO_PROMOTION_STREAK` | `3` | Consecutive zero-promotion nights before flagging |
| `SB_HEALTH_ZERO_PROMOTION_MIN_INPUTS` | `5` | Cumulative input events over the window that makes a zero streak hard |
| `SB_HEALTH_DREAM_STALE_HOURS` | `48` | Newest dream file older than this is a stalled sweep (hard) |
| `SB_HEALTH_JOURNAL_WINDOW` | `2 hours ago` | `--since` window for the `/consolidate` journal check |
| `SB_HEALTH_ALERT_COOLDOWN_SECONDS` | `21600` | Suppress duplicate Matrix/wall alerts within this window |
| `SB_HEALTH_REPORT_ONLY` | unset | If `1`, exit non-zero on hard warnings but skip alerting (dry run) |
| `DREAMS_OUTPUT_PATH` | `~/.local/state/sacred-brain/dreams` | Dream markdown directory |
| `MG_STATE_DIR` | `~/.local/state/sacred-brain/governor` | Alert cooldown state |
| `SACRED_BRAIN_HEALTH_MATRIX` | unset | If `1`, send hard warnings to Matrix |
| `SACRED_BRAIN_HEALTH_WALL` | unset | If `1`, `wall` hard warnings to logged-in users |

## User-mode install (live deployment)

The system `Makefile` installs everything to `/etc/systemd/system` under the
`sacred` service user. The live red5 box instead runs the whole stack in
**user mode**, so the healthcheck is deployed by hand:

```bash
# script on PATH
install -m 0755 scripts/sacred-brain-healthcheck ~/.local/bin/sacred-brain-healthcheck

# user units
install -m 0644 ops/systemd/user/sacred-brain-healthcheck.service ~/.config/systemd/user/
install -m 0644 ops/systemd/user/sacred-brain-healthcheck.timer   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now sacred-brain-healthcheck.timer
```

Run it by hand (dry, no alerts):

```bash
SB_HEALTH_REPORT_ONLY=1 SACRED_BRAIN_HEALTH_MATRIX=0 SACRED_BRAIN_HEALTH_WALL=0 \
  ~/.local/bin/sacred-brain-healthcheck
```
