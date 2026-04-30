#!/usr/bin/env bats
# tests/dep_parser.bats — coverage for lib/dep_parser.py.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PYTHONPATH="$REPO_ROOT/lib"
}

# Helper: run dep_parser.extract on stdin body, optional self_num via $1.
parse() {
    local self="${1:-}"
    SELF="$self" python3 -c '
import os, sys
import dep_parser
self = os.environ.get("SELF") or None
if self:
    self = int(self)
print(",".join(str(n) for n in dep_parser.extract(sys.stdin.read(), self_num=self)))
'
}

@test "blocked by single ref" {
    run bash -c 'PYTHONPATH="'"$REPO_ROOT"'/lib" python3 -c "
import sys
sys.path.insert(0,\"'$REPO_ROOT'/lib\")
import dep_parser
print(\",\".join(str(n) for n in dep_parser.extract(\"blocked by #42\")))"'
    [ "$status" -eq 0 ]
    [ "$output" = "42" ]
}

@test "depends on / requires / waiting on / after" {
    run bash -c 'PYTHONPATH="'"$REPO_ROOT"'/lib" python3 -c "
import sys
sys.path.insert(0,\"'$REPO_ROOT'/lib\")
import dep_parser
body = \"depends on #5\nrequires #6\nwaiting on #7\nafter #8\"
print(\",\".join(str(n) for n in dep_parser.extract(body)))"'
    [ "$status" -eq 0 ]
    [ "$output" = "5,6,7,8" ]
}

@test "## Dependencies section refs picked up" {
    run bash -c 'PYTHONPATH="'"$REPO_ROOT"'/lib" python3 -c "
import sys
sys.path.insert(0,\"'$REPO_ROOT'/lib\")
import dep_parser
body = \"## Dependencies\n- #50\n- #51\n## Other\n- #99\"
print(\",\".join(str(n) for n in dep_parser.extract(body)))"'
    [ "$status" -eq 0 ]
    [ "$output" = "50,51" ]
}

@test "closes/fixes/resolves are NOT treated as blockers" {
    run bash -c 'PYTHONPATH="'"$REPO_ROOT"'/lib" python3 -c "
import sys
sys.path.insert(0,\"'$REPO_ROOT'/lib\")
import dep_parser
body = \"Closes #10\nfixes #11\nresolves #12\"
print(\",\".join(str(n) for n in dep_parser.extract(body)))"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "self-reference is filtered out" {
    run bash -c 'PYTHONPATH="'"$REPO_ROOT"'/lib" python3 -c "
import sys
sys.path.insert(0,\"'$REPO_ROOT'/lib\")
import dep_parser
body = \"blocked by #99 and depends on #42\"
print(\",\".join(str(n) for n in dep_parser.extract(body, self_num=99)))"'
    [ "$status" -eq 0 ]
    [ "$output" = "42" ]
}

@test "after that — common phrase, no false positive" {
    run bash -c 'PYTHONPATH="'"$REPO_ROOT"'/lib" python3 -c "
import sys
sys.path.insert(0,\"'$REPO_ROOT'/lib\")
import dep_parser
body = \"after that we ship; we go after the bug\"
print(\",\".join(str(n) for n in dep_parser.extract(body)))"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "mixed: closes excluded, blocked-by included" {
    run bash -c 'PYTHONPATH="'"$REPO_ROOT"'/lib" python3 -c "
import sys
sys.path.insert(0,\"'$REPO_ROOT'/lib\")
import dep_parser
body = \"Closes #100 — but blocked by #99\"
print(\",\".join(str(n) for n in dep_parser.extract(body)))"'
    [ "$status" -eq 0 ]
    [ "$output" = "99" ]
}

@test "empty body → empty result" {
    run bash -c 'PYTHONPATH="'"$REPO_ROOT"'/lib" python3 -c "
import sys
sys.path.insert(0,\"'$REPO_ROOT'/lib\")
import dep_parser
print(\",\".join(str(n) for n in dep_parser.extract(\"\")))"'
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}
