"""Tests for lib/python/handler_timeout.py.

Covers the wall-clock timeout that prevents a hung orchestrator worker from
holding the project lock forever (issue #409).

Run:
    python3 -m pytest lib/python/tests/test_handler_timeout.py -v
"""

import sys
import time
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.python.handler_timeout import run_with_timeout


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


def test_fast_command_returns_ok():
    result = run_with_timeout(["true"], timeout_seconds=5)
    assert result.status == "ok"
    assert result.returncode == 0
    assert result.elapsed < 5


def test_failing_command_returns_failed():
    result = run_with_timeout(["false"], timeout_seconds=5)
    assert result.status == "failed"
    assert result.returncode != 0


def test_stdout_captured():
    result = run_with_timeout(["echo", "hello"], timeout_seconds=5)
    assert result.status == "ok"
    assert "hello" in result.stdout


# ---------------------------------------------------------------------------
# Timeout enforcement — the core scenario from issue #409:
# "orchestrator with a worker that never returns + max_worker_timeout_seconds=2
#  → orchestrator returns failed_timeout within ~2s"
# ---------------------------------------------------------------------------


def test_worker_that_never_returns_is_killed_at_timeout():
    """A process that sleeps forever is killed within the timeout window."""
    timeout_sec = 2
    t_start = time.monotonic()

    result = run_with_timeout(["sleep", "300"], timeout_seconds=timeout_sec)

    elapsed_wall = time.monotonic() - t_start

    assert result.status == "failed_timeout", (
        f"Expected failed_timeout, got {result.status!r}"
    )
    assert result.returncode is None
    # Wall clock should be close to timeout_sec (allow 2x slack for slow CI)
    assert elapsed_wall < timeout_sec * 3, (
        f"Took {elapsed_wall:.1f}s — should have been killed within {timeout_sec * 3}s"
    )


def test_timeout_elapsed_field_reflects_actual_runtime():
    timeout_sec = 2
    result = run_with_timeout(["sleep", "300"], timeout_seconds=timeout_sec)
    assert result.status == "failed_timeout"
    # elapsed should be roughly timeout_sec
    assert result.elapsed >= timeout_sec * 0.9


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------


def test_very_short_timeout_still_returns_failed_timeout():
    result = run_with_timeout(["sleep", "60"], timeout_seconds=0.1)
    assert result.status == "failed_timeout"


def test_command_that_finishes_just_before_timeout():
    result = run_with_timeout(["sleep", "0"], timeout_seconds=5)
    assert result.status == "ok"
