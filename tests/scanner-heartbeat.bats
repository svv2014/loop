#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — coverage for scanner liveness heartbeat (#413).
# Verifies that:
#   1. _scanner_write_heartbeat writes/updates HEARTBEAT_FILE on each tick.
#   2. restart-scanner-if-stale.sh exits 0 (ok) when heartbeat is fresh.
#   3. restart-scanner-if-stale.sh kills a stale scanner PID and exits cleanly.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export LOOP_EXTRA_PATH=""

    # Extract _scanner_write_heartbeat from scanner.sh.
    local _src="$BATS_TMPDIR/heartbeat-src.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        printf "LOOP_LOG_DIR='%s'\n" "$LOOP_LOG_DIR"
        printf "HEARTBEAT_FILE='%s/scanner-heartbeat'\n" "$LOOP_LOG_DIR"
        printf "DRY_RUN=false\n"
        awk '/^_scanner_write_heartbeat\(\)/{p=1} p; p && /^\}/{p=0; exit}' \
            "$REPO_ROOT/scanner/scanner.sh"
    } > "$_src"
    # shellcheck disable=SC1090
    source "$_src"
    HEARTBEAT_FILE="${LOOP_LOG_DIR}/scanner-heartbeat"
}

teardown() {
    rm -rf "$BATS_TMPDIR/logs" "$BATS_TMPDIR/heartbeat-src.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _scanner_write_heartbeat
# ---------------------------------------------------------------------------

@test "_scanner_write_heartbeat: creates heartbeat file" {
    rm -f "${HEARTBEAT_FILE}"
    _scanner_write_heartbeat
    [ -f "${HEARTBEAT_FILE}" ]
}

@test "_scanner_write_heartbeat: file contains current timestamp" {
    _scanner_write_heartbeat
    local content
    content=$(cat "${HEARTBEAT_FILE}")
    # File must start with a date-time pattern.
    [[ "$content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]
}

@test "_scanner_write_heartbeat: updates mtime on each call" {
    _scanner_write_heartbeat
    local t1
    t1=$(stat -f%m "${HEARTBEAT_FILE}" 2>/dev/null || stat -c%Y "${HEARTBEAT_FILE}")
    sleep 1
    _scanner_write_heartbeat
    local t2
    t2=$(stat -f%m "${HEARTBEAT_FILE}" 2>/dev/null || stat -c%Y "${HEARTBEAT_FILE}")
    [ "$t2" -ge "$t1" ]
}

@test "_scanner_write_heartbeat: no-op when DRY_RUN=true" {
    rm -f "${HEARTBEAT_FILE}"
    DRY_RUN=true _scanner_write_heartbeat || true
    [ ! -f "${HEARTBEAT_FILE}" ]
}

# ---------------------------------------------------------------------------
# restart-scanner-if-stale.sh — freshness checks
# ---------------------------------------------------------------------------

@test "restart-scanner-if-stale.sh: exits 0 (ok) when heartbeat is fresh" {
    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    printf '%s pid=1\n' "$(date '+%Y-%m-%dT%H:%M:%S')" > "$hb"

    run env LOOP_LOG_DIR="${LOOP_LOG_DIR}" \
            LOOP_SCANNER_STALE_THRESHOLD=600 \
            LOOP_EXTRA_PATH="" \
            bash "$REPO_ROOT/scanner/restart-scanner-if-stale.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok:"* ]]
}

@test "restart-scanner-if-stale.sh: exits 0 when heartbeat file absent" {
    rm -f "${LOOP_LOG_DIR}/scanner-heartbeat"

    run env LOOP_LOG_DIR="${LOOP_LOG_DIR}" \
            LOOP_SCANNER_STALE_THRESHOLD=600 \
            LOOP_EXTRA_PATH="" \
            bash "$REPO_ROOT/scanner/restart-scanner-if-stale.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"absent"* ]]
}

@test "restart-scanner-if-stale.sh: kills stale scanner PID" {
    # Start a harmless background process to get a live PID.
    sleep 60 &
    local fake_pid=$!

    local hb="${LOOP_LOG_DIR}/scanner-heartbeat"
    printf '%s pid=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$fake_pid" > "$hb"
    # Backdate the heartbeat file by 20 minutes.
    touch -t "$(date -v-20M +%Y%m%d%H%M.%S 2>/dev/null \
                || date -d '20 minutes ago' +%Y%m%d%H%M.%S)" "$hb"

    # Write a lock file pointing at that PID.
    local lock_file="$BATS_TMPDIR/test-scanner.lock"
    echo "$fake_pid" > "$lock_file"

    run env LOOP_LOG_DIR="${LOOP_LOG_DIR}" \
            LOOP_SCANNER_LOCK="$lock_file" \
            LOOP_SCANNER_STALE_THRESHOLD=600 \
            LOOP_EXTRA_PATH="" \
            bash "$REPO_ROOT/scanner/restart-scanner-if-stale.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"killing"* ]] || [[ "$output" == *"STALE"* ]]

    # The target process must have been killed.
    sleep 0.5
    ! kill -0 "$fake_pid" 2>/dev/null

    rm -f "$lock_file"
}
