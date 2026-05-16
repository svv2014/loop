#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file updated every scanner tick (#413).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_EXTRA_PATH=""
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Expose a stub gh that returns empty lists so run_once completes quickly.
    mkdir -p "$BATS_TMPDIR/bin"
    cat > "$BATS_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
# Return empty arrays for any list call; exit 0 for everything else.
case "$*" in
    *"pr list"*|*"issue list"*|*"api"*)
        echo "[]" ;;
esac
exit 0
GH
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Stub python3 to avoid real YAML parsing.
    cat > "$BATS_TMPDIR/bin/python3" <<'PY'
#!/usr/bin/env bash
# Return empty for slugs, passthrough otherwise.
cat /dev/stdin 2>/dev/null || true
exit 0
PY
    chmod +x "$BATS_TMPDIR/bin/python3"

    export HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
    export DEDUP_DIR="$BATS_TMPDIR/dedup"
    export STAGE_AGE_DIR="$BATS_TMPDIR/stage-age"
    mkdir -p "$DEDUP_DIR" "$STAGE_AGE_DIR"

    # Source only the function definitions from scanner.sh (stop before acquire_lock).
    local _src="$BATS_TMPDIR/scanner-src.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        printf "HEARTBEAT_FILE='%s'\n" "$HEARTBEAT_FILE"
        printf "DEDUP_DIR='%s'\n" "$DEDUP_DIR"
        printf "STAGE_AGE_DIR='%s'\n" "$STAGE_AGE_DIR"
        printf "LOG_FILE='%s/loop-scanner.log'\n" "$LOOP_LOG_DIR"
        awk '
            /^SCRIPT_DIR=/           { next }
            /^LOOP_ROOT=/            { next }
            /^HEARTBEAT_FILE=/       { next }
            /^DEDUP_DIR=/            { next }
            /^STAGE_AGE_DIR=/        { next }
            /^LOG_FILE=/             { next }
            /^for arg in "\$@"; do$/ { skip=1; print "DRY_RUN=false"; print "ONCE=false"; next }
            skip && /^done$/         { skip=0; next }
            skip                     { next }
            /^acquire_lock$/         { exit }
            { print }
        ' "$REPO_ROOT/scanner/scanner.sh"
    } > "$_src"
    # shellcheck disable=SC1090
    source "$_src"

    # Stub loop_list_slugs to return empty (no projects to scan).
    loop_list_slugs() { echo ""; }
    # Stub jobs_init_schema to be a no-op.
    jobs_init_schema() { return 0; }
    # Stub _sweep_stale_locks.
    _sweep_stale_locks() { return 0; }
}

teardown() {
    rm -f "$HEARTBEAT_FILE"
}

@test "run_once writes heartbeat file" {
    [ ! -f "$HEARTBEAT_FILE" ]
    run_once
    [ -f "$HEARTBEAT_FILE" ]
}

@test "run_once updates heartbeat timestamp on each call" {
    run_once
    local ts1
    ts1=$(cat "$HEARTBEAT_FILE")

    sleep 1
    run_once
    local ts2
    ts2=$(cat "$HEARTBEAT_FILE")

    [ "$ts2" -gt "$ts1" ]
}

@test "scanner.sh declares HEARTBEAT_FILE variable" {
    grep -q "HEARTBEAT_FILE=" "$REPO_ROOT/scanner/scanner.sh"
}

@test "run_once writes epoch seconds to heartbeat file" {
    run_once
    local ts now
    ts=$(cat "$HEARTBEAT_FILE")
    now=$(date +%s)
    # Timestamp must be recent (within 5s).
    [ $(( now - ts )) -lt 5 ]
}
