#!/usr/bin/env bats
# tests/judge.bats - regression coverage for judge bounty feed events.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    BIN_DIR="$BATS_TMPDIR/bin"
    BAD_BIN_DIR="$BATS_TMPDIR/bad-bin"
    LOOP_ENV_FILE="$REPO_ROOT/loop.env"
    LOOP_ENV_BACKUP="$BATS_TMPDIR/loop.env.backup"
    LOOP_ENV_HAD_FILE=0
    if [ -f "$LOOP_ENV_FILE" ]; then
        cp "$LOOP_ENV_FILE" "$LOOP_ENV_BACKUP"
        LOOP_ENV_HAD_FILE=1
    fi

    mkdir -p "$BIN_DIR" "$BAD_BIN_DIR" "$BATS_TMPDIR/home"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$BAD_BIN_DIR/gh"
    chmod +x "$BAD_BIN_DIR/gh"

    # Simulate a local operator loop.env that would shadow test mocks unless
    # this test owns loop.env for the duration of the run.
    printf 'LOOP_EXTRA_PATH=%s\n' "$BAD_BIN_DIR" > "$REPO_ROOT/loop.env"

    cat > "$BIN_DIR/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
    printf '{"number":123,"title":"Test PR","state":"MERGED","labels":[],"reviews":[],"commits":[],"comments":[],"headRefName":"feature","baseRefName":"main"}'
    exit 0
fi
if [ "${1:-}" = "api" ]; then
    printf '[]'
    exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "comment" ]; then
    printf 'gh pr comment %s\n' "$*" >> "${GH_COMMENT_LOG:?}"
    exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
SH

    cat > "$BIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"outcome":"clean","points":3,"summary":"Looks good."}'
SH

    cat > "$BIN_DIR/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
payload=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d)
            payload="$2"
            shift 2
            ;;
        http://*|https://*)
            url="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done
printf '%s\t%s\n' "$url" "$payload" >> "${CURL_CALLS:?}"
SH

    chmod +x "$BIN_DIR/gh" "$BIN_DIR/claude" "$BIN_DIR/curl"
    printf 'LOOP_EXTRA_PATH=%s\nLOOP_LOG_DIR=%s\n' "$BIN_DIR" "$BATS_TMPDIR/logs" > "$LOOP_ENV_FILE"
    export PATH="$BIN_DIR:$PATH"
    export LOOP_EXTRA_PATH="$BIN_DIR"
    export HOME="$BATS_TMPDIR/home"
    export BOUNTY_URL="http://127.0.0.1:18792"
    export BOUNTY_TIMEOUT="1"
    export CURL_CALLS="$BATS_TMPDIR/curl-calls.tsv"
    export GH_COMMENT_LOG="$BATS_TMPDIR/gh-comments.log"
}

teardown() {
    if [ "${LOOP_ENV_HAD_FILE:-0}" = "1" ]; then
        cp "$LOOP_ENV_BACKUP" "$LOOP_ENV_FILE"
    else
        rm -f "$LOOP_ENV_FILE" 2>/dev/null || true
    fi

    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/bad-bin" "$BATS_TMPDIR/home" \
           "$BATS_TMPDIR/curl-calls.tsv" "$BATS_TMPDIR/gh-comments.log" 2>/dev/null || true
}

@test "judge.sh emits judge_start and judge_done with judge role, model, and duration" {
    run "$REPO_ROOT/scripts/judge.sh" 123 owner/repo "" "judge" "test-proj"

    [ "$status" -eq 0 ]
    [ -f "$CURL_CALLS" ]

    run python3 - "$CURL_CALLS" <<'PY'
import json
import sys

events = []
for line in open(sys.argv[1], encoding="utf-8"):
    url, payload = line.rstrip("\n").split("\t", 1)
    if not url.endswith("/api/report"):
        continue
    events.append(json.loads(payload))

assert [e["event"] for e in events] == ["judge_start", "judge_done"], events
for event in events:
    assert event["role"] == "judge", event
    assert event["model"] == "sonnet", event
    assert event["project"] == "test-proj", event
    assert event["pr_num"] == 123, event
done = events[1]
assert isinstance(done.get("duration_seconds"), int), done
assert done["duration_seconds"] >= 0, done
assert "outcome=clean points=3" in (done.get("detail") or ""), done
PY
    [ "$status" -eq 0 ]
}

@test "merge-handler invokes judge with judge role and non-empty model" {
    grep -F '"$LOOP_ROOT/scripts/judge.sh" "$PR_NUM" "$REPO" "${LOOP_JUDGE_MODEL:-sonnet}" "judge" "$SLUG"' \
        "$REPO_ROOT/scripts/merge-handler.sh"

    ! grep -F '"$LOOP_ROOT/scripts/judge.sh" "$PR_NUM" "$REPO" "" "dev" "$SLUG"' \
        "$REPO_ROOT/scripts/merge-handler.sh"
}
