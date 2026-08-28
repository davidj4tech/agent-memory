# agent-memory installer (system-wide layout)
#
# Common targets:
#   sudo make install           Full install (user, dirs, package, units, configs)
#   sudo make install-update    Reinstall package + units, restart services
#   sudo make uninstall         Stop + disable + remove units (keeps state)
#   sudo make uninstall-purge   Also remove configs, state, and the service user
#
# Honors DESTDIR, PREFIX, SYSCONFDIR, PIPX_HOME for packagers and non-default
# installs:
#   make install PREFIX=/usr SYSCONFDIR=/etc DESTDIR=/tmp/stage

PREFIX     ?= /usr/local
SYSCONFDIR ?= /etc
DESTDIR    ?=

# One knob for the name so a future rename is a variable, not a sed hunt.
APP_NAME ?= agent-memory
SVC_USER ?= $(APP_NAME)

ETC_DIR     := $(DESTDIR)$(SYSCONFDIR)/$(APP_NAME)
STATE_DIR   := $(DESTDIR)/var/lib/$(APP_NAME)
SYSTEMD_DIR := $(DESTDIR)/etc/systemd/system
BIN_DIR     := $(DESTDIR)$(PREFIX)/bin
# Architecture-independent read-only data (the bot doc loader reads this).
DATA_DIR    := $(DESTDIR)$(PREFIX)/share/$(APP_NAME)

# pipx layout: a system-wide venv under /opt/pipx, with bins symlinked into
# $(PREFIX)/bin. This works on every pipx version (no --global needed) and
# keeps service binaries on the standard PATH.
#
# The venv is the ONLY code on a deployed host. Everything the units invoke is
# a console script from the package, so there is no source tree to install,
# keep in sync, or accidentally run from.
PIPX_HOME    ?= /opt/pipx
PIPX_BIN_DIR ?= $(PREFIX)/bin

REPO_DIR := $(shell pwd)

.PHONY: install install-update install-deps check-legacy install-package \
        install-bin install-systemd install-config install-compose install-docs \
        uninstall uninstall-purge help

help:
	@sed -n '1,12p' Makefile

# ── Composite targets ───────────────────────────────────────────────

install: install-deps check-legacy install-package install-bin install-systemd install-config install-compose install-docs
	@./scripts/post-install-message.sh "$(ETC_DIR)" "$(STATE_DIR)" || true

# Advisory only. Older installs kept a source checkout at /opt/sacred-brain
# with an in-tree venv, plus config/state under the old name. Those are no
# longer used, but they can hold edited config (.env.matrix) and a live
# memory store — so report them and let a human move them. Never delete data.
check-legacy:
	@for p in /opt/sacred-brain /etc/sacred-brain /var/lib/sacred-brain; do \
	    if [ -e "$$p" ]; then \
	        echo "  [!] Legacy path still present: $$p"; \
	        echo "      Nothing uses it now. Move anything you need to the"; \
	        echo "      $(APP_NAME) equivalent, then remove it by hand."; \
	    fi; \
	done
	@if id sacred >/dev/null 2>&1; then \
	    echo "  [!] Legacy service user 'sacred' still exists (now '$(SVC_USER)')."; \
	fi

install-update: install-package install-systemd
	systemctl daemon-reload
	@for unit in $$(ls ops/systemd/*.service | xargs -n1 basename); do \
	    systemctl is-enabled $$unit >/dev/null 2>&1 && systemctl restart $$unit || true; \
	done

# ── Phase: service user + state dirs ────────────────────────────────

install-deps:
	@if ! id $(SVC_USER) >/dev/null 2>&1; then \
	    echo "  [+] Creating service user '$(SVC_USER)'"; \
	    useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/$(APP_NAME) $(SVC_USER); \
	else echo "  [+] User '$(SVC_USER)' already exists"; fi
	@echo "  [+] Creating state directories"
	install -d -m 0755 -o $(SVC_USER) -g $(SVC_USER) $(STATE_DIR)/hippocampus
	install -d -m 0755 -o $(SVC_USER) -g $(SVC_USER) $(STATE_DIR)/governor
	install -d -m 0755 -o $(SVC_USER) -g $(SVC_USER) $(STATE_DIR)/cache
	install -d -m 0755 -o $(SVC_USER) -g $(SVC_USER) $(STATE_DIR)/dreams
	install -d -m 0755 -o $(SVC_USER) -g $(SVC_USER) $(STATE_DIR)/digests
	install -d -m 0755 -o $(SVC_USER) -g $(SVC_USER) $(ETC_DIR)

# ── Phase: Python package via pipx ──────────────────────────────────

install-package:
	@command -v pipx >/dev/null || { echo "ERROR: pipx not installed (apt install pipx)"; exit 1; }
	@echo "  [+] Installing Python package via pipx into $(PIPX_HOME)"
	PIPX_HOME=$(PIPX_HOME) PIPX_BIN_DIR=$(PIPX_BIN_DIR) \
	    pipx install --force "$(REPO_DIR)"

# ── Phase: shell scripts on PATH ────────────────────────────────────

install-bin:
	@echo "  [+] Installing shell utilities to $(BIN_DIR)"
	install -d -m 0755 $(BIN_DIR)
	install -m 0755 scripts/agent-memory-search $(BIN_DIR)/agent-memory-search
	install -m 0755 scripts/sacred-search $(BIN_DIR)/sacred-search

# ── Phase: systemd units ────────────────────────────────────────────

install-systemd:
	@echo "  [+] Installing systemd units to $(SYSTEMD_DIR)"
	install -d -m 0755 $(SYSTEMD_DIR)
	@for f in ops/systemd/*.service ops/systemd/*.timer; do \
	    [ -e "$$f" ] || continue; \
	    install -m 0644 "$$f" $(SYSTEMD_DIR)/; \
	    echo "      $$(basename $$f)"; \
	done
	@if [ -z "$(DESTDIR)" ]; then \
	    systemctl daemon-reload; \
	    for f in ops/systemd/*.service ops/systemd/*.timer; do \
	        [ -e "$$f" ] || continue; \
	        if grep -q '^\[Install\]' "$$f"; then \
	            systemctl enable "$$(basename $$f)"; \
	        fi; \
	    done; \
	fi

# ── Phase: config templates ─────────────────────────────────────────

# Standalone-safe: create ETC_DIR here rather than relying on install-deps
# having run, and only claim success if the install actually succeeded.
install-config:
	@echo "  [+] Installing config templates to $(ETC_DIR)"
	install -d -m 0755 $(ETC_DIR)
	@for tmpl in ops/config/*.example; do \
	    [ -e "$$tmpl" ] || continue; \
	    target="$(ETC_DIR)/$$(basename $${tmpl%.example})"; \
	    if [ -f "$$target" ]; then \
	        echo "      exists, skipping: $$target"; \
	    elif install -m 0640 "$$tmpl" "$$target"; then \
	        chown $(SVC_USER):$(SVC_USER) "$$target" 2>/dev/null || true; \
	        echo "      created: $$target  (edit CHANGE_ME values!)"; \
	    else \
	        echo "      FAILED: $$target"; exit 1; \
	    fi; \
	done

# Compose stacks are config: they are edited per host (ports, models, tokens)
# and the units run `docker compose` with $(ETC_DIR)/compose/<stack> as the
# working directory. Never clobber a stack an operator has edited.
install-compose:
	@echo "  [+] Installing compose stacks to $(ETC_DIR)/compose"
	@for dir in ops/compose/*/; do \
	    [ -d "$$dir" ] || continue; \
	    stack=$$(basename "$$dir"); \
	    target="$(ETC_DIR)/compose/$$stack"; \
	    install -d -m 0755 "$$target"; \
	    for f in "$$dir"*; do \
	        [ -f "$$f" ] || continue; \
	        if [ -f "$$target/$$(basename $$f)" ]; then \
	            echo "      exists, skipping: $$target/$$(basename $$f)"; \
	        else \
	            install -m 0644 "$$f" "$$target/"; \
	        fi; \
	    done; \
	    echo "      $$stack"; \
	done

# ── Phase: docs as installed data ───────────────────────────────────

# brain.hippocampus.bot_router serves docs by name. They are data, not a
# checkout, so they get installed rather than read out of a source tree.
install-docs:
	@echo "  [+] Installing docs to $(DATA_DIR)/docs"
	install -d -m 0755 $(DATA_DIR)/docs
	@for f in docs/*.md; do \
	    [ -e "$$f" ] || continue; \
	    install -m 0644 "$$f" $(DATA_DIR)/docs/; \
	done
	@echo "      $$(ls -1 docs/*.md 2>/dev/null | wc -l) documents"

# ── Uninstall ───────────────────────────────────────────────────────

uninstall:
	@echo "  [+] Stopping and disabling units"
	@for f in ops/systemd/*.service ops/systemd/*.timer; do \
	    [ -e "$$f" ] || continue; \
	    unit=$$(basename $$f); \
	    if [ -f "$(SYSTEMD_DIR)/$$unit" ]; then \
	        systemctl disable --now "$$unit" 2>/dev/null || true; \
	        rm -f "$(SYSTEMD_DIR)/$$unit"; \
	    fi; \
	done
	@if [ -z "$(DESTDIR)" ]; then systemctl daemon-reload; fi
	@echo "  [+] Removing shell utilities from $(BIN_DIR)"
	@rm -f $(BIN_DIR)/agent-memory-search $(BIN_DIR)/sacred-search
	@echo "  [+] Uninstalling Python package"
	@PIPX_HOME=$(PIPX_HOME) PIPX_BIN_DIR=$(PIPX_BIN_DIR) \
	    pipx uninstall $(APP_NAME) 2>/dev/null || true
	@echo "  [+] Kept $(ETC_DIR) and $(STATE_DIR) (use 'make uninstall-purge' to remove)"

uninstall-purge: uninstall
	@echo "  [+] Removing $(ETC_DIR) and $(STATE_DIR)"
	rm -rf $(ETC_DIR) $(STATE_DIR) $(DATA_DIR)
	@if id $(SVC_USER) >/dev/null 2>&1; then \
	    echo "  [+] Removing service user '$(SVC_USER)'"; \
	    userdel $(SVC_USER) 2>/dev/null || echo "  [!] could not remove user '$(SVC_USER)'"; \
	fi
