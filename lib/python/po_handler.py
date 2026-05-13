#!/usr/bin/env python3
"""po_handler.py — pure logic for the PO handler pipeline step.

CLI usage (from bash, with PYTHONPATH=$LOOP_ROOT):
  python3 -m lib.python.po_handler has-complete-ac   < body.txt   → exit 0/1
  python3 -m lib.python.po_handler extract-brief     < body.txt   → prints brief
  python3 -m lib.python.po_handler parse-event       < event.json → JSON on stdout
  python3 -m lib.python.po_handler parse-issue       < issue.json → JSON on stdout
  python3 -m lib.python.po_handler label-transition  --action A --po-trigger loop.po_review
  python3 -m lib.python.po_handler format-comment    --slug <slug> --issue <N> --model <m>

Coverage:
  python3 -m coverage run -m pytest lib/python/tests/test_po_handler.py
  python3 -m coverage report --include='lib/python/po_handler.py' --fail-under=80
"""

import argparse
import dataclasses
import json
import re
import sys
from typing import List, Optional


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclasses.dataclass
class IssueData:
    number: int
    title: str
    body: str
    labels: List[str]
    state: str


@dataclasses.dataclass
class EventData:
    slug: str
    issue_number: str
    issue_title: str
    issue_url: str


@dataclasses.dataclass
class LabelTransition:
    remove: List[str]
    add: List[str]


# ---------------------------------------------------------------------------
# Pure functions
# ---------------------------------------------------------------------------

def parse_issue_json(json_str: str) -> IssueData:
    """Parse the output of ``gh issue view --json`` into an IssueData."""
    data = json.loads(json_str)
    labels = [lbl["name"] for lbl in data.get("labels", []) if isinstance(lbl, dict)]
    return IssueData(
        number=int(data.get("number", 0)),
        title=str(data.get("title", "")),
        body=str(data.get("body", "") or ""),
        labels=labels,
        state=str(data.get("state", "")),
    )


def parse_event_json(json_str: str) -> EventData:
    """Parse an event payload JSON (direct or wrapped under ``payload`` key)."""
    data = json.loads(json_str)
    payload = data.get("payload", data)
    return EventData(
        slug=str(payload.get("slug", "")),
        issue_number=str(payload.get("issue_number", "")),
        issue_title=str(payload.get("issue_title", "")),
        issue_url=str(payload.get("issue_url", "")),
    )


def has_complete_ac(body: str) -> bool:
    """Return True iff body contains a non-empty Acceptance Criteria section.

    Looks for ``## Acceptance`` or ``## Acceptance Criteria`` heading with at
    least one ``- [ ]`` / ``- [x]`` checkbox item before the next ``##``
    heading (or EOF).  Mirrors the bash heredoc in po-handler.sh so the
    logic lives in exactly one place.
    """
    m = re.search(r"(?im)^##\s+Acceptance(?:\s+Criteria)?\s*$", body)
    if not m:
        return False
    rest = body[m.end():]
    nxt = re.search(r"(?m)^##\s+\S", rest)
    section = rest[: nxt.start()] if nxt else rest
    return bool(re.search(r"(?m)^\s*-\s*\[[ xX]\]", section))


def extract_original_brief(body: str) -> str:
    """Strip any existing ``## Original brief`` section and return the remainder.

    Re-triaging an already-expanded issue must not nest the preservation
    marker.  Mirrors the python3 heredoc in po-handler.sh.
    """
    body = body.strip()
    body = re.split(r"(?m)^---\s*\n##\s+Original brief", body)[0].rstrip()
    return body


# Label-transition table for PO decision paths.
# Key: action name (matches the letter in the prompt, plus internal paths).
# Value: LabelTransition(remove=[...], add=[...])
_LABEL_TRANSITIONS = {
    "A":                LabelTransition(remove=["in-progress"], add=["dev"]),
    "B":                LabelTransition(remove=["in-progress"], add=[]),
    "C":                LabelTransition(remove=["in-progress"], add=[]),
    "D":                LabelTransition(remove=["in-progress"], add=["tracker"]),
    "E":                LabelTransition(remove=["in-progress"], add=["needs-clarification"]),
    "F_requeue":        LabelTransition(remove=["in-progress"], add=["dev"]),
    "F_cancel":         LabelTransition(remove=["in-progress"], add=[]),
    "F_blocked":        LabelTransition(remove=["in-progress"], add=["blocked"]),
    "success_fallback": LabelTransition(remove=["in-progress"], add=["dev"]),
    "transient_retry":  LabelTransition(remove=["in-progress"], add=[]),  # add po_trigger at call site
    "transient_blocked":LabelTransition(remove=["in-progress"], add=["blocked"]),
    "perm_retry":       LabelTransition(remove=["in-progress"], add=[]),  # add po_trigger at call site
    "perm_fail":        LabelTransition(remove=["in-progress"], add=["needs-clarification"]),
}


def compute_label_transition(action: str, po_trigger: str = "") -> LabelTransition:
    """Return the label add/remove pair for a given PO decision action.

    ``po_trigger`` is appended to ``add`` for retry paths that need it.
    Raises ``ValueError`` for unknown action names.
    """
    if action not in _LABEL_TRANSITIONS:
        raise ValueError(f"Unknown PO action: {action!r}")
    base = _LABEL_TRANSITIONS[action]
    extra_add = [po_trigger] if po_trigger and action in ("transient_retry", "perm_retry") else []
    return LabelTransition(remove=list(base.remove), add=list(base.add) + extra_add)


def format_failure_comment(
    slug: str,
    issue_num: str,
    model: str,
    log_tail: str,
    max_bytes: int = 60000,
) -> str:
    """Format the body of a PO-failure issue comment.

    Returns a plain fallback string when ``log_tail`` is empty.  Truncates
    from the front when the formatted body exceeds ``max_bytes``.
    """
    if not log_tail:
        return (
            f"Automated PO agent failed. Needs human clarification. "
            f"project={slug} issue=#{issue_num} model={model}"
        )
    from datetime import datetime, timezone
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    header = f"Run: {ts} | model={model} | project={slug} | issue=#{issue_num}"
    full_body = f"{header}\n```text\n{log_tail}\n```"
    if len(full_body) > max_bytes:
        excess = len(full_body) - max_bytes
        log_tail = log_tail[excess:]
        full_body = f"{header}\n```text\n...truncated {excess} chars...\n{log_tail}\n```"
    return full_body


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _cmd_has_complete_ac(args: argparse.Namespace) -> int:
    body = sys.stdin.read()
    return 0 if has_complete_ac(body) else 1


def _cmd_extract_brief(args: argparse.Namespace) -> int:
    body = sys.stdin.read()
    print(extract_original_brief(body))
    return 0


def _cmd_parse_event(args: argparse.Namespace) -> int:
    raw = sys.stdin.read()
    try:
        ev = parse_event_json(raw)
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1
    print(json.dumps(dataclasses.asdict(ev)))
    return 0


def _cmd_parse_issue(args: argparse.Namespace) -> int:
    raw = sys.stdin.read()
    try:
        issue = parse_issue_json(raw)
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1
    print(json.dumps(dataclasses.asdict(issue)))
    return 0


def _cmd_label_transition(args: argparse.Namespace) -> int:
    try:
        trans = compute_label_transition(args.action, args.po_trigger or "")
    except ValueError as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 1
    print(json.dumps(dataclasses.asdict(trans)))
    return 0


def _cmd_format_comment(args: argparse.Namespace) -> int:
    log_tail = sys.stdin.read() if not args.log_tail else args.log_tail
    body = format_failure_comment(
        slug=args.slug,
        issue_num=args.issue,
        model=args.model,
        log_tail=log_tail,
    )
    print(body)
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="po_handler",
        description="PO handler pure-logic CLI",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("has-complete-ac", help="Exit 0 if stdin body has AC checkboxes")
    sub.add_parser("extract-brief", help="Strip Original brief section from stdin body")
    sub.add_parser("parse-event", help="Parse event JSON from stdin → JSON on stdout")
    sub.add_parser("parse-issue", help="Parse gh issue view --json from stdin → JSON on stdout")

    p_lt = sub.add_parser("label-transition", help="Compute label add/remove for a PO action")
    p_lt.add_argument("--action", required=True, help="PO action (A/B/C/D/E/F_requeue/…)")
    p_lt.add_argument("--po-trigger", default="", help="PO trigger label (for retry paths)")

    p_fc = sub.add_parser("format-comment", help="Format a PO failure comment")
    p_fc.add_argument("--slug", required=True)
    p_fc.add_argument("--issue", required=True)
    p_fc.add_argument("--model", required=True)
    p_fc.add_argument("--log-tail", default="", help="Log tail text (else read stdin)")

    args = parser.parse_args(argv)
    handlers = {
        "has-complete-ac": _cmd_has_complete_ac,
        "extract-brief": _cmd_extract_brief,
        "parse-event": _cmd_parse_event,
        "parse-issue": _cmd_parse_issue,
        "label-transition": _cmd_label_transition,
        "format-comment": _cmd_format_comment,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
