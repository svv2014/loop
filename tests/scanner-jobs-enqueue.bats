#!/usr/bin/env bats
# tests/scanner-jobs-enqueue.bats — scanner dual-write to jobs table.
#
# Seeds two issues with claimable labels, runs one scanner pass, and asserts
# two pending rows exist. A second pass asserts the count is unchanged (dedup).
# Also tests LOOP_JOBS_ENQUEUE=0 and --dry-run guards.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

    if ! command -v sqlite3 >/dev/null 2>&1; then
        skip "sqlite3 not available"
    fi

    mkdir -p "$BATS_TMPDIR/bin"
    ln -sf "$BATS_TEST_DIRNAME/test_helper/mock-gh.sh" "$BATS_TMPDIR/bin/gh"
    chmod +x "$BATS_TMPDIR/bin/gh"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    export LOOP_LOG_DIR="$BATS_TMPDIR/logs"
    mkdir -p "$LOOP_LOG_DIR"

    export LOOP_JOBS_DB="$BATS_TMPDIR/jobs-enqueue-$$.db"
    export LOOP_JOBS_ENQUEUE=1

    unset GH_MOCK_OUTPUT GH_MOCK_EXIT GH_MOCK_LOG

    export LOOP_EXTRA_PATH=""
    local _src="$BATS_TMPDIR/scanner-src-enqueue.sh"
    {
        printf "LOOP_ROOT='%s'\n" "$REPO_ROOT"
        awk '
            /^SCRIPT_DIR=/           { next }
            /^LOOP_ROOT=/            { next }
            /^for arg in "\$@"; do$/ { skip=1; print "DRY_RUN=false"; print "ONCE=false"; next }
            skip && /^done$/         { skip=0; next }
            skip                     { next }
            /^acquire_lock$/         { exit }
            { print }
        ' "$REPO_ROOT/scanner/scanner.sh"
    } > "$_src"
    # shellcheck disable=SC1090
    source "$_src"
    export PATH="$BATS_TMPDIR/bin:$PATH"

    DEDUP_DIR="$BATS_TMPDIR/dedup-enqueue"
    LOG_FILE="$BATS_TMPDIR/scanner-enqueue-test.log"
    mkdir -p "$DEDUP_DIR"

    DRY_RUN=false
    LOOP_DISPATCH_MODE=direct
    BOBA_EVENT_CLIENT=""

    log() { :; }
    dispatch_direct() { :; }

    jobs_init_schema
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/dedup-enqueue" \
           "$BATS_TMPDIR/logs" "$BATS_TMPDIR/scanner-enqueue-test.log" \
           "$BATS_TMPDIR/scanner-src-enqueue.sh" \
           "$LOOP_JOBS_DB" 2>/dev/null || true
    unset LOOP_JOBS_DB LOOP_JOBS_ENQUEUE
}

_write_enqueue_fixture() {
    cat > "$BATS_TMPDIR/enqueue-fixture.yaml" <<'YAML'
version: 1
projects:
  - slug: proj-enqueue
    name: Enqueue Test Project
    repo: owner/enqueue-repo
    root: /tmp/fake-enqueue
    default_branch: main
    workflow: default
    dev:
      commit_prefix: ENQ
      max_concurrent_prs: 3
YAML
}

# ---------------------------------------------------------------------------
# Two pending rows after one pass
# ---------------------------------------------------------------------------

@test "scanner enqueues two pending rows for two issues with claimable labels" {
    _write_enqueue_fixture
    export LOOP_CONFIG="$BATS_TMPDIR/enqueue-fixture.yaml"

    local ISSUE1 ISSUE2
    ISSUE1='{"number":101,"title":"Issue one","url":"http://gh/101","labels":["needs-dev"],"author":"bot"}'
    ISSUE2='{"number":102,"title":"Issue two","url":"http://gh/102","labels":["needs-dev"],"author":"bot"}'

    backend_list_issues_with_label() {
        local _label="$2"
        if [ "$_label" = "needs-dev" ]; then
            printf '%s\n' "$ISSUE1"
            printf '%s\n' "$ISSUE2"
        fi
        return 0
    }
    backend_list_prs_with_label()  { return 0; }
    backend_list_open_prs_raw()    { echo "[]"; }
    backend_issue_has_any_label()  { return 1; }
    backend_pr_has_any_label()     { return 1; }
    backend_issue_unmet_deps()     { return 1; }
    loop_load_backend()            { return 0; }
    loop_load_project() {
        REPO="owner/enqueue-repo"
        MAX_CONCURRENT_PRS=3
        BACKEND=github
        WORKFLOW=default
        ALLOWED_AUTHORS=""
        LOOP_LABEL_OVERRIDES=""
        return 0
    }
    emit() { return 0; }

    scan_project "proj-enqueue"

    local count
    count=$(sqlite3 "$LOOP_JOBS_DB" \
        "SELECT COUNT(*) FROM jobs WHERE project='proj-enqueue' AND status='pending';")
    [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Second pass — row count unchanged (dedup via partial unique index)
# ---------------------------------------------------------------------------

@test "second scanner pass does not create duplicate pending rows" {
    _write_enqueue_fixture
    export LOOP_CONFIG="$BATS_TMPDIR/enqueue-fixture.yaml"

    local ISSUE1 ISSUE2
    ISSUE1='{"number":201,"title":"Issue one","url":"http://gh/201","labels":["needs-dev"],"author":"bot"}'
    ISSUE2='{"number":202,"title":"Issue two","url":"http://gh/202","labels":["needs-dev"],"author":"bot"}'

    backend_list_issues_with_label() {
        local _label="$2"
        if [ "$_label" = "needs-dev" ]; then
            printf '%s\n' "$ISSUE1"
            printf '%s\n' "$ISSUE2"
        fi
        return 0
    }
    backend_list_prs_with_label()  { return 0; }
    backend_list_open_prs_raw()    { echo "[]"; }
    backend_issue_has_any_label()  { return 1; }
    backend_pr_has_any_label()     { return 1; }
    backend_issue_unmet_deps()     { return 1; }
    loop_load_backend()            { return 0; }
    loop_load_project() {
        REPO="owner/enqueue-repo"
        MAX_CONCURRENT_PRS=3
        BACKEND=github
        WORKFLOW=default
        ALLOWED_AUTHORS=""
        LOOP_LABEL_OVERRIDES=""
        return 0
    }
    emit() { return 0; }

    scan_project "proj-enqueue"

    local count_first
    count_first=$(sqlite3 "$LOOP_JOBS_DB" \
        "SELECT COUNT(*) FROM jobs WHERE project='proj-enqueue' AND status='pending';")
    [ "$count_first" -eq 2 ]

    scan_project "proj-enqueue"

    local count_second
    count_second=$(sqlite3 "$LOOP_JOBS_DB" \
        "SELECT COUNT(*) FROM jobs WHERE project='proj-enqueue' AND status='pending';")
    [ "$count_second" -eq 2 ]
}

# ---------------------------------------------------------------------------
# LOOP_JOBS_ENQUEUE=0 gate
# ---------------------------------------------------------------------------

@test "LOOP_JOBS_ENQUEUE=0 disables enqueue — no rows written" {
    _write_enqueue_fixture
    export LOOP_CONFIG="$BATS_TMPDIR/enqueue-fixture.yaml"
    export LOOP_JOBS_ENQUEUE=0

    local ISSUE1
    ISSUE1='{"number":301,"title":"Issue one","url":"http://gh/301","labels":["needs-dev"],"author":"bot"}'

    backend_list_issues_with_label() {
        local _label="$2"
        [ "$_label" = "needs-dev" ] && printf '%s\n' "$ISSUE1"
        return 0
    }
    backend_list_prs_with_label()  { return 0; }
    backend_list_open_prs_raw()    { echo "[]"; }
    backend_issue_has_any_label()  { return 1; }
    backend_pr_has_any_label()     { return 1; }
    backend_issue_unmet_deps()     { return 1; }
    loop_load_backend()            { return 0; }
    loop_load_project() {
        REPO="owner/enqueue-repo"
        MAX_CONCURRENT_PRS=3
        BACKEND=github
        WORKFLOW=default
        ALLOWED_AUTHORS=""
        LOOP_LABEL_OVERRIDES=""
        return 0
    }
    emit() { return 0; }

    scan_project "proj-enqueue"

    local count
    count=$(sqlite3 "$LOOP_JOBS_DB" \
        "SELECT COUNT(*) FROM jobs WHERE project='proj-enqueue';")
    [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# DRY_RUN guard
# ---------------------------------------------------------------------------

@test "DRY_RUN=true does not write to jobs DB" {
    _write_enqueue_fixture
    export LOOP_CONFIG="$BATS_TMPDIR/enqueue-fixture.yaml"
    DRY_RUN=true

    local ISSUE1
    ISSUE1='{"number":401,"title":"Issue one","url":"http://gh/401","labels":["needs-dev"],"author":"bot"}'

    backend_list_issues_with_label() {
        local _label="$2"
        [ "$_label" = "needs-dev" ] && printf '%s\n' "$ISSUE1"
        return 0
    }
    backend_list_prs_with_label()  { return 0; }
    backend_list_open_prs_raw()    { echo "[]"; }
    backend_issue_has_any_label()  { return 1; }
    backend_pr_has_any_label()     { return 1; }
    backend_issue_unmet_deps()     { return 1; }
    loop_load_backend()            { return 0; }
    loop_load_project() {
        REPO="owner/enqueue-repo"
        MAX_CONCURRENT_PRS=3
        BACKEND=github
        WORKFLOW=default
        ALLOWED_AUTHORS=""
        LOOP_LABEL_OVERRIDES=""
        return 0
    }

    scan_project "proj-enqueue"

    local count
    count=$(sqlite3 "$LOOP_JOBS_DB" \
        "SELECT COUNT(*) FROM jobs WHERE project='proj-enqueue';")
    [ "$count" -eq 0 ]
}
