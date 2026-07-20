# Installing agent-memory in user mode

This is the deployment model the live `red5` box runs: everything under a
single unprivileged login user — **no root, no `sacred` service user, no
`/opt`, no `/etc`**. The whole stack runs from a clone at
`~/projects/agent-memory`, a per-user pipx venv, and `systemctl --user` units.

If you instead want the packaged, system-wide model (`/opt/agent-memory`,
`/etc`, `/var/lib`, the `sacred` user), see [INSTALL.md](INSTALL.md). The two
models are independent; pick one per host.

> The Python package and pipx venv are still named
> `sacred-brain-hippocampus`, and config/state still live under
> `sacred-brain/`. Task 012 deliberately froze those internal names during the
> `agent-memory` rename — only the clone location and user-facing commands
> move. Do not rename the venv or config dirs to make these units match.

## Prerequisites

- Linux with systemd and a logind session for your user
- Python 3.11+
- `pipx` (`sudo apt install pipx` — used unprivileged)
- Lingering enabled so timers fire without an active login:
  `sudo loginctl enable-linger "$USER"`

## Quick Start

```bash
# 1. Clone the repo to the canonical user-mode location
git clone https://github.com/davidj4tech/sacred-brain.git ~/projects/agent-memory
cd ~/projects/agent-memory

# 2. Install the Python package into a per-user pipx venv
#    (creates ~/.local/bin/hippocampus and ~/.local/bin/memory-governor)
pipx install --force .

# 3. Put the shell utilities on PATH
install -m 0755 scripts/sacred-search          ~/.local/bin/sacred-search
install -m 0755 scripts/agent-memory-search    ~/.local/bin/agent-memory-search
install -m 0755 scripts/sacred-brain-healthcheck ~/.local/bin/sacred-brain-healthcheck

# 4. Install the user systemd units
install -d ~/.config/systemd/user
install -m 0644 ops/systemd/user/*.service ops/systemd/user/*.timer ~/.config/systemd/user/
systemctl --user daemon-reload

# 5. Create config (see below), then enable + start
systemctl --user enable --now hippocampus.service memory-governor.service
systemctl --user enable --now \
    memory-governor-consolidate.timer \
    sacred-brain-dream.timer \
    claude-memory-sync.timer \
    sacred-brain-healthcheck.timer

# 6. Verify
curl -sf http://127.0.0.1:54321/health && echo
curl -sf http://127.0.0.1:54323/health && echo
systemctl --user list-timers --no-pager
```

## User-mode layout

```
~/projects/agent-memory/                            ← repo clone (timer scripts run from here)
~/.local/share/pipx/venvs/sacred-brain-hippocampus/ ← installed Python package (services run from here)
~/.local/bin/hippocampus
~/.local/bin/memory-governor
~/.local/bin/sacred-search
~/.local/bin/agent-memory-search
~/.local/bin/sacred-brain-healthcheck
~/.config/sacred-brain/                             ← configuration (not in repo)
    hippocampus.env
    memory-governor.env
    secrets.env                                     ← rendered from sops by dotfiles-secrets
~/.local/state/sacred-brain/                        ← state (not in repo)
    hippocampus/
    governor/
    dreams/
~/.config/systemd/user/                             ← user units (from ops/systemd/user/)
```

## User units

The templates in [`ops/systemd/user/`](../ops/systemd/user/) use `%h` for the
home directory and expect the clone at `%h/projects/agent-memory`. They are
kept in a `user/` subdirectory so the system `Makefile`'s non-recursive
`ops/systemd/*.service` glob never mis-installs them into
`/etc/systemd/system`, where the `--user`/`%h` assumptions would break.

| Unit | Type | Purpose |
| --- | --- | --- |
| `hippocampus.service` | long-running | Memory store (port 54321) |
| `memory-governor.service` | long-running | Policy/recall layer (port 54323) |
| `memory-governor-consolidate.timer` | hourly | Consolidate working memory |
| `sacred-brain-dream.timer` | nightly 03:00 | Scored dream sweep + REM reflection |
| `claude-memory-sync.timer` | hourly | Sync Claude Code memory files into the governor |
| `sacred-brain-healthcheck.timer` | hourly | Watch the sweep + `/consolidate` (see [HEALTHCHECK.md](HEALTHCHECK.md)) |

## Updating

```bash
cd ~/projects/agent-memory
git pull
pipx install --force .
install -m 0755 scripts/sacred-search scripts/agent-memory-search scripts/sacred-brain-healthcheck ~/.local/bin/
install -m 0644 ops/systemd/user/*.service ops/systemd/user/*.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user restart hippocampus.service memory-governor.service
```

## Migrating an existing `~/projects/sacred-brain` clone

Older user-mode installs cloned to `~/projects/sacred-brain`. To move to the
canonical `~/projects/agent-memory` location without disturbing config or
state (which live outside the clone):

```bash
systemctl --user stop hippocampus.service memory-governor.service
git -C ~/projects/sacred-brain pull                 # land latest first
mv ~/projects/sacred-brain ~/projects/agent-memory
# Refresh units so WorkingDirectory/PYTHONPATH/ExecStart point at the new path
install -m 0644 ~/projects/agent-memory/ops/systemd/user/*.service \
                ~/projects/agent-memory/ops/systemd/user/*.timer \
                ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user start hippocampus.service memory-governor.service
```

Nothing under `~/.config/sacred-brain` or `~/.local/state/sacred-brain` needs
to change — only the clone location and the units that reference it.
