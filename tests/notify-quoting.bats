#!/usr/bin/env bats
# tests/notify-quoting.bats — coverage for loop_notify shell-quoting fix.
# Regression for the "syntax error near unexpected token '('" bug observed
# 2026-05-01 when anomaly + agent-distress alerts contained parens.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export RECEIVED="$BATS_TMPDIR/received-$$.log"
    rm -f "$RECEIVED"

    # Stub script: writes its argv to RECEIVED, one arg per line.
    STUB="$BATS_TMPDIR/stub-notifier-$$.sh"
    cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    echo "$a" >> "$RECEIVED"
done
exit 0
STUB
    chmod +x "$STUB"
    export STUB

    # shellcheck source=../lib/notify.sh
    source "$REPO_ROOT/lib/notify.sh"
}

teardown() {
    rm -f "$RECEIVED" "$STUB"
    unset LOOP_NOTIFY
}

@test "no LOOP_NOTIFY: silent no-op" {
    unset LOOP_NOTIFY
    run loop_notify "anything"
    [ "$status" -eq 0 ]
    [ ! -f "$RECEIVED" ]
}

@test "plain message: passes through unchanged" {
    export LOOP_NOTIFY="$STUB --channel=ops"
    run loop_notify "hello world"
    [ "$status" -eq 0 ]
    grep -qx -- "--channel=ops" "$RECEIVED"
    grep -qx -- "hello world" "$RECEIVED"
}

@test "parens in message: NO syntax error (regression for #pre-existing notify bug)" {
    export LOOP_NOTIFY="$STUB --channel=ops"
    run loop_notify "PR#441 stale 44h in (needs-qa): refresh SVG"
    [ "$status" -eq 0 ]
    # The whole message must arrive as ONE argv item, not split or
    # mis-parsed by the shell.
    grep -qxF "PR#441 stale 44h in (needs-qa): refresh SVG" "$RECEIVED"
}

@test "backticks in message: NO command substitution" {
    export LOOP_NOTIFY="$STUB --channel=ops"
    run loop_notify 'this has \`backticks\` and should not run anything'
    [ "$status" -eq 0 ]
    grep -qF '\`backticks\`' "$RECEIVED"
}

@test "dollar paren in message: NO command substitution" {
    export LOOP_NOTIFY="$STUB --channel=ops"
    run loop_notify 'this has $(date) and should not run anything'
    [ "$status" -eq 0 ]
    # Must contain the literal string, not the expanded date.
    grep -qF '$(date)' "$RECEIVED"
}

@test "ampersand and semicolon in message: NO command chaining" {
    export LOOP_NOTIFY="$STUB --channel=ops"
    # Semicolons / ampersands previously could terminate the eval'd command.
    run loop_notify "alert: a && b ; c | d"
    [ "$status" -eq 0 ]
    grep -qxF "alert: a && b ; c | d" "$RECEIVED"
}

@test "multiple flags in LOOP_NOTIFY: each lands as its own argv" {
    export LOOP_NOTIFY="$STUB --channel=ops --priority=high --tag=loop"
    run loop_notify "msg"
    [ "$status" -eq 0 ]
    grep -qx -- "--channel=ops"   "$RECEIVED"
    grep -qx -- "--priority=high" "$RECEIVED"
    grep -qx -- "--tag=loop"      "$RECEIVED"
    grep -qx -- "msg"             "$RECEIVED"
}

@test "notifier failure is non-fatal" {
    # A notifier that exits non-zero must not abort the caller.
    BAD_STUB="$BATS_TMPDIR/bad-stub-$$.sh"
    cat > "$BAD_STUB" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$BAD_STUB"
    export LOOP_NOTIFY="$BAD_STUB"

    run loop_notify "anything"
    [ "$status" -eq 0 ]   # we got 0 from loop_notify even though the stub exit'd 1

    rm -f "$BAD_STUB"
}
