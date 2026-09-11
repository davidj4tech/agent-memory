#!/usr/bin/env bash
# install-user.sh — user-mode install/update for agent-memory (the red5 model).
#
# Installs the Python package into a per-user pipx venv and SYMLINKS the user
# systemd units from ops/systemd/user/ into ~/.config/systemd/user/, so the
# repo stays the source of truth for what runs. Units were previously
# `install`ed as copies, which is how hippocampus.service drifted from the
# repo. Existing copies are moved aside as *.bak.<timestamp>; existing
# .wants/ links are re-pointed; nothing is auto-enabled.
#
# Uses agent-config's lib/install-lib.sh when present (same helper the rest of
# the fleet uses), with an equivalent inline fallback otherwise.
#
# Usage:
#   scripts/install-user.sh            # package + units
#   scripts/install-user.sh --units    # units only (no pipx)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_SRC="$REPO_DIR/ops/systemd/user"
UNIT_DST="$HOME/.config/systemd/user"
do_pipx=1
[[ "${1:-}" == "--units" ]] && do_pipx=0

if (( do_pipx )); then
  command -v pipx >/dev/null || { echo "pipx not installed (apt install pipx)" >&2; exit 1; }
  echo "  [+] pipx install --force $REPO_DIR"
  pipx install --force "$REPO_DIR" >/dev/null
fi

# agent-memory-search lives in agent-config (fleet-wide); nothing to install here.
for lib in "$HOME/agent-config/lib/install-lib.sh" "$HOME/.config/agent-config/lib/install-lib.sh"; do
  if [[ -r "$lib" ]]; then
    # shellcheck source=/dev/null
    . "$lib"
    break
  fi
done

if ! declare -F link_systemd_units_repoint_only >/dev/null; then
  link_file() {
    local src="$1" dst="$2"
    [ -e "$src" ] || return 0
    mkdir -p "$(dirname "$dst")"
    if [ -L "$dst" ]; then rm -f "$dst"
    elif [ -e "$dst" ]; then mv "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
    fi
    ln -s "$src" "$dst"
    echo "  linked ${dst#"$HOME"/}"
  }
  link_systemd_units_repoint_only() {
    local src="$1" dst="${2:-$HOME/.config/systemd/user}" u name wanted wdir
    [ -d "$src" ] || return 0
    mkdir -p "$dst"
    for u in "$src"/*; do [ -f "$u" ] && link_file "$u" "$dst/$(basename "$u")"; done
    for u in "$src"/*; do
      [ -f "$u" ] || continue
      name=$(basename "$u")
      wanted=$(sed -n 's/^WantedBy=//p' "$u" | head -1)
      [ -n "$wanted" ] || continue
      wdir="$dst/$wanted.wants"
      if [ -e "$wdir/$name" ] || [ -L "$wdir/$name" ]; then
        ln -sfn "../$name" "$wdir/$name"
        echo "  re-pointed ${wdir#"$HOME"/}/$name"
      fi
    done
    systemctl --user daemon-reload 2>/dev/null || true
  }
fi

echo "  [+] Linking user units from ${UNIT_SRC#"$HOME"/}"
link_systemd_units_repoint_only "$UNIT_SRC" "$UNIT_DST"

# The healthcheck is a plain script run from the clone; keep it on PATH as a link.
mkdir -p "$HOME/.local/bin"
ln -sfn "$REPO_DIR/scripts/agent-memory-healthcheck" "$HOME/.local/bin/agent-memory-healthcheck"

echo "  [+] Done. Long-running services are NOT restarted; if the package changed:"
echo "      systemctl --user restart hippocampus.service memory-governor.service"
