#!/usr/bin/env bats
# tests/label-transition-events.bats — covers backend_add_label / backend_remove_label
# wrapper functions in lib/backends/backend.sh that emit label_transition audit events.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"

    # Wire mock curl so loop_audit_event doesn't hit a real server.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-curl.sh" "$BATS_TMPDIR/bin/curl"
    chmod +x "$BATS_TMPDIR/bin/curl"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    PAYLOAD_FILE="$BATS_TMPDIR/audit-payload.json"
    export CURL_PAYLOAD_FILE="$PAYLOAD_FILE"
    unset CURL_MOCK_EXIT CURL_MOCK_LOG

    # Source libs. backend.sh re-sources github.sh via loop_load_backend, so
    # stubs that must survive must be defined AFTER all sources.
    export BACKEND=github
    source "$REPO_ROOT/lib/notify.sh"
    source "$REPO_ROOT/lib/backends/backend.sh"

    # Stub out low-level helpers AFTER all sourcing is complete.
    loop_add_label()    { return 0; }
    loop_remove_label() { return 0; }

    # Stub backend_issue_view with a file-based call counter so before/after
    # differ even when run in subshells (where shell vars can't be incremented).
    _VIEW_COUNTER_FILE="$BATS_TMPDIR/view-call-count"
    printf '0' > "$_VIEW_COUNTER_FILE"
    export _VIEW_COUNTER_FILE

    backend_issue_view() {
        local _n
        _n=$(cat "$_VIEW_COUNTER_FILE" 2>/dev/null || printf '0')
        printf '%d' $(( _n + 1 )) > "$_VIEW_COUNTER_FILE"
        if [ "$_n" -eq 0 ]; then
            printf '["label-a","label-b"]'
        else
            printf '["label-a","label-b","needs-qa"]'
        fi
    }
    export -f backend_issue_view
}

teardown() {
    rm -rf "${BATS_TMPDIR:?}/bin" "${BATS_TMPDIR:?}/audit-payload.json" 2>/dev/null || true
}

# ---------------------------------------------------------------------------

@test "backend_add_label emits one event with op=add and matching before/after labels" {
    backend_add_label "owner/repo" 42 "needs-qa"

    [ -f "$PAYLOAD_FILE" ]
    run python3 - "$PAYLOAD_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d["event"] == "label_transition", f"event={d['event']}"
p = d["payload"]
assert p["op"] == "add",                   f"op={p['op']}"
assert p["number"] == 42,                  f"number={p['number']}"
assert p["kind"] == "issue",               f"kind={p['kind']}"
assert "label-a" in p["before_labels"],    f"before_labels={p['before_labels']}"
assert "needs-qa" in p["after_labels"],    f"after_labels={p['after_labels']}"
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "backend_remove_label emits one event with op=remove" {
    # Reset file counter and adjust stub: before has needs-qa, after doesn't.
    printf '0' > "$_VIEW_COUNTER_FILE"
    backend_issue_view() {
        local _n
        _n=$(cat "$_VIEW_COUNTER_FILE" 2>/dev/null || printf '0')
        printf '%d' $(( _n + 1 )) > "$_VIEW_COUNTER_FILE"
        if [ "$_n" -eq 0 ]; then
            printf '["label-a","needs-qa"]'
        else
            printf '["label-a"]'
        fi
    }
    export -f backend_issue_view

    backend_remove_label "owner/repo" 42 "needs-qa"

    [ -f "$PAYLOAD_FILE" ]
    run python3 - "$PAYLOAD_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d["event"] == "label_transition", f"event={d['event']}"
p = d["payload"]
assert p["op"] == "remove",                f"op={p['op']}"
assert p["number"] == 42,                  f"number={p['number']}"
assert "needs-qa" in p["before_labels"],   f"before_labels={p['before_labels']}"
assert "needs-qa" not in p["after_labels"],f"after_labels={p['after_labels']}"
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "failing impl still propagates non-zero exit code" {
    # Override the impl to fail.
    _backend_add_label_impl() { return 7; }
    export -f _backend_add_label_impl

    run backend_add_label "owner/repo" 42 "needs-qa"
    [ "$status" -eq 7 ]
}

@test "source field is the basename of the caller script" {
    backend_add_label "owner/repo" 42 "needs-qa"

    [ -f "$PAYLOAD_FILE" ]
    run python3 - "$PAYLOAD_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
p = d["payload"]
# source must be a plain basename (no slashes) and non-empty
src = p.get("source", "")
assert src,                  "source is empty"
assert "/" not in src,       f"source contains slash: {src}"
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}
