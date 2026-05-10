#!/usr/bin/env python3
"""Filter `gh pr list --json ...` output to PRs that need rework.

Reads JSON array from stdin (output of `gh pr list ... --json
number,author,labels,mergeable,statusCheckRollup,createdAt,updatedAt`),
prints `<num>\\t<reason>` lines for PRs that match the auto-rework rules.

Rules — emit a PR if ALL of these hold:
  - author.login is in --allowed-authors (comma-separated)
  - none of {needs-rework, blocked, needs-clarification} on the labels
  - either:
      mergeable == CONFLICTING and updatedAt older than --conflict-grace seconds, or
      any statusCheckRollup entry has conclusion == FAILURE and updatedAt older
        than --ci-grace seconds

`updatedAt` is used as a proxy for "how long has this been in its current bad
state". It's not perfect — a comment on the PR resets it — but it's the
cheapest signal that doesn't require additional API calls per PR.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone

_DEFAULT_EXCLUDE_LABELS = "needs-rework,blocked,needs-clarification"


def parse_iso(ts: str) -> datetime:
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    return datetime.fromisoformat(ts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conflict-grace", type=int, required=True)
    ap.add_argument("--ci-grace", type=int, required=True)
    ap.add_argument("--allowed-authors", required=True, help="comma-separated")
    ap.add_argument(
        "--exclude-labels",
        default=_DEFAULT_EXCLUDE_LABELS,
        help="comma-separated labels that mark a PR as already handled",
    )
    args = ap.parse_args()

    exclude_labels = {l.strip() for l in args.exclude_labels.split(",") if l.strip()}

    allowed = {a.strip() for a in args.allowed_authors.split(",") if a.strip()}
    if not allowed:
        return 0

    try:
        prs = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0

    now = datetime.now(timezone.utc)

    for pr in prs:
        author_login = (pr.get("author") or {}).get("login", "")
        if author_login not in allowed:
            continue

        labels = {(l.get("name") or "") for l in pr.get("labels") or []}
        if labels & exclude_labels:
            continue

        try:
            updated_age = (now - parse_iso(pr["updatedAt"])).total_seconds()
        except (KeyError, ValueError):
            continue

        reason = None

        # Conflict path
        if pr.get("mergeable") == "CONFLICTING" and updated_age >= args.conflict_grace:
            reason = f"conflict for {int(updated_age)}s"

        # CI failure path
        if reason is None:
            for chk in pr.get("statusCheckRollup") or []:
                if chk.get("conclusion") == "FAILURE" and updated_age >= args.ci_grace:
                    name = chk.get("name") or chk.get("workflowName") or "ci"
                    reason = f"ci failure ({name}) for {int(updated_age)}s"
                    break

        if reason:
            print(f"{pr['number']}\t{reason}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
