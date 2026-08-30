# Installing Sacred Brain

> **Two install models.** This document covers the packaged, system-wide model
> (`/opt/agent-memory`, `/etc`, `/var/lib`, a `sacred` service user, root).
> For the unprivileged single-user model the live `red5` box runs — a clone at
> `~/projects/agent-memory`, a per-user pipx venv, and `systemctl --user`
> units — see [INSTALL_USER.md](INSTALL_USER.md). Pick one model per host.

## Prerequisites

- Linux with systemd (Debian/Ubuntu/Raspberry Pi OS)
- Python 3.11+
- `pipx` (`sudo apt install pipx`)
- `make`, `curl`
- `just` (optional, for ops recipes): `sudo apt install just`
- A LiteLLM-compatible gateway on port 4000 (optional, for LLM features)

## Quick Start

```bash
# 1. Clone the repo (anywhere — the checkout is build-time only)
git clone https://github.com/davidj4tech/agent-memory.git
cd agent-memory

# 2. Install
sudo make install

# 3. Edit /etc/agent-memory/* — replace CHANGE_ME values
sudoedit /etc/agent-memory/hippocampus.toml
sudoedit /etc/agent-memory/hippocampus.env
sudoedit /etc/agent-memory/memory-governor.env

# 4. Start the services
sudo systemctl start hippocampus memory-governor

# 5. Verify
just health
just timers
```

The checkout is needed **only to run `make install`** — clone it wherever you
like, and delete it afterwards if you want. Nothing at runtime reads from it:
every unit invokes a console script from the pipx-managed venv at
`/opt/pipx/venvs/agent-memory/`, symlinked into `/usr/local/bin/`.

That was not always true. The units used to run loose files out of a source
tree at `/opt/sacred-brain/`, which meant a deployed host had to keep a git
checkout in sync with its installed package. The scripts are part of the
package now (`agent_memory.cli.*`), so that whole class of drift is gone.

## What `make install` Does

| Target | Action |
|--------|--------|
| `install-deps` | Creates the `agent-memory` system user (nologin) and `/var/lib/agent-memory/{hippocampus,governor,cache,dreams,digests}` and `/etc/agent-memory/` |
| `check-legacy` | Reports any leftover `/opt/sacred-brain`, `/etc/sacred-brain`, `/var/lib/sacred-brain` or `sacred` user. Advisory only — it never deletes, because those can hold an edited config or a live store |
| `install-package` | `pipx install --force .` into `/opt/pipx/venvs/agent-memory/`, exposing every console script in `$(PREFIX)/bin/` |
| `install-bin` | Installs `agent-memory-search` (and the `sacred-search` alias) to `$(PREFIX)/bin/` |
| `install-compose` | Copies the compose stacks to `/etc/agent-memory/compose/<stack>/`, skipping any file already there |
| `install-docs` | Installs `docs/*.md` to `$(PREFIX)/share/agent-memory/docs/` (the bot doc loader reads these) |
| `install-systemd` | Copies all unit files from `ops/systemd/` to `/etc/systemd/system/`, runs `daemon-reload`, enables every unit with an `[Install]` section **except those in `OPTIONAL_UNITS`** (see below) |
| `install-config` | Copies `.example` templates to `/etc/agent-memory/` (skips files that already exist) |

`make install` does **not** start services automatically — the operator
edits `CHANGE_ME` values, then runs `systemctl start` manually.

## Updating

After pulling new code:

```bash
cd /path/to/agent-memory   # your checkout
sudo git pull
sudo make install-update
```

`install-update` reinstalls the Python package, refreshes systemd unit
files, runs `daemon-reload`, and restarts any enabled services.

## Uninstalling

```bash
# Stop, disable, and remove all systemd units; uninstall the pipx package;
# remove sacred-search from $(PREFIX)/bin. Keeps configs and state.
sudo make uninstall

# Also remove /etc/agent-memory, /var/lib/agent-memory, and the 'sacred' user
sudo make uninstall-purge
```

## Compatibility shim

`scripts/install.sh` still exists as a thin wrapper that delegates to the
Makefile, so `sudo ./scripts/install.sh [--update|--uninstall|--uninstall --purge]`
continues to work for existing automation.

## Customization

The Makefile honors standard variables for non-default installs and packagers:

| Variable | Default | Purpose |
|----------|---------|---------|
| `PREFIX` | `/usr/local` | Where `hippocampus`, `memory-governor`, `sacred-search` live |
| `SYSCONFDIR` | `/etc` | Parent of `sacred-brain/` config dir |
| `DESTDIR` | (empty) | Stage all paths under this prefix (skips `systemctl` calls) |
| `PIPX_HOME` | `/opt/pipx` | Where pipx puts the package's venv |

## Units that are installed but not enabled

`make install` enables every unit with an `[Install]` section, apart from the
ones listed in `OPTIONAL_UNITS`:

| Unit | Why it is opt-in | Guard if enabled early |
| --- | --- | --- |
| `matrix-bot.service` | Needs the `matrix` extra (`matrix-nio`) and `/etc/agent-memory/matrix.env` | `ConditionPathExists` on `matrix.env` |
| `matrix-autojoin.service` | Same | Same |
| `baibot-compose.service` | Needs docker and a configured compose stack | `ConditionFileIsExecutable=/usr/bin/docker` + `ConditionPathExists` on the stack's `docker-compose.yml` |
| `litellm-compose.service` | Same | Same |
| `llamacpp-compose.service` | Same | Same |
| `hippocampus-memory-sync.service` (+ `.timer`) | Needs `MEMORY_SYNC_ROOT` pointed at a real directory | `ExecCondition` |

None of these is something `make install` can supply: an extra outside the
default dependency set, a homeserver token, a container runtime, or a path that
only the host knows. Enabling them by default gave every host a handful of
units that failed on each boot, whether or not it wanted them.

To turn them on:

```bash
# Matrix
pipx install --force '/path/to/agent-memory[matrix]'
sudo $EDITOR /etc/agent-memory/matrix.env
sudo systemctl enable --now matrix-bot.service

# compose stacks — edit the stack first
sudo $EDITOR /etc/agent-memory/compose/litellm/docker-compose.yml
sudo systemctl enable --now litellm-compose.service

# markdown memory sync — set MEMORY_SYNC_ROOT
sudo $EDITOR /etc/agent-memory/hippocampus.env
sudo systemctl enable --now hippocampus-memory-sync.timer
```

### Enabled early is safe

Each unit also carries a guard, so one enabled before its prerequisites exist
is **skipped** rather than failed — `Result=success`, and no
`Restart=on-failure` loop chewing on a unit that cannot succeed.

`MEMORY_SYNC_ROOT` needs `ExecCondition` rather than a `Condition*`: the
`Condition*` family is evaluated against the manager environment and cannot see
values from an `EnvironmentFile`, whereas `ExecCondition` runs with the unit's
environment loaded and skips the unit on a non-zero exit.

Override the list if you want different defaults:

```bash
sudo make install OPTIONAL_UNITS="matrix-bot.service litellm-compose.service"
```

## Directory Layout

```
/opt/pipx/venvs/agent-memory/             ← the only code on the host
/usr/local/bin/hippocampus
/usr/local/bin/memory-governor
/usr/local/bin/agent-memory-dream         ← console scripts the timers invoke
/usr/local/bin/agent-memory-digest
/usr/local/bin/agent-memory-file-sync
/usr/local/bin/agent-memory-prune
/usr/local/bin/agent-memory-tune
/usr/local/bin/agent-memory-notes
/usr/local/bin/agent-memory-search
/usr/local/share/agent-memory/docs/       ← docs as installed data
/etc/agent-memory/                        ← configuration (not in repo)
    hippocampus.toml
    hippocampus.env
    memory-governor.env
/var/lib/agent-memory/                    ← state (not in repo)
    hippocampus/
        hippocampus_memories.sqlite
        memories-denote/
    governor/
        state.db
        durable.spool
    cache/
        sam_chart.json
    auto_memory_tuning.json
```

## Services

| Service | Port | Description |
|---------|------|-------------|
| `hippocampus.service` | 54321 | Memory storage and retrieval (Mem0/SQLite) |
| `memory-governor.service` | 54323 | Memory governance, classification, and consolidation |

## Timers

| Timer | Schedule | Description |
|-------|----------|-------------|
| `governor-digest.timer` | 03:20 daily | Write memory digest to markdown |
| `hippocampus-memory-sync.timer` | 03:35 daily | Sync markdown files into Hippocampus |
| `hippocampus-auto-prune.timer` | 04:15 daily | Prune low-salience auto memories |
| `hippocampus-auto-tune.timer` | Hourly | Adaptive capture threshold tuning |
| `hippocampus-notes-export.timer` | Daily | Export memories to Org/Denote format |
| `hippocampus-notes-import.timer` | Daily | Import Org/Denote notes into memories |
| `memory-governor-consolidate.timer` | Hourly | Consolidate working memory into long-term |

## Configuration

### Hippocampus (`hippocampus.toml`)

Core settings: auth keys, Mem0 backend, Agno model, notes directory. See `ops/config/hippocampus.toml.example` for all options.

### Hippocampus Environment (`hippocampus.env`)

SAM pipeline settings (LLM gateway URL, model alias, timeout) and the Hippocampus API key.
Optional: `HIPPOCAMPUS_HOST` (default `0.0.0.0`) and `HIPPOCAMPUS_PORT` (default `54321`).

### Governor Environment (`memory-governor.env`)

Bind address, Hippocampus/LiteLLM URLs, stream/working memory TTLs, reranking config, consolidation scopes.

## Optional Features

### Memory Sync (per-identity)

Sync markdown memory files for any identity into Hippocampus. See [MEMORY_SYNC.md](MEMORY_SYNC.md) for setup.

### ChatGPT Import

One-time import of ChatGPT conversation history. See [CHATGPT_IMPORT.md](CHATGPT_IMPORT.md).

### Governor Digest

Nightly timer that pulls consolidated memories from Governor and writes human-readable markdown. Requires a target directory (configured via the systemd unit's `ReadWritePaths`).

## Hardening

All services run with:
- `NoNewPrivileges=true`
- `ProtectSystem=strict`
- `ProtectHome=true`
- `PrivateTmp=true`
- `ReadWritePaths` limited to `/var/lib/agent-memory`
- `ReadOnlyPaths` for code (`/opt/pipx`) and config (`/etc/agent-memory`) — no source tree to grant access to

Check security scores: `just security-audit`

## Troubleshooting

```bash
# Service logs
just logs

# Service status
just status

# Full smoke test (health + write + read)
just smoke

# Config validation
just config-check

# Check a specific service
journalctl -u hippocampus --since "10 min ago"
journalctl -u memory-governor --since "10 min ago"
```
