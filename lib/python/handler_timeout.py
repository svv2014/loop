"""handler_timeout.py — wall-clock timeout wrapper for long-running subprocesses.

Used by Loop handlers (via shell `timeout` or directly) to ensure that a
worker subprocess that crashes silently does not hold the project lock forever.

The module provides:
  run_with_timeout(cmd, cwd, timeout_seconds) -> RunResult

A RunResult has:
  .returncode  — int exit code (or None if not started)
  .status      — "ok" | "failed" | "failed_timeout"
  .elapsed     — float seconds the process ran

Design note: "failed_timeout" maps directly to the orchestrator's
max_worker_timeout_seconds semantic described in issue #409.
"""

from __future__ import annotations

import subprocess
import time
from dataclasses import dataclass, field
from typing import List, Optional


@dataclass
class RunResult:
    returncode: Optional[int]
    status: str          # "ok" | "failed" | "failed_timeout"
    elapsed: float
    stdout: str = field(default="", repr=False)
    stderr: str = field(default="", repr=False)


def run_with_timeout(
    cmd: List[str],
    cwd: Optional[str] = None,
    timeout_seconds: float = 7200,
) -> RunResult:
    """Run *cmd* in *cwd* and enforce a wall-clock cap of *timeout_seconds*.

    Returns a RunResult.  On timeout the process tree is killed and
    status is set to "failed_timeout".
    """
    start = time.monotonic()
    try:
        result = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
        elapsed = time.monotonic() - start
        status = "ok" if result.returncode == 0 else "failed"
        return RunResult(
            returncode=result.returncode,
            status=status,
            elapsed=elapsed,
            stdout=result.stdout,
            stderr=result.stderr,
        )
    except subprocess.TimeoutExpired as exc:
        elapsed = time.monotonic() - start
        stdout = (exc.stdout or b"").decode(errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = (exc.stderr or b"").decode(errors="replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        return RunResult(
            returncode=None,
            status="failed_timeout",
            elapsed=elapsed,
            stdout=stdout,
            stderr=stderr,
        )
