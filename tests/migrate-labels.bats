#!/usr/bin/env bats
# tests/migrate-labels.bats — unit tests for scripts/migrate-labels.sh.
#
# Stubs `gh` via a fake binary on PATH so no real GitHub calls are made.
# Deprecated→canonical pairs come from lib/labels.sh.

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
        printf '%s\n' $GH_LABEL_LIST
        ;;
  "issue list"|"pr list")
        if [ "$1" = "issue" ]; then nums="$GH_ISSUE_NUMS"; else nums="$GH_PR_NUMS"; fi
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

@test "no deprecated labels present → zero changes, zero summary, exit 0" {
    export GH_LABEL_LIST="needs-po needs-dev needs-review needs-qa qa-pass qa-fail blocked done"
    run bash "$SCRIPT" --slug alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"renamed=0 deleted=0"* ]]
    run grep -E "issue edit|pr edit|label delete" "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "dry-run: deprecated label with no open items → planned delete, no mutation" {
    export GH_LABEL_LIST="plan needs-po needs-dev"
    export GH_ISSUE_NUMS=""
    export GH_PR_NUMS=""
    run bash "$SCRIPT" --slug alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"delete label: plan"* ]]
    [[ "$output" == *"renamed=0 deleted=1"* ]]
    run grep "label delete" "$GH_LOG"
    [ "$status" -ne 0 ]
}

@test "dry-run: deprecated label with open items → planned renames, skips delete" {
    export GH_LABEL_LIST="in-progress needs-dev"
    export GH_ISSUE_NUMS="42 43"
    export GH_PR_NUMS="100"
    run bash "$SCRIPT" --slug alpha
    [ "$status" -ne 0 ]
    [[ "$output" == *"rename #42: in-progress → needs-dev"* ]]
    [[ "$output" == *"rename PR #100: in-progress → needs-dev"* ]]
    [[ "$output" == *"renamed=3"* ]]
    [[ "$output" == *"[SKIP] label 'in-progress' still attached"* ]]
}

@test "apply: invokes gh label delete when label is unused" {
    export GH_LABEL_LIST="po-review needs-po"
    export GH_ISSUE_NUMS=""
    export GH_PR_NUMS=""
    run bash "$SCRIPT" --slug alpha --apply
    [ "$status" -eq 0 ]
    run grep "label delete po-review" "$GH_LOG"
    [ "$status" -eq 0 ]
}

@test "unknown slug fails gracefully" {
    run bash "$SCRIPT" --slug nope
    [[ "$output" == *"slug 'nope' not found"* ]]
    [ "$status" -ne 0 ]
}

@test "summary line format matches spec" {
    export GH_LABEL_LIST="needs-po needs-dev"
    run bash "$SCRIPT" --slug alpha
    [ "$status" -eq 0 ]
    [[ "$output" =~ migrate-labels\ slug=alpha\ renamed=[0-9]+\ deleted=[0-9]+ ]]
}

@test "idempotent: a second run after migration produces zero changes" {
    export GH_LABEL_LIST="needs-po needs-dev needs-review needs-qa qa-pass qa-fail blocked done"
    run bash "$SCRIPT" --slug alpha --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"renamed=0 deleted=0"* ]]
}
