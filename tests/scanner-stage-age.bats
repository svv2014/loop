#!/usr/bin/env bats
# tests/scanner-stage-age.bats — unit tests for _stage_age_exceeded in scanner/scanner.sh.
# Added by QA for PR #419 (issue #418): verifies round-robin skip logic.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    export LOOP_EXTRA_PATH=""
    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    # Override STAGE_AGE_DIR so tests don't touch /tmp/loop-stage-age.
    export STAGE_AGE_DIR="$BATS_TMPDIR/stage-age"
    mkdir -p "$STAGE_AGE_DIR"

    # Extract _dedup_key and _stage_age_exceeded from scanner.sh.
    local _src="$BATS_TMPDIR/stage-age-src.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        printf "STAGE_AGE_DIR='%s'\n" "$STAGE_AGE_DIR"
        # Pull in _dedup_key
        awk '/^_dedup_key\(\)/{p=1} p; p && /^\}/{p=0; exit}' \
            "$REPO_ROOT/scanner/scanner.sh"
        # Pull in _stage_age_exceeded (stop before 'emit')
        awk '/^_stage_age_exceeded\(\)/{p=1} p; p && /^\}/{exit}' \
            "$REPO_ROOT/scanner/scanner.sh"
    } > "$_src"
    # shellcheck disable=SC1090
    source "$_src"
}

teardown() {
    rm -rf "$BATS_TMPDIR/stage-age" "$BATS_TMPDIR/logs" "$BATS_TMPDIR/stage-age-src.sh"
}

@test "_stage_age_exceeded: first call creates tracking file and returns 1 (not exceeded)" {
    run _stage_age_exceeded "loop.pr_review:myslug:42" 3600
    [ "$status" -eq 1 ]
    # File must now exist
    local key_file
    key_file="$STAGE_AGE_DIR/$(_dedup_key "loop.pr_review:myslug:42")"
    [ -f "$key_file" ]
}

@test "_stage_age_exceeded: second call within max_age returns 1 (still not exceeded)" {
    _stage_age_exceeded "loop.pr_review:myslug:99" 3600 || true  # first call: creates file
    run _stage_age_exceeded "loop.pr_review:myslug:99" 3600
    [ "$status" -eq 1 ]
}

@test "_stage_age_exceeded: returns 0 when file is older than max_age" {
    local key="loop.pr_review:myslug:7"
    _stage_age_exceeded "$key" 3600 || true  # creates file
    local key_file
    key_file="$STAGE_AGE_DIR/$(_dedup_key "$key")"
    # Backdate the file by 2 hours
    touch -t "$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M.%S)" "$key_file"
    run _stage_age_exceeded "$key" 3600
    [ "$status" -eq 0 ]
}

@test "_stage_age_exceeded: max_age=0 always exceeded on second call" {
    local key="loop.pr_review:myslug:zero"
    _stage_age_exceeded "$key" 0 || true  # first call: creates file
    run _stage_age_exceeded "$key" 0
    [ "$status" -eq 0 ]
}

@test "_stage_age_exceeded: different keys are tracked independently" {
    _stage_age_exceeded "loop.pr_review:slug:1" 3600 || true
    _stage_age_exceeded "loop.pr_review:slug:2" 3600 || true

    local kf1 kf2
    kf1="$STAGE_AGE_DIR/$(_dedup_key "loop.pr_review:slug:1")"
    kf2="$STAGE_AGE_DIR/$(_dedup_key "loop.pr_review:slug:2")"
    # Backdate only key 1
    touch -t "$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M.%S)" "$kf1"

    run _stage_age_exceeded "loop.pr_review:slug:1" 3600
    [ "$status" -eq 0 ]

    run _stage_age_exceeded "loop.pr_review:slug:2" 3600
    [ "$status" -eq 1 ]
}
