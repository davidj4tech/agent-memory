"""AGENT_MEMORY_HEALTH_* knobs, and the legacy spellings they replaced.

The healthcheck is a standalone script rather than a package module, so it is
loaded by path. Reloading it per case is deliberate: the knobs are resolved at
import time.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import sys
from types import ModuleType

import pytest

SCRIPT = "scripts/agent-memory-healthcheck"
SUFFIX = "STORE_STALE_HOURS"
NEW = f"AGENT_MEMORY_HEALTH_{SUFFIX}"
LEGACY_SB = f"SB_HEALTH_{SUFFIX}"
LEGACY_SACRED = f"SACRED_BRAIN_HEALTH_{SUFFIX}"


def _load() -> ModuleType:
    sys.modules.pop("_healthcheck_under_test", None)
    loader = importlib.machinery.SourceFileLoader("_healthcheck_under_test", SCRIPT)
    spec = importlib.util.spec_from_loader("_healthcheck_under_test", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in (NEW, LEGACY_SB, LEGACY_SACRED):
        monkeypatch.delenv(name, raising=False)


def test_default_when_nothing_set() -> None:
    assert _load().STORE_STALE_HOURS == 72.0


@pytest.mark.parametrize("name", [NEW, LEGACY_SB, LEGACY_SACRED])
def test_each_spelling_is_honoured(monkeypatch: pytest.MonkeyPatch, name: str) -> None:
    monkeypatch.setenv(name, "11")
    assert _load().STORE_STALE_HOURS == 11.0


def test_new_name_wins_over_legacy(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(NEW, "44")
    monkeypatch.setenv(LEGACY_SB, "11")
    monkeypatch.setenv(LEGACY_SACRED, "22")
    assert _load().STORE_STALE_HOURS == 44.0


def test_sb_wins_over_sacred_brain(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(LEGACY_SB, "11")
    monkeypatch.setenv(LEGACY_SACRED, "22")
    assert _load().STORE_STALE_HOURS == 11.0


def test_health_env_returns_default_for_unset() -> None:
    assert _load().health_env("DEFINITELY_NOT_SET", "fallback") == "fallback"
