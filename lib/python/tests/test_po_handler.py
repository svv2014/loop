"""Unit tests for lib/python/po_handler.py.

Run:
    python3 -m pytest lib/python/tests/test_po_handler.py -v

Coverage (≥80% required on po_handler.py):
    python3 -m coverage run -m pytest lib/python/tests/test_po_handler.py
    python3 -m coverage report --include='lib/python/po_handler.py' --fail-under=80

Fixtures live in lib/python/tests/fixtures/ and are frozen snapshots of real
``gh issue view --json`` responses.  Tests never call ``gh`` or any external
service.
"""

import dataclasses
import json
import os
import sys
from io import StringIO
from pathlib import Path

import pytest

# Ensure the project root is on sys.path so ``import lib.python.po_handler`` works
# when pytest is invoked from anywhere inside the repo.
_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.python.po_handler import (
    EventData,
    IssueData,
    LabelTransition,
    compute_label_transition,
    extract_original_brief,
    format_failure_comment,
    has_complete_ac,
    main,
    parse_event_json,
    parse_issue_json,
)

FIXTURES = Path(__file__).parent / "fixtures"


def load_fixture(name: str) -> str:
    return (FIXTURES / name).read_text()


# ---------------------------------------------------------------------------
# parse_issue_json
# ---------------------------------------------------------------------------

class TestParseIssueJson:
    def test_parses_issue_with_ac(self):
        issue = parse_issue_json(load_fixture("issue_with_ac.json"))
        assert issue.number == 42
        assert issue.title == "Add rate-limit retry to gh API calls"
        assert issue.state == "OPEN"
        assert "dev" in issue.labels
        assert "in-progress" in issue.labels
        assert "Acceptance Criteria" in issue.body

    def test_parses_issue_no_ac(self):
        issue = parse_issue_json(load_fixture("issue_no_ac.json"))
        assert issue.number == 7
        assert issue.labels == ["loop.po_review"]

    def test_null_body_becomes_empty_string(self):
        raw = json.dumps({"number": 1, "title": "t", "body": None, "labels": [], "state": "OPEN"})
        issue = parse_issue_json(raw)
        assert issue.body == ""

    def test_missing_fields_use_defaults(self):
        issue = parse_issue_json("{}")
        assert issue.number == 0
        assert issue.title == ""
        assert issue.labels == []

    def test_raises_on_malformed_json(self):
        with pytest.raises(json.JSONDecodeError):
            parse_issue_json("not json")

    def test_labels_extracted_by_name(self):
        raw = json.dumps({
            "number": 3,
            "title": "x",
            "body": "",
            "state": "OPEN",
            "labels": [{"id": "L1", "name": "bug"}, {"id": "L2", "name": "dev"}],
        })
        issue = parse_issue_json(raw)
        assert issue.labels == ["bug", "dev"]


# ---------------------------------------------------------------------------
# parse_event_json
# ---------------------------------------------------------------------------

class TestParseEventJson:
    def test_parses_direct_payload(self):
        ev = parse_event_json(load_fixture("event_direct.json"))
        assert ev.slug == "myproject"
        assert ev.issue_number == "42"
        assert ev.issue_title == "Add rate-limit retry"

    def test_parses_wrapped_payload(self):
        ev = parse_event_json(load_fixture("event_wrapped.json"))
        assert ev.slug == "myproject"
        assert ev.issue_number == "42"

    def test_integer_issue_number_becomes_string(self):
        raw = json.dumps({"slug": "s", "issue_number": 99, "issue_title": "", "issue_url": ""})
        ev = parse_event_json(raw)
        assert ev.issue_number == "99"

    def test_raises_on_malformed_json(self):
        with pytest.raises(json.JSONDecodeError):
            parse_event_json("{bad json")

    def test_missing_fields_use_empty_string(self):
        ev = parse_event_json("{}")
        assert ev.slug == ""
        assert ev.issue_number == ""


# ---------------------------------------------------------------------------
# has_complete_ac
# ---------------------------------------------------------------------------

class TestHasCompleteAc:
    def test_positive_with_checkboxes(self):
        issue = parse_issue_json(load_fixture("issue_with_ac.json"))
        assert has_complete_ac(issue.body) is True

    def test_negative_no_ac_section(self):
        issue = parse_issue_json(load_fixture("issue_no_ac.json"))
        assert has_complete_ac(issue.body) is False

    def test_epic_with_ac(self):
        issue = parse_issue_json(load_fixture("issue_epic_with_ac.json"))
        assert has_complete_ac(issue.body) is True

    def test_empty_body_returns_false(self):
        assert has_complete_ac("") is False

    def test_ac_section_with_no_checkboxes_returns_false(self):
        body = "## Acceptance Criteria\n\nJust prose, no checkboxes here.\n\n## Notes\n\nfoo"
        assert has_complete_ac(body) is False

    def test_checked_box_counts(self):
        body = "## Acceptance Criteria\n\n- [x] Already done\n"
        assert has_complete_ac(body) is True

    def test_ac_section_stops_at_next_heading(self):
        # Checkboxes only appear after the next ## heading — should not count.
        body = "## Acceptance Criteria\n\nNo checkboxes here.\n\n## Notes\n\n- [ ] Item in notes"
        assert has_complete_ac(body) is False

    def test_crlf_line_endings_regression_284(self):
        # Regression: CRLF endings must not break checkbox detection (#284).
        issue = parse_issue_json(load_fixture("issue_body_newline_bug.json"))
        assert has_complete_ac(issue.body) is True

    def test_acceptance_heading_without_criteria_word(self):
        body = "## Acceptance\n\n- [ ] Short heading variant\n"
        assert has_complete_ac(body) is True


# ---------------------------------------------------------------------------
# extract_original_brief
# ---------------------------------------------------------------------------

class TestExtractOriginalBrief:
    def test_strips_original_brief_marker(self):
        issue = parse_issue_json(load_fixture("issue_already_expanded.json"))
        brief = extract_original_brief(issue.body)
        assert "## Original brief" not in brief
        assert "## Acceptance Criteria" in brief

    def test_unchanged_when_no_marker(self):
        body = "## Objective\n\nDo the thing."
        assert extract_original_brief(body) == body

    def test_empty_body(self):
        assert extract_original_brief("") == ""

    def test_whitespace_only_body(self):
        assert extract_original_brief("   ") == ""

    def test_multiple_paragraphs_before_marker(self):
        body = "line one\n\nline two\n\n---\n\n## Original brief (preserved by PO)\n\nold text"
        result = extract_original_brief(body)
        assert result == "line one\n\nline two"

    def test_re_triage_does_not_nest(self):
        # Simulates a second PO run on an already-expanded issue.
        already_expanded = parse_issue_json(load_fixture("issue_already_expanded.json"))
        first_pass = extract_original_brief(already_expanded.body)
        second_pass = extract_original_brief(first_pass)
        assert first_pass == second_pass


# ---------------------------------------------------------------------------
# compute_label_transition
# ---------------------------------------------------------------------------

class TestComputeLabelTransition:
    def test_path_A_queues_dev(self):
        t = compute_label_transition("A")
        assert "dev" in t.add
        assert "in-progress" in t.remove

    def test_path_B_no_add(self):
        t = compute_label_transition("B")
        assert t.add == []
        assert "in-progress" in t.remove

    def test_path_C_no_add(self):
        t = compute_label_transition("C")
        assert t.add == []

    def test_path_D_adds_tracker(self):
        t = compute_label_transition("D")
        assert "tracker" in t.add

    def test_path_E_adds_needs_clarification(self):
        t = compute_label_transition("E")
        assert "needs-clarification" in t.add

    def test_path_F_requeue_adds_dev(self):
        t = compute_label_transition("F_requeue")
        assert "dev" in t.add

    def test_path_F_blocked_adds_blocked(self):
        t = compute_label_transition("F_blocked")
        assert "blocked" in t.add

    def test_transient_retry_adds_po_trigger(self):
        t = compute_label_transition("transient_retry", po_trigger="loop.po_review")
        assert "loop.po_review" in t.add

    def test_perm_retry_adds_po_trigger(self):
        t = compute_label_transition("perm_retry", po_trigger="loop.po_review")
        assert "loop.po_review" in t.add

    def test_perm_fail_adds_needs_clarification(self):
        t = compute_label_transition("perm_fail")
        assert "needs-clarification" in t.add

    def test_unknown_action_raises(self):
        with pytest.raises(ValueError, match="Unknown PO action"):
            compute_label_transition("Z")

    def test_returns_label_transition_dataclass(self):
        t = compute_label_transition("A")
        assert isinstance(t, LabelTransition)

    def test_result_is_independent_copy(self):
        t1 = compute_label_transition("A")
        t1.add.append("extra")
        t2 = compute_label_transition("A")
        assert "extra" not in t2.add


# ---------------------------------------------------------------------------
# format_failure_comment
# ---------------------------------------------------------------------------

class TestFormatFailureComment:
    def test_empty_log_tail_returns_fallback(self):
        body = format_failure_comment("myslug", "42", "claude-opus-4-7", "")
        assert "human clarification" in body.lower()
        assert "myslug" in body
        assert "#42" in body

    def test_includes_log_tail_in_code_block(self):
        body = format_failure_comment("s", "1", "m", "some error here")
        assert "```text" in body
        assert "some error here" in body

    def test_truncates_long_log(self):
        big_log = "x" * 70000
        body = format_failure_comment("s", "1", "m", big_log, max_bytes=60000)
        assert len(body) <= 60000 + 200  # header overhead
        assert "truncated" in body

    def test_short_log_not_truncated(self):
        body = format_failure_comment("s", "1", "m", "short log", max_bytes=60000)
        assert "truncated" not in body

    def test_includes_project_and_issue(self):
        body = format_failure_comment("proj", "99", "model", "log")
        assert "proj" in body
        assert "#99" in body


# ---------------------------------------------------------------------------
# CLI interface
# ---------------------------------------------------------------------------

class TestCLI:
    def _run(self, argv, stdin_text=""):
        old_stdin = sys.stdin
        sys.stdin = StringIO(stdin_text)
        try:
            rc = main(argv)
        finally:
            sys.stdin = old_stdin
        return rc

    def test_has_complete_ac_exits_0_when_ac_present(self, capsys):
        body = "## Acceptance Criteria\n\n- [ ] Item\n"
        rc = self._run(["has-complete-ac"], stdin_text=body)
        assert rc == 0

    def test_has_complete_ac_exits_1_when_no_ac(self):
        rc = self._run(["has-complete-ac"], stdin_text="no checkboxes here")
        assert rc == 1

    def test_extract_brief_strips_marker(self, capsys):
        body = "intro\n\n---\n\n## Original brief (preserved by PO)\n\nold"
        rc = self._run(["extract-brief"], stdin_text=body)
        assert rc == 0
        out = capsys.readouterr().out
        assert "Original brief" not in out
        assert "intro" in out

    def test_parse_event_returns_json(self, capsys):
        raw = load_fixture("event_direct.json")
        rc = self._run(["parse-event"], stdin_text=raw)
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        assert data["slug"] == "myproject"

    def test_parse_event_error_on_bad_json(self):
        rc = self._run(["parse-event"], stdin_text="not json")
        assert rc == 1

    def test_parse_issue_returns_json(self, capsys):
        raw = load_fixture("issue_with_ac.json")
        rc = self._run(["parse-issue"], stdin_text=raw)
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        assert data["number"] == 42

    def test_parse_issue_error_on_bad_json(self):
        rc = self._run(["parse-issue"], stdin_text="{bad}")
        assert rc == 1

    def test_label_transition_returns_json(self, capsys):
        rc = self._run(["label-transition", "--action", "A"])
        assert rc == 0
        data = json.loads(capsys.readouterr().out)
        assert "dev" in data["add"]

    def test_label_transition_error_on_unknown_action(self, capsys):
        rc = self._run(["label-transition", "--action", "Z"])
        assert rc == 1

    def test_format_comment_from_arg(self, capsys):
        rc = self._run(
            ["format-comment", "--slug", "s", "--issue", "1",
             "--model", "m", "--log-tail", "some log"],
        )
        assert rc == 0
        out = capsys.readouterr().out
        assert "some log" in out
