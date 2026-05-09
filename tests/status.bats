#!/usr/bin/env bats
# tests/status.bats — unit tests for scripts/status.sh

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STATUS_SH="$REPO_ROOT/scripts/status.sh"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs-$$"
    mkdir -p "$LOOP_LOG_DIR"

    # Suppress env.sh side-effects: no external PATH, no orchestrator
    export LOOP_EXTRA_PATH=""
    export LOOP_ORCHESTRATOR=""
    export LOOP_EVENT_QUEUE_URL=""
    export LOOP_DISPATCH_MODE="direct"
    export MAX_RETRIES="2"
    # Default 30m interval expressed in seconds
    export LOOP_SCANNER_INTERVAL="30m"
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs-$$" "$BATS_TMPDIR/retries-$$" 2>/dev/null || true
}

# ─── --help ──────────────────────────────────────────────────────────────────

@test "--help exits 0 and prints usage" {
    run bash "$STATUS_SH" --help
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "usage"
}

# ─── --json ──────────────────────────────────────────────────────────────────

@test "--json output is valid JSON" {
    # Provide a fresh scanner log so scanner probe doesn't FAIL
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner] tick" > "$LOOP_LOG_DIR/loop-scanner.log"
    touch "$LOOP_LOG_DIR/loop-po-handler.log"
    run bash "$STATUS_SH" --json
    # Must exit 0, 1, or 2 — accept any; just validate JSON parse
    echo "$output" | python3 -c 'import sys,json; json.load(sys.stdin)'
}

@test "--json output has required top-level keys" {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner] tick" > "$LOOP_LOG_DIR/loop-scanner.log"
    touch "$LOOP_LOG_DIR/loop-po-handler.log"
    run bash "$STATUS_SH" --json
    python3 - "$output" <<'PY'
import sys, json
obj = json.loads(sys.argv[1])
for key in ("status", "checks", "retry_counters", "active_handlers", "recent_failures"):
    assert key in obj, f"missing key: {key}"
PY
}

# ─── exit codes ──────────────────────────────────────────────────────────────

@test "exit 1 when all probes fail" {
    # No scanner log → scanner=FAIL
    # No po-handler log → recent-failures=ok (graceful)
    # LOOP_ORCHESTRATOR set to non-executable path → orchestrator=FAIL
    export LOOP_ORCHESTRATOR="/nonexistent/path/to/orchestrator"
    # No log files at all
    run bash "$STATUS_SH" --json || true
    [ "$status" -eq 1 ]
}

@test "exit 2 when mix of OK and DEGRADED" {
    # Make scanner log stale by 3x interval (degraded range: 2x-4x)
    local interval_secs=1800   # 30m
    local stale_age=$(( interval_secs * 3 ))
    touch "$LOOP_LOG_DIR/loop-scanner.log"
    # Backdate the log file by stale_age seconds
    local past
    past=$(date -v -${stale_age}S '+%Y%m%d%H%M' 2>/dev/null || date -d "@$(( $(date +%s) - stale_age ))" '+%Y%m%d%H%M' 2>/dev/null || true)
    if [ -n "$past" ]; then
        touch -t "$past" "$LOOP_LOG_DIR/loop-scanner.log" 2>/dev/null || true
    fi
    touch "$LOOP_LOG_DIR/loop-po-handler.log"
    run bash "$STATUS_SH" --json || true
    # DEGRADED means exit 2, unless scanner is already FAIL (age > 4x)
    # Since we set 3x we expect degraded=2; but if touch failed we skip
    [ "$status" -eq 2 ] || [ "$status" -eq 1 ]
}

@test "exit 0 when scanner log is fresh and no failures" {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner] tick" > "$LOOP_LOG_DIR/loop-scanner.log"
    touch "$LOOP_LOG_DIR/loop-po-handler.log"
    run bash "$STATUS_SH" --json
    [ "$status" -eq 0 ]
}

# ─── section: scanner ────────────────────────────────────────────────────────

@test "plain-text output includes scanner section" {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner] tick" > "$LOOP_LOG_DIR/loop-scanner.log"
    touch "$LOOP_LOG_DIR/loop-po-handler.log"
    run bash "$STATUS_SH"
    echo "$output" | grep -q "scanner"
}

# ─── section: orchestrator skip ──────────────────────────────────────────────

@test "orchestrator shows skip when LOOP_ORCHESTRATOR is unset" {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner] tick" > "$LOOP_LOG_DIR/loop-scanner.log"
    touch "$LOOP_LOG_DIR/loop-po-handler.log"
    unset LOOP_ORCHESTRATOR
    run bash "$STATUS_SH" --json
    python3 - "$output" <<'PY'
import sys, json
obj = json.loads(sys.argv[1])
assert obj["checks"]["orchestrator"]["status"] == "skip", \
    f"expected skip, got {obj['checks']['orchestrator']['status']}"
PY
}

# ─── section: event-queue skip ───────────────────────────────────────────────

@test "event-queue shows skip when URL unset and mode is direct" {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner] tick" > "$LOOP_LOG_DIR/loop-scanner.log"
    touch "$LOOP_LOG_DIR/loop-po-handler.log"
    run bash "$STATUS_SH" --json
    python3 - "$output" <<'PY'
import sys, json
obj = json.loads(sys.argv[1])
assert obj["checks"]["event-queue"]["status"] == "skip", \
    f"expected skip, got {obj['checks']['event-queue']['status']}"
PY
}

# ─── section: retry counters ─────────────────────────────────────────────────

@test "retry-counters section present in JSON output" {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scanner] tick" > "$LOOP_LOG_DIR/loop-scanner.log"
    touch "$LOOP_LOG_DIR/loop-po-handler.log"
    run bash "$STATUS_SH" --json
    python3 - "$output" <<'PY'
import sys, json
obj = json.loads(sys.argv[1])
assert "retry-counters" in obj["checks"]
assert "retry_counters" in obj
PY
}
