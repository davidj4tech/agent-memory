from pathlib import Path

from memory_governor.schemas import ObserveRequest, Scope
from memory_governor.store import WorkingStore, near_duplicate


def _ev(text: str) -> ObserveRequest:
    return ObserveRequest(
        source="claude-code:stop",
        user_id="ryer",
        text=text,
        scope=Scope(kind="project", id="p", parent=Scope(kind="user", id="ryer", parent=None)),
        metadata={},
    )


BASE = " ".join(f"word{i}" for i in range(60))


def test_near_duplicate_thresholds() -> None:
    assert near_duplicate(BASE, BASE)
    assert near_duplicate(BASE, BASE + " one extra trailing clause here")
    assert not near_duplicate(BASE, " ".join(f"other{i}" for i in range(60)))
    assert not near_duplicate("", BASE)


def test_add_working_drops_near_duplicates(tmp_path: Path) -> None:
    store = WorkingStore(tmp_path / "state.db")
    assert store.add_working(_ev(BASE))
    assert not store.add_working(_ev(BASE))                       # exact
    assert not store.add_working(_ev(BASE + " plus a tail"))      # near
    assert store.add_working(_ev(" ".join(f"other{i}" for i in range(60))))
