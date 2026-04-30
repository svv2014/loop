#!/usr/bin/env bats
# tests/dep_parser.bats — coverage for the shared dep parser source in
# lib/dep_parser.sh. Tests run the heredoc-inlined Python via the same
# DEP_PARSER_PY/exec pattern that lib/recovery.sh uses.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # shellcheck source=../lib/dep_parser.sh
    source "$REPO_ROOT/lib/dep_parser.sh"
}

# Run extract(BODY, self_num=SELF) and print comma-separated deps.
# $1 = body string, $2 = optional self_num.
parse() {
    BODY="$1" SELF="${2:-}" DEP_PARSER_PY="$_DEP_PARSER_PY" python3 - <<'PY'
import os
exec(os.environ['DEP_PARSER_PY'])
self_num = os.environ.get('SELF') or None
self_num = int(self_num) if self_num else None
print(",".join(str(n) for n in extract(os.environ['BODY'], self_num=self_num)))
PY
}

@test "blocked by single ref" {
    run parse "blocked by #42"
    [ "$status" -eq 0 ]
    [ "$output" = "42" ]
}

@test "depends on / requires / waiting on / after" {
    run parse $'depends on #5\nrequires #6\nwaiting on #7\nafter #8'
    [ "$status" -eq 0 ]
    [ "$output" = "5,6,7,8" ]
}

@test "## Dependencies section refs picked up" {
    run parse $'## Dependencies\n- #50\n- #51\n## Other\n- #99'
    [ "$status" -eq 0 ]
    [ "$output" = "50,51" ]
}

@test "closes/fixes/resolves are NOT treated as blockers" {
    run parse $'Closes #10\nfixes #11\nresolves #12'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "self-reference is filtered out" {
    run parse "blocked by #99 and depends on #42" "99"
    [ "$status" -eq 0 ]
    [ "$output" = "42" ]
}

@test "after that — common phrase, no false positive" {
    run parse "after that we ship; we go after the bug"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "mixed: closes excluded, blocked-by included" {
    run parse "Closes #100 — but blocked by #99"
    [ "$status" -eq 0 ]
    [ "$output" = "99" ]
}

@test "empty body → empty result" {
    run parse ""
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}
