#!/usr/bin/env bats
# tests/anomaly-detector.bats — coverage for reconcile_anomalies (#195).
#
# Verifies the post-#195 contract: deterministic mining of the reconciler
# log for label-flip-rate anomalies; threshold-gated Signal with per-ticket
# cool-down; observational only (no auto-mutation, like reconcile_lost_issues).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export OPS_LOG="$BATS_TMPDIR/ops.log"
    rm -f "$OPS_LOG"

    export LOOP_ANOMALY_STATE_DIR="$BATS_TMPDIR/anomaly-notified-$$"
    rm -rf "$LOOP_ANOMALY_STATE_DIR"

    # Make the threshold low so we can drive the test with a few log lines.
    export LOOP_ANOMALY_THRESHOLD=3
    export LOOP_ANOMALY_WINDOW_HOURS=1
    export LOOP_ANOMALY_NOTIFY_HOURS=24

    export REPO="owner/test-repo"
    export DRY_RUN=false
    export LOG_FILE="$LOOP_LOG_DIR/loop-reconciler.log"

    export LOOP_RECONCILER_LIB_ONLY=1
    # shellcheck source=../scanner/reconciler.sh
    source "$REPO_ROOT/scanner/reconciler.sh"

    loop_notify() { echo "loop_notify $*" >> "$OPS_LOG"; }
}

teardown() {
    rm -rf "$LOOP_ANOMALY_STATE_DIR" "$OPS_LOG" "$LOG_FILE"
}

# Helper: write N synthetic touch lines for a ticket, all timestamped now.
seed_touches() {
    local num="$1" count="$2" pattern="${3:-alias-rename issue}"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    : > "$LOG_FILE"
    for ((i=0; i<count; i++)); do
        echo "[${ts}] [reconciler] [$REPO] $pattern #$num: po-review → needs-po" >> "$LOG_FILE"
    done
}

@test "anomaly threshold met: Signal fires once" {
    seed_touches 42 3 "alias-rename issue"

    run reconcile_anomalies "$REPO"
    [ "$status" -eq 0 ]

    grep -q "^loop_notify .*#42.*3×" "$OPS_LOG"
}

@test "below threshold: no Signal" {
    seed_touches 42 2 "alias-rename issue"  # threshold=3, count=2

    run reconcile_anomalies "$REPO"
    [ "$status" -eq 0 ]

    [ ! -s "$OPS_LOG" ] || ! grep -q "^loop_notify" "$OPS_LOG"
}

@test "cool-down: second tick within window does NOT re-Signal" {
    seed_touches 42 5 "alias-rename issue"

    reconcile_anomalies "$REPO"
    local notifies1
    notifies1=$(grep -c "^loop_notify" "$OPS_LOG" 2>/dev/null || echo 0)
    [ "$notifies1" -eq 1 ]

    # Same log, run again — sentinel should suppress.
    reconcile_anomalies "$REPO"
    local notifies2
    notifies2=$(grep -c "^loop_notify" "$OPS_LOG" 2>/dev/null || echo 0)
    [ "$notifies2" -eq 1 ]
}

@test "observational only: zero backend mutations on anomaly" {
    seed_touches 42 5 "alias-rename issue"

    backend_add_label()    { echo "backend_add_label $*"    >> "$OPS_LOG"; }
    backend_remove_label() { echo "backend_remove_label $*" >> "$OPS_LOG"; }
    backend_comment_issue(){ echo "backend_comment_issue $*">> "$OPS_LOG"; }

    reconcile_anomalies "$REPO"

    grep -q "^loop_notify"             "$OPS_LOG"
    ! grep -q "^backend_add_label"     "$OPS_LOG"
    ! grep -q "^backend_remove_label"  "$OPS_LOG"
    ! grep -q "^backend_comment_issue" "$OPS_LOG"
}

@test "DRY_RUN=true: detect but do not Signal" {
    seed_touches 42 5 "alias-rename issue"
    DRY_RUN=true

    reconcile_anomalies "$REPO"

    [ ! -s "$OPS_LOG" ] || ! grep -q "^loop_notify" "$OPS_LOG"
    DRY_RUN=false
}

@test "different patterns count toward the same ticket's total" {
    # Mix alias-rename + synonym + UNBLOCK touches on #42.
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    : > "$LOG_FILE"
    echo "[${ts}] [reconciler] [$REPO] alias-rename issue #42: po-review → needs-po" >> "$LOG_FILE"
    echo "[${ts}] [reconciler] [$REPO] synonym rename issue #42: review-pending → needs-review" >> "$LOG_FILE"
    echo "[${ts}] [reconciler] [$REPO] UNBLOCK issue #42 (deps satisfied)" >> "$LOG_FILE"
    # 3 touches with threshold=3 → trigger.

    run reconcile_anomalies "$REPO"
    [ "$status" -eq 0 ]
    grep -q "^loop_notify .*#42" "$OPS_LOG"
}

@test "SQL-backed monitor path drives Signal alert" {
    mkdir -p "$BATS_TMPDIR/bin"
    cat > "$BATS_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env sh
printf '[{"issue_number":77,"touches":4}]'
SH
    chmod +x "$BATS_TMPDIR/bin/curl"
    PATH="$BATS_TMPDIR/bin:$PATH"
    export PATH
    export BOUNTY_MONITOR_URL="http://monitor.test"
    rm -f "$LOG_FILE"

    run reconcile_anomalies "$REPO"
    [ "$status" -eq 0 ]

    grep -q "^loop_notify .*#77.*4" "$OPS_LOG"
}

@test "SQL monitor failure falls back to log mining" {
    mkdir -p "$BATS_TMPDIR/bin"
    cat > "$BATS_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env sh
exit 22
SH
    chmod +x "$BATS_TMPDIR/bin/curl"
    PATH="$BATS_TMPDIR/bin:$PATH"
    export PATH
    export BOUNTY_MONITOR_URL="http://monitor.test"
    seed_touches 88 3 "alias-rename issue"

    run reconcile_anomalies "$REPO"
    [ "$status" -eq 0 ]

    grep -q "^loop_notify .*#88.*3" "$OPS_LOG"
}
