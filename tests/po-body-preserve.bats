#!/usr/bin/env bats
# tests/po-body-preserve.bats — unit tests for _ORIGINAL_BRIEF extraction logic.
#
# Tests that the python3 snippet in po-handler.sh correctly strips any existing
# ## Original brief section from the captured issue body so re-triage never
# nests the marker.

# Inline replication of the python3 extraction snippet from po-handler.sh.
extract_original_brief() {
    local body="$1"
    BODY="$body" python3 -c "
import os, re
body = os.environ.get('BODY', '').strip()
# Strip existing marker and everything after it
body = re.split(r'(?m)^---\s*\n##\s+Original brief', body)[0].rstrip()
print(body)
"
}

@test "strips existing ## Original brief marker and everything after it" {
    local input
    input="$(printf 'do X\n\n---\n\n## Original brief (preserved by PO)\n\nold original')"
    result=$(extract_original_brief "$input")
    [ "$result" = "do X" ]
}

@test "returns body unchanged when no marker is present" {
    result=$(extract_original_brief "do X")
    [ "$result" = "do X" ]
}

@test "returns empty string for an empty body" {
    result=$(extract_original_brief "")
    [ -z "$result" ]
}

@test "returns empty string for a whitespace-only body" {
    result=$(extract_original_brief "   ")
    [ -z "$result" ]
}

@test "strips marker even when body has multiple paragraphs before it" {
    local input
    input="$(printf 'line one\n\nline two\n\n---\n\n## Original brief (preserved by PO)\n\nsome old brief')"
    result=$(extract_original_brief "$input")
    [ "$result" = "$(printf 'line one\n\nline two')" ]
}
