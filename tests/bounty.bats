#!/usr/bin/env bats
# tests/bounty.bats — unit tests for lib/bounty.sh payload helper.
# curl calls are intercepted by the mock binary in test_helper/.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    # Expose mock-curl.sh as the curl binary via a per-test temp bin directory.
    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-curl.sh" "$BATS_TMPDIR/bin/curl"
    chmod +x "$BATS_TMPDIR/bin/curl"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # shellcheck source=../lib/bounty.sh
    source "$REPO_ROOT/lib/bounty.sh"

    # Point at the mock so tests don't need a real loop-monitor.
    export BOUNTY_URL="http://127.0.0.1:18792"
    export BOUNTY_TIMEOUT="1"

    PAYLOAD_FILE="$BATS_TMPDIR/payload.json"
    export CURL_PAYLOAD_FILE="$PAYLOAD_FILE"
    unset CURL_MOCK_EXIT CURL_MOCK_LOG
}

teardown() {
    rm -rf "${BATS_TMPDIR:?}/bin" "${BATS_TMPDIR:?}/payload.json" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# (a) valid v1.0 payload accepted
# ---------------------------------------------------------------------------

@test "bounty_report: valid v1.0 payload has correct api field" {
    BOUNTY_API_VERSION="1.0"
    bounty_report "dev_start" project=myapp issue_num=42

    [ -f "$PAYLOAD_FILE" ]
    run python3 -c "import json,sys; d=json.load(sys.stdin); print(d['api'])" < "$PAYLOAD_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "1.0" ]
}

@test "bounty_report: valid v1.0 payload contains required fields" {
    BOUNTY_API_VERSION="1.0"
    bounty_report "dev_done" project=loop issue_num=7

    [ -f "$PAYLOAD_FILE" ]
    run python3 - "$PAYLOAD_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
required = ["api", "core_version", "event", "timestamp"]
missing = [k for k in required if k not in d]
if missing:
    print("missing:", missing)
    sys.exit(1)
PY
    [ "$status" -eq 0 ]
}

@test "bounty_report: returns 0 when monitor accepts v1.0 payload" {
    BOUNTY_API_VERSION="1.0"
    export CURL_MOCK_EXIT=0
    run bounty_report "dev_start" project=myapp
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (b) future v1.x payload — extra unknown key=value args are ignored
# ---------------------------------------------------------------------------

@test "bounty_report: extra unknown key=value args are not included in payload" {
    BOUNTY_API_VERSION="1.0"
    bounty_report "dev_start" project=myapp unknown_field=foo another_extra=bar

    [ -f "$PAYLOAD_FILE" ]
    run python3 - "$PAYLOAD_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for key in ("unknown_field", "another_extra"):
    if key in d:
        print("unexpected key in payload:", key)
        sys.exit(1)
PY
    [ "$status" -eq 0 ]
}

@test "bounty_report: known fields are still present when extra args are passed" {
    BOUNTY_API_VERSION="1.0"
    bounty_report "qa_pass" project=loop issue_num=3 pr_num=10 extra_future_field=ignored

    [ -f "$PAYLOAD_FILE" ]
    run python3 - "$PAYLOAD_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d["api"] == "1.0", "api mismatch"
assert d["event"] == "qa_pass", "event mismatch"
assert d["project"] == "loop", "project mismatch"
assert d["issue_num"] == 3, "issue_num mismatch"
assert d["pr_num"] == 10, "pr_num mismatch"
PY
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (c) v2.0 payload rejected with HTTP 426 — client handles it gracefully
# ---------------------------------------------------------------------------

@test "bounty_report: returns 0 when monitor responds with 426 (fire-and-forget)" {
    BOUNTY_API_VERSION="1.0"
    # curl -f exits 22 for HTTP 4xx/5xx errors (simulates 426 from monitor)
    export CURL_MOCK_EXIT=22
    run bounty_report "dev_start" project=myapp
    [ "$status" -eq 0 ]
}

@test "bounty_report: returns 0 when curl times out (monitor unreachable)" {
    BOUNTY_API_VERSION="1.0"
    # curl exits 28 on timeout
    export CURL_MOCK_EXIT=28
    run bounty_report "dev_start" project=myapp
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (d) missing api field — treated as 1.0 with deprecation warning
# ---------------------------------------------------------------------------

@test "bounty_report: empty BOUNTY_API_VERSION defaults payload api to 1.0" {
    BOUNTY_API_VERSION=""
    bounty_report "dev_start" project=myapp

    [ -f "$PAYLOAD_FILE" ]
    run python3 -c "import json,sys; d=json.load(sys.stdin); print(d['api'])" < "$PAYLOAD_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "1.0" ]
}

@test "bounty_report: empty BOUNTY_API_VERSION emits deprecation warning on stderr" {
    BOUNTY_API_VERSION=""
    # Run without `run` so we can capture stderr via subshell redirect
    local warn_file="$BATS_TMPDIR/warn.txt"
    bounty_report "dev_start" project=myapp 2>"$warn_file"

    run grep -i "deprecat" "$warn_file"
    [ "$status" -eq 0 ]
}

@test "bounty_report: empty BOUNTY_API_VERSION still returns 0" {
    BOUNTY_API_VERSION=""
    run bounty_report "dev_start" project=myapp
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# _bounty_core_version() — three resolution paths
# ---------------------------------------------------------------------------

@test "_bounty_core_version: returns LOOP_VERSION when env var is set" {
    LOOP_VERSION="9.9.9" run _bounty_core_version
    [ "$status" -eq 0 ]
    [ "$output" = "9.9.9" ]
}

@test "_bounty_core_version: reads VERSION file when LOOP_VERSION is unset" {
    local vfile="$BATS_TMPDIR/VERSION"
    printf '1.2.3' > "$vfile"
    unset LOOP_VERSION
    LOOP_ROOT="$BATS_TMPDIR" run _bounty_core_version
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.3" ]
}

@test "_bounty_core_version: returns unknown when neither env var nor VERSION file is present" {
    unset LOOP_VERSION
    LOOP_ROOT="$BATS_TMPDIR/nonexistent" run _bounty_core_version
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "bounty_report: payload core_version is non-empty" {
    BOUNTY_API_VERSION="1.0"
    LOOP_VERSION="0.1.0"
    bounty_report "dev_start" project=myapp

    [ -f "$PAYLOAD_FILE" ]
    run python3 - "$PAYLOAD_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
cv = d.get("core_version", "")
if not cv:
    print("core_version is empty or missing")
    sys.exit(1)
PY
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# loop_id — stable per-instance identifier
# ---------------------------------------------------------------------------

@test "bounty_report: default loop_id is stable across two calls with same env" {
    BOUNTY_API_VERSION="1.0"
    unset LOOP_ID
    export LOOP_ROOT="$BATS_TMPDIR"

    bounty_report "dev_done" project=myapp issue_num=1
    [ -f "$PAYLOAD_FILE" ]
    local id1
    id1="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['loop_id'])" < "$PAYLOAD_FILE")"

    rm -f "$PAYLOAD_FILE"
    bounty_report "dev_done" project=myapp issue_num=1
    [ -f "$PAYLOAD_FILE" ]
    local id2
    id2="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['loop_id'])" < "$PAYLOAD_FILE")"

    [ "$id1" = "$id2" ]
    [ -n "$id1" ]
}

@test "bounty_report: LOOP_ID env override appears in payload" {
    BOUNTY_API_VERSION="1.0"
    export LOOP_ID="test-instance-abc"

    bounty_report "merge_done" project=myapp pr_num=5

    [ -f "$PAYLOAD_FILE" ]
    run python3 -c "import json,sys; d=json.load(sys.stdin); print(d['loop_id'])" < "$PAYLOAD_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "test-instance-abc" ]
}

@test "bounty_report: core_version and loop_id present for po_start, dev_done, rework_failed" {
    BOUNTY_API_VERSION="1.0"
    export LOOP_VERSION="2.0.0"
    export LOOP_ID="ci-instance"

    for event in po_start dev_done rework_failed; do
        rm -f "$PAYLOAD_FILE"
        bounty_report "$event" project=myapp issue_num=10

        [ -f "$PAYLOAD_FILE" ]
        run python3 - "$PAYLOAD_FILE" "$event" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
ev = sys.argv[2]
assert d.get("core_version"), f"core_version missing for {ev}"
assert d.get("loop_id"), f"loop_id missing for {ev}"
assert d["event"] == ev, f"event mismatch: {d['event']} != {ev}"
PY
        [ "$status" -eq 0 ]
    done
}
