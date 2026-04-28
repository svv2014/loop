#!/usr/bin/env bash
# lib/backends/jira-gitlab.sh — Jira+GitLab composite backend.
#
# Ticket state (issues, labels/transitions) → Jira REST API v3.
# Code and MR operations → GitLab adapter (lib/backends/gitlab.sh).
#
# Strategy: source gitlab.sh first so all backend_* MR functions are defined,
# then override only the issue/ticket functions with Jira implementations.
#
# Required env vars (set in loop.env):
#   JIRA_URL    — e.g. https://yourorg.atlassian.net  (no trailing slash)
#   JIRA_USER   — Atlassian account email
#   JIRA_TOKEN  — Atlassian API token
#
# Per-project env vars (set in loop.env or from backend_config loader):
#   JIRA_TICKET_PROJECT    — Jira project key, e.g. PROJ
#
# Optional env vars:
#   JIRA_BLOCKED_STATUS    — Jira status name for escape-hatch states (default: Blocked)
#
# Transition map overrides (all optional; values are Jira transition names):
#   LOOP_JIRA_STATE_DEV, LOOP_JIRA_STATE_IN_PROGRESS
#   LOOP_JIRA_STATE_REVIEW_PENDING, LOOP_JIRA_STATE_IN_REVIEW
#   LOOP_JIRA_STATE_READY_FOR_QA, LOOP_JIRA_STATE_QA_PASS
#   LOOP_JIRA_STATE_QA_FAIL, LOOP_JIRA_STATE_DONE

set -euo pipefail

# Guard against double-sourcing.
[ -n "${_LOOP_BACKEND_JIRA_GITLAB_LOADED:-}" ] && return 0
_LOOP_BACKEND_JIRA_GITLAB_LOADED=1

_JG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source GitLab adapter — provides all MR/PR backend_* functions.
# shellcheck source=gitlab.sh
source "${_JG_DIR}/gitlab.sh"

# ---------------------------------------------------------------------------
# Jira REST helpers
# ---------------------------------------------------------------------------

_jira_api() {
    local method="$1" path="$2"
    shift 2
    curl -s -X "$method" \
        -u "${JIRA_USER}:${JIRA_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        "${JIRA_URL}${path}" "$@"
}

# _jira_get_transitions_json <key>
# Returns the raw JSON from the transitions endpoint.
_jira_get_transitions_json() {
    local key="$1"
    _jira_api GET "/rest/api/3/issue/${key}/transitions"
}

# _jira_find_transition_id <transitions_json> <name>
# Looks up a transition ID by name (case-insensitive). Prints id or returns 1.
_jira_find_transition_id() {
    local json="$1" name="$2"
    local tid
    tid=$(echo "$json" | jq -r --arg n "$name" \
        '.transitions[]? | select(.name | ascii_downcase == ($n | ascii_downcase)) | .id' \
        2>/dev/null | head -1)
    [ -n "$tid" ] || return 1
    echo "$tid"
}

# _jira_transition <key> <transition_name>
# Transitions the Jira issue. Returns 1 if the transition is unavailable.
_jira_transition() {
    local key="$1" name="$2"
    local tdata tid
    tdata=$(_jira_get_transitions_json "$key") || return 1
    tid=$(_jira_find_transition_id "$tdata" "$name") || return 1
    _jira_api POST "/rest/api/3/issue/${key}/transitions" \
        -d "{\"transition\":{\"id\":\"${tid}\"}}" >/dev/null
}

# _jira_add_comment <key> <text>
_jira_add_comment() {
    local key="$1" text="$2"
    # Build ADF (Atlassian Document Format) body via python3 to avoid jq escaping issues.
    local payload
    payload=$(python3 -c "
import json, sys
text = sys.argv[1]
print(json.dumps({
    'body': {
        'type': 'doc', 'version': 1,
        'content': [{'type': 'paragraph',
                     'content': [{'type': 'text', 'text': text}]}]
    }
}))" "$text")
    _jira_api POST "/rest/api/3/issue/${key}/comment" -d "$payload" >/dev/null
}

# _jira_get_status <key>
# Prints the current Jira status name.
_jira_get_status() {
    local key="$1"
    _jira_api GET "/rest/api/3/issue/${key}?fields=status" \
        | jq -r '.fields.status.name' 2>/dev/null
}

# _jira_transition_or_comment <key> <status_name> <fallback_marker>
# Tries to transition; on failure posts a comment with the fallback marker.
_jira_transition_or_comment() {
    local key="$1" status="$2" marker="$3"
    if ! _jira_transition "$key" "$status" 2>/dev/null; then
        _jira_add_comment "$key" "Loop: ${marker}" 2>/dev/null || true
    fi
}

# _state_to_jira_transition <loop_label>
# Returns the Jira transition name for the given Loop canonical label.
# Operator overrides via LOOP_JIRA_STATE_* env vars.
_state_to_jira_transition() {
    case "$1" in
        dev)                  echo "${LOOP_JIRA_STATE_DEV:-In Progress}" ;;
        in-progress)          echo "${LOOP_JIRA_STATE_IN_PROGRESS:-In Progress}" ;;
        review-pending)       echo "${LOOP_JIRA_STATE_REVIEW_PENDING:-In Review}" ;;
        in-review)            echo "${LOOP_JIRA_STATE_IN_REVIEW:-In Review}" ;;
        ready-for-qa)         echo "${LOOP_JIRA_STATE_READY_FOR_QA:-QA}" ;;
        qa-pass)              echo "${LOOP_JIRA_STATE_QA_PASS:-QA}" ;;
        qa-fail)              echo "${LOOP_JIRA_STATE_QA_FAIL:-In Progress}" ;;
        done)                 echo "${LOOP_JIRA_STATE_DONE:-Done}" ;;
        needs-clarification|changes-requested|blocked)
                              echo "${JIRA_BLOCKED_STATUS:-Blocked}" ;;
        *)                    echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# Issue/ticket interface (overrides GitLab stubs)
# ---------------------------------------------------------------------------

# backend_add_label <repo> <key> <label>
# Maps Loop label additions to Jira status transitions.
# <key> is the Jira issue key, e.g. PROJ-42.
backend_add_label() {
    local _repo="$1" key="$2" label="$3"
    local transition
    transition=$(_state_to_jira_transition "$label")
    [ -z "$transition" ] && return 0

    case "$label" in
        needs-clarification|changes-requested|blocked)
            _jira_transition_or_comment "$key" "$transition" "state=${label}" \
                2>/dev/null || true
            ;;
        *)
            _jira_transition "$key" "$transition" 2>/dev/null || true
            ;;
    esac
}

# backend_remove_label <repo> <key> <label>
# Removing a label has no direct Jira equivalent — no-op.
backend_remove_label() {
    return 0
}

# backend_issue_has_any_label <repo> <key> <label1> [label2 ...]
# Checks whether the current Jira status matches any of the given Loop labels.
backend_issue_has_any_label() {
    local _repo="$1" key="$2"
    shift 2
    local current_status
    current_status=$(_jira_get_status "$key" 2>/dev/null) || return 1
    local current_lc="${current_status,,}"
    local want transition
    for want in "$@"; do
        transition=$(_state_to_jira_transition "$want")
        if [ "${current_lc}" = "${transition,,}" ] \
                || [ "${current_lc}" = "${want,,}" ]; then
            return 0
        fi
    done
    return 1
}

# backend_issue_view <repo> <key> [extra_flags...]
# Returns Jira issue data. Extra flags are accepted but not forwarded (Jira has
# no CLI pass-through); the Jira REST JSON is returned directly.
backend_issue_view() {
    local _repo="$1" key="$2"
    # extra_flags intentionally ignored — no Jira CLI to forward to
    _jira_api GET "/rest/api/3/issue/${key}?fields=summary,status,description" \
        2>/dev/null || true
}

# backend_list_issues_with_label <repo> <label>
# Lists Jira issues whose status matches the given Loop label via JQL.
# Uses JIRA_TICKET_PROJECT env var for the project scope.
backend_list_issues_with_label() {
    local _repo="$1" label="$2"
    local project="${JIRA_TICKET_PROJECT:-}"
    local transition
    transition=$(_state_to_jira_transition "$label")

    if [ -z "$transition" ]; then
        return 0
    fi
    if [ -z "$project" ]; then
        echo "backend_list_issues_with_label: JIRA_TICKET_PROJECT not set" >&2
        return 1
    fi

    local encoded_jql
    encoded_jql=$(python3 -c "
import urllib.parse, sys
project, status = sys.argv[1], sys.argv[2]
jql = 'project = \"{}\" AND status = \"{}\" ORDER BY priority ASC, created ASC'.format(project, status)
print(urllib.parse.quote(jql))
" "$project" "$transition")

    _jira_api GET "/rest/api/3/search?jql=${encoded_jql}&fields=summary,status,priority" \
        2>/dev/null \
        | jq -r --arg base "${JIRA_URL}" '
            .issues[]? |
            {
              number: .key,
              title:  .fields.summary,
              url:    ($base + "/browse/" + .key),
              labels: [.fields.status.name]
            } | @json' 2>/dev/null || true
}

# backend_comment_issue <repo> <key> <body>
backend_comment_issue() {
    local _repo="$1" key="$2" body="$3"
    _jira_add_comment "$key" "$body" 2>/dev/null || true
}

# backend_close_issue <repo> <key>
# Transitions the Jira issue to the configured "done" status.
backend_close_issue() {
    local _repo="$1" key="$2"
    local done_status="${LOOP_JIRA_STATE_DONE:-Done}"
    _jira_transition "$key" "$done_status" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Extended interface — bulk operations used by scanner/reconciler
# ---------------------------------------------------------------------------

# backend_list_open_issues_raw <repo> <label>
# Returns a JSON array of open Jira issues with the given Loop label.
backend_list_open_issues_raw() {
    local _repo="$1" label="$2"
    local project="${JIRA_TICKET_PROJECT:-}"
    local transition
    transition=$(_state_to_jira_transition "$label")

    if [ -z "$transition" ] || [ -z "$project" ]; then
        echo "[]"
        return 0
    fi

    local encoded_jql
    encoded_jql=$(python3 -c "
import urllib.parse, sys
project, status = sys.argv[1], sys.argv[2]
jql = 'project = \"{}\" AND status = \"{}\" ORDER BY priority ASC, created ASC'.format(project, status)
print(urllib.parse.quote(jql))
" "$project" "$transition")

    _jira_api GET "/rest/api/3/search?jql=${encoded_jql}&fields=summary,status,description,updated&maxResults=100" \
        2>/dev/null \
        | jq '[
            .issues[]? |
            {
              number:    .key,
              title:     .fields.summary,
              labels:    [.fields.status.name],
              body:      (.fields.description // "" | if type == "object" then "" else . end),
              updatedAt: .fields.updated
            }
          ]' 2>/dev/null || echo "[]"
}

# backend_list_open_prs_raw and backend_list_merged_prs_raw are inherited from gitlab.sh.

# backend_find_pr_for_issue <repo> <issue_num>
# Jira issues use project-scoped keys (e.g. PROJ-42), not numeric GitHub/GitLab
# references, so MR description search is not reliable. Return empty; exits 0.
backend_find_pr_for_issue() {
    return 0
}
