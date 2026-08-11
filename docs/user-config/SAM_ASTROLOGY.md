# Sam Astrology (Optional Bias Signals)

Sam can load a small set of “bias signals” derived from a birth timestamp and location. These signals only influence Sam’s internal system prompt; they never surface astrology terms unless explicitly asked.

## Configuration

`config/hippocampus.toml` contains defaults. David's deployment overrides them in `~/.config/agent-memory/hippocampus.toml`:

```toml
[sam.birth]
timestamp = "2026-07-04T23:36:00"
timezone = "Australia/Melbourne"
location_name = "Melbourne, Australia"
latitude = -37.8136
longitude = 144.9631

[sam.astrology]
enabled = true
engine = "swisseph"       # or "fallback"
signals_enabled = true
cache_path = "/home/ryer/.local/state/agent-memory/cache/sam_chart.json"
```

The Governor oracle natal record lives at `~/.local/state/agent-memory/governor/oracle/natal/sam.json`. A copy and identity notes live in `docs/user-config/sam/`.

Env overrides (most common):

- `SAM_ASTROLOGY_ENABLED=true`
- `SAM_ASTROLOGY_ENGINE=swisseph|fallback`
- `SAM_ASTROLOGY_CACHE_PATH=/var/cache/sam_chart.json`
- `SAM_BIRTH_TIMESTAMP`, `SAM_BIRTH_TIMEZONE`, `SAM_BIRTH_LOCATION_NAME`, `SAM_BIRTH_LATITUDE`, `SAM_BIRTH_LONGITUDE`

## Behavior

- When enabled, a chart is computed once and cached to `cache_path`. If Swiss Ephemeris is unavailable, a fallback computes at least the Sun sign (Cancer for the bundled date).
- Signals map to soft tendencies (e.g., synthesis_bias, zoom_out_preference) and are injected as a short “bias note” into Sam’s system prompt.
- No astrology content is emitted to users unless they ask.
- If disabled, nothing changes in Sam responses.

## Troubleshooting

- Delete the cache file to force a recompute.
- Set `SAM_ASTROLOGY_ENABLED=false` to disable quickly.
- If Swiss Ephemeris is missing, set `SAM_ASTROLOGY_ENGINE=fallback` (Sun-sign only).
