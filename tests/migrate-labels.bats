#!/usr/bin/env bats
# tests/migrate-labels.bats — unit tests for scripts/migrate-labels.sh.
#
# Stubs `gh` via a fake binary on PATH so no real GitHub calls are made.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export LOOP_ROOT="$REPO_ROOT"
    SCRIPT="$REPO_ROOT/scripts/migrate-labels.sh"

    cat > "$BATS_TMPDIR/projects.yaml" <<'YAML'
version: 1
projects:
  - slug: alpha
    name: Alpha
    repo: owner/alpha
    root: /tmp/fake
    default_branch: main
    workflow: default
YAML
    export LOOP_CONFIG="$BATS_TMPDIR/projects.yaml"

    # Fake gh binary: dispatches on first two args.
    BIN_DIR="$BATS_TMPDIR/bin"
    mkdir -p "$BIN_DIR"
    export GH_LOG="$BATS_TMPDIR/gh.log"
    rm -f "$GH_LOG"
    export GH_LABEL_LIST="${GH_LABEL_LIST:-}"
    export GH_ISSUE_NUMS="${GH_ISSUE_NUMS:-}"
    export GH_PR_NUMS="${GH_PR_NUMS:-}"

    cat > "$BIN_DIR/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "label list")
        # emit one name per line as `--jq '.[].name'` would
        printf '%s\n' $GH_LABEL_LIST
        ;;
  "issue list"|"pr list")
        if [ "$1" = "issue" ]; then nums="$GH_ISSUE_NUMS"; else nums="$GH_PR_NUMS"; fi
        # If invoked with `--jq length` (used by the script for re-check), emit a count.
        want_length=0
        for a in "$@"; do
            if [ "$a" = "length" ]; then want_length=1; break; fi
        done
        if [ $want_length -eq 1 ]; then
            count=0
            for n in $nums; do count=$((count + 1)); done
            printf '%s\n' "$count"
        else
            printf '['
            first=1
            for n in $nums; do
                if [ $first -eq 1 ]; then first=0; else printf ','; fi
                printf '{"number":%s}' "$n"
            done
            printf ']\n'
        fi
        ;;
  "issue edit"|"pr edit"|"label delete")
        : # success
        ;;
esac
exit 0
SH
    chmod +x "$BIN_DIR/gh"
    export PATH="$BIN_DIR:$PATH"
}

teardown() {
    rm -rf "$BATS_TMPDIR/bin" "$BATS_TMPDIR/projects.yaml" "$BATS_TMPDIR/gh.log"
}

@test "rejects invocation without --slug or --all" {
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--slug"* ]]
}

@test "dry-run: no deprecated labels present → zero changes" {
    export GH_LABEL_LIST="po-review dev review-pending ready-for-qa qa-pass qa-fail changes-requested"
    run bash "$SCRIPT" --slug alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"renamed=0 deleted=0"* ]]
    # No mutating gh calls.
    run grep -E "issue edit|pr edit|label delete" "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "dry-run: deprecated label with no open items → reports planned delete, no mutation" {
    export GH_LABEL_LIST="plan po-review dev"
    export GH_ISSUE_NUMS=""
    export GH_PR_NUMS=""
    run bash "$SCRIPT" --slug alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"delete label: plan"* ]]
    [[ "$output" == *"renamed=0 deleted=1"* ]]
    # dry-run must not actually call label delete
    run grep "label delete" "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "dry-run: deprecated label with open issues → reports planned renames, skips delete" {
    export GH_LABEL_LIST="needs-review review-pending"
    export GH_ISSUE_NUMS="42 43"
    export GH_PR_NUMS="100"
    run bash "$SCRIPT" --slug alpha
    [ "$status" -ne 0 ]   # nonzero because label could not be safely deleted
    [[ "$output" == *"rename #42: needs-review → review-pending"* ]]
    [[ "$output" == *"rename PR #100: needs-review → review-pending"* ]]
    [[ "$output" == *"renamed=3"* ]]
    [[ "$output" == *"[SKIP] label 'needs-review' still attached"* ]]
}

@test "apply: invokes gh label delete when label is unused" {
    export GH_LABEL_LIST="approved qa-pass"
    export GH_ISSUE_NUMS=""
    export GH_PR_NUMS=""
    run bash "$SCRIPT" --slug alpha --apply
    [ "$status" -eq 0 ]
    run grep "label delete approved" "$GH_LOG"
    [ "$status" -eq 0 ]
}

@test "unknown slug fails gracefully" {
    run bash "$SCRIPT" --slug nope
    [[ "$output" == *"slug 'nope' not found"* ]]
}

@test "summary line format matches spec" {
    export GH_LABEL_LIST="po-review dev"
    run bash "$SCRIPT" --slug alpha
    [ "$status" -eq 0 ]
    [[ "$output" =~ migrate-labels\ slug=alpha\ renamed=[0-9]+\ deleted=[0-9]+ ]]
}
