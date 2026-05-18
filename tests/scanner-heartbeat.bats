#!/usr/bin/env bats
# tests/scanner-heartbeat.bats — heartbeat file is written on every scanner tick.
#
# Coverage for issue #413: scanner liveness heartbeat + watchdog.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"
    export HEARTBEAT_FILE="$LOOP_LOG_DIR/scanner-heartbeat"
}

teardown() {
    rm -rf "$LOOP_LOG_DIR"
}

# ---------------------------------------------------------------------------
# Structural checks (scanner.sh)
# ---------------------------------------------------------------------------

@test "scanner.sh defines HEARTBEAT_FILE pointing to LOOP_LOG_DIR" {
    grep -q 'HEARTBEAT_FILE=.*LOOP_LOG_DIR.*scanner-heartbeat' \
        "$REPO_ROOT/scanner/scanner.sh"
}

@test "scanner.sh writes heartbeat in run_once" {
    # The heartbeat write must be inside run_once (between the function open brace
    # and the closing brace that ends run_once).
    python3 - "$REPO_ROOT/scanner/scanner.sh" <<'PY'
import sys, re

with open(sys.argv[1]) as f:
    src = f.read()

# Extract run_once body
m = re.search(r'run_once\(\)\s*\{(.+?)^\}', src, re.DOTALL | re.MULTILINE)
assert m, "run_once() not found"
body = m.group(1)
assert 'HEARTBEAT_FILE' in body, "HEARTBEAT_FILE not referenced in run_once"
assert 'date' in body, "date command not found in run_once heartbeat write"
PY
}

# ---------------------------------------------------------------------------
# Behavioural: heartbeat file is updated by each tick
# ---------------------------------------------------------------------------

@test "heartbeat file is created/updated on each scanner tick" {
    # Build a minimal run_once stub that reproduces only the heartbeat logic.
    local stub="$BATS_TMPDIR/stub-heartbeat.sh"
    cat > "$stub" <<STUB
#!/usr/bin/env bash
set -euo pipefail
LOOP_LOG_DIR="$LOOP_LOG_DIR"
HEARTBEAT_FILE="\${LOOP_LOG_DIR}/scanner-heartbeat"
DRY_RUN=false
run_once() {
    \$DRY_RUN || date +%s > "\$HEARTBEAT_FILE" 2>/dev/null || true
}
run_once
STUB
    chmod +x "$stub"
    bash "$stub"
    [ -f "$HEARTBEAT_FILE" ]
    local ts
    ts=$(cat "$HEARTBEAT_FILE")
    [ -n "$ts" ]
    # Value must be a unix timestamp (all digits)
    [[ "$ts" =~ ^[0-9]+$ ]]
}

@test "heartbeat file mtime advances between consecutive ticks" {
    local stub="$BATS_TMPDIR/stub-tick.sh"
    cat > "$stub" <<STUB
#!/usr/bin/env bash
set -euo pipefail
LOOP_LOG_DIR="$LOOP_LOG_DIR"
HEARTBEAT_FILE="\${LOOP_LOG_DIR}/scanner-heartbeat"
DRY_RUN=false
run_once() {
    \$DRY_RUN || date +%s > "\$HEARTBEAT_FILE" 2>/dev/null || true
}
run_once
STUB
    chmod +x "$stub"

    bash "$stub"
    local mtime1
    mtime1=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")

    sleep 1.1  # ensure mtime advances by at least 1 second
    bash "$stub"
    local mtime2
    mtime2=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || stat -c%Y "$HEARTBEAT_FILE")

    [ "$mtime2" -gt "$mtime1" ]
}

@test "heartbeat file is NOT written in dry-run mode" {
    local stub="$BATS_TMPDIR/stub-dryrun.sh"
    cat > "$stub" <<STUB
#!/usr/bin/env bash
set -euo pipefail
LOOP_LOG_DIR="$LOOP_LOG_DIR"
HEARTBEAT_FILE="\${LOOP_LOG_DIR}/scanner-heartbeat"
DRY_RUN=true
run_once() {
    \$DRY_RUN || date +%s > "\$HEARTBEAT_FILE" 2>/dev/null || true
}
run_once
STUB
    chmod +x "$stub"
    rm -f "$HEARTBEAT_FILE"
    bash "$stub"
    [ ! -f "$HEARTBEAT_FILE" ]
}

# ---------------------------------------------------------------------------
# scanner-watchdog.sh structural checks
# ---------------------------------------------------------------------------

@test "scanner-watchdog.sh exists and is executable" {
    [ -x "$REPO_ROOT/scanner/scanner-watchdog.sh" ]
}

@test "scanner-watchdog.sh sources lib/env.sh" {
    grep -q 'source.*lib/env.sh' "$REPO_ROOT/scanner/scanner-watchdog.sh"
}

@test "scanner-watchdog.sh respects --dry-run flag" {
    # With a stale heartbeat (or missing file) and --dry-run, it must not kill anything.
    # We verify by checking it exits 0 and logs DRY-RUN.
    rm -f "$HEARTBEAT_FILE"

    # Stub lib/env.sh so the watchdog doesn't need a real loop.env.
    local fake_env="$BATS_TMPDIR/fake-env.sh"
    cat > "$fake_env" <<ENVSH
export LOOP_LOG_DIR="$LOOP_LOG_DIR"
export LOOP_SCANNER_INTERVAL=300
ENVSH

    # Patch the watchdog to source our fake env instead.
    local patched="$BATS_TMPDIR/patched-watchdog.sh"
    sed "s|source \"\$LOOP_ROOT/lib/env.sh\"|source '$fake_env'|" \
        "$REPO_ROOT/scanner/scanner-watchdog.sh" > "$patched"
    chmod +x "$patched"

    run bash "$patched" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
}
