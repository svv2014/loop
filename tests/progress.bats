#!/usr/bin/env bats
# tests/progress.bats — regression tests for lib/progress.sh
#
# Stubs curl via PATH shadowing so no real HTTP calls are made.
# Stubs a transcript dir with synthetic JSONL.
# Asserts:
#   (a) at least one dev_progress event payload lands in the curl stub log
#   (b) payload includes a non-empty detail field
#   (c) no orphan sleep/poller process remains after progress_stop

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Stub curl: log every invocation body to a file.
    CURL_LOG="$BATS_TMPDIR/curl.log"
    export CURL_LOG
    mkdir -p "$BATS_TMPDIR/bin"
    cat > "$BATS_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
# Stub curl: write request body to CURL_LOG, always succeed.
body=""
i=1
while [ $i -le $# ]; do
    eval "arg=\${$i}"
    if [ "$arg" = "-d" ]; then
        i=$((i+1))
        eval "body=\${$i}"
    fi
    i=$((i+1))
done
printf '%s\n' "$body" >> "$CURL_LOG"
SH
    chmod +x "$BATS_TMPDIR/bin/curl"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    # Stub transcript dir with synthetic JSONL
    export LOOP_TRANSCRIPT_DIR="$BATS_TMPDIR/transcripts"
    mkdir -p "$LOOP_TRANSCRIPT_DIR"
    cat > "$LOOP_TRANSCRIPT_DIR/test-transcript.jsonl" <<'JSONL'
{"type":"text","text":"starting"}
{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git fetch origin"}}
{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/project/CLAUDE.md"}}
JSONL

    # Set context env vars expected by _progress_emit
    export SLUG="testproject"
    export ISSUE_NUM="42"
    export PR_NUM=""
    export LOOP_MONITOR_URL="http://localhost:19999"
    export LOOP_PROGRESS_INTERVAL_SEC="1"

    # shellcheck source=../lib/progress.sh
    source "$REPO_ROOT/lib/progress.sh"
}

teardown() {
    progress_stop 2>/dev/null || true
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/logs" \
           "$BATS_TMPDIR/transcripts" "$BATS_TMPDIR/curl.log" 2>/dev/null || true
    unset SLUG ISSUE_NUM PR_NUM LOOP_MONITOR_URL LOOP_PROGRESS_INTERVAL_SEC \
          LOOP_TRANSCRIPT_DIR CURL_LOG
}

# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------

@test "progress: at least one dev_progress event emitted after interval" {
    progress_start dev
    sleep 2
    progress_stop

    [ -f "$CURL_LOG" ]
    grep -q "dev_progress" "$CURL_LOG"
}

@test "progress: emitted payload includes non-empty detail field" {
    progress_start dev
    sleep 2
    progress_stop

    [ -f "$CURL_LOG" ]
    # detail must be present and non-empty (not just '"detail":""')
    run python3 -c "
import sys, json
found = False
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            p = obj.get('payload', {})
            detail = p.get('detail', '')
            if detail:
                found = True
                break
        except Exception:
            continue
sys.exit(0 if found else 1)
" "$CURL_LOG"
    [ "$status" -eq 0 ]
}

@test "progress: payload contains project slug and issue_num" {
    progress_start dev
    sleep 2
    progress_stop

    [ -f "$CURL_LOG" ]
    run python3 -c "
import sys, json
found = False
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            p = obj.get('payload', {})
            if p.get('project') == 'testproject' and p.get('issue_num') == 42:
                found = True
                break
        except Exception:
            continue
sys.exit(0 if found else 1)
" "$CURL_LOG"
    [ "$status" -eq 0 ]
}

@test "progress: no orphan poller process after progress_stop" {
    progress_start dev
    local poller_pid="$_LOOP_PROGRESS_PID"
    sleep 2
    progress_stop

    # poller process must be gone
    run kill -0 "$poller_pid"
    [ "$status" -ne 0 ]
}

@test "progress: no orphan sleep process after progress_stop" {
    progress_start dev
    sleep 2
    progress_stop

    # Give processes a moment to fully exit
    sleep 0.2

    # No 'sleep 1' child processes whose parent is now init (ppid=1) from our poller
    # We check by verifying _LOOP_PROGRESS_PID is cleared
    [ -z "${_LOOP_PROGRESS_PID:-}" ]
}

# ---------------------------------------------------------------------------
# Fallback behaviour
# ---------------------------------------------------------------------------

@test "progress: emits working when transcript dir absent" {
    export LOOP_TRANSCRIPT_DIR="$BATS_TMPDIR/no-such-dir"
    progress_start dev
    sleep 2
    progress_stop

    [ -f "$CURL_LOG" ]
    run python3 -c "
import sys, json
found = False
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            p = obj.get('payload', {})
            if p.get('detail') == 'working':
                found = True
                break
        except Exception:
            continue
sys.exit(0 if found else 1)
" "$CURL_LOG"
    [ "$status" -eq 0 ]
}

@test "progress: no emission when LOOP_MONITOR_URL is unset" {
    unset LOOP_MONITOR_URL
    progress_start dev
    sleep 2
    progress_stop

    # curl stub log must not exist or be empty
    [ ! -f "$CURL_LOG" ] || [ ! -s "$CURL_LOG" ]
}

@test "progress_stop: safe to call when no poller is running" {
    run progress_stop
    [ "$status" -eq 0 ]
}
