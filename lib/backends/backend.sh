#!/usr/bin/env bash
# lib/backends/backend.sh — abstract backend interface for Loop.
#
# Sources the correct backend implementation (defaulting to 'github') based on
# the $BACKEND env var, which is exported by loop_load_project.
#
# Abstract interface — all backend implementations must provide:
#
#   backend_list_issues_with_label <repo> <label>
#     Emits priority-sorted open issues with the label, one JSON object per
#     line: {"number","title","url","labels":["..."]}
#
#   backend_list_prs_with_label <repo> <label>
#     Emits priority-sorted open PRs with the label, one JSON object per line:
#     {"number","title","url","headRefName","mergeable","labels":["..."]}
#     mergeable is an optional field; may be absent on non-GitHub backends.
#
#   backend_add_label <repo> <number> <label>
#     Adds a label to the issue or PR identified by <number>.
#
#   backend_remove_label <repo> <number> <label>
#     Removes a label from the issue or PR identified by <number>.
#
#   backend_issue_has_any_label <repo> <number> <label1> [label2 ...]
#     Returns 0 if the issue carries at least one of the listed labels, 1 otherwise.
#
#   backend_pr_has_any_label <repo> <number> <label1> [label2 ...]
#     Returns 0 if the PR carries at least one of the listed labels, 1 otherwise.
#
#   backend_issue_view <repo> <number> [extra_flags...]
#     Returns issue data. Extra flags (e.g. --json fields --jq expr) are
#     passed through to the underlying implementation.
#
#   backend_pr_view <repo> <number> [extra_flags...]
#     Returns PR data. Extra flags are passed through as with backend_issue_view.
#
#   backend_open_pr <repo> <title> <body_file> <label>
#     Opens a pull request. <body_file> is a path to a file containing the
#     PR body. Returns the PR URL on stdout.
#
#   backend_close_issue <repo> <number>
#     Closes the issue without adding a comment.
#
#   backend_close_pr <repo> <number> [--delete-branch]
#     Closes the PR. Optionally deletes the head branch.
#
#   backend_comment_issue <repo> <number> <body>
#     Posts <body> as a comment on the issue.
#
#   backend_comment_pr <repo> <number> <body>
#     Posts <body> as a comment on the PR.
#
#   backend_merge_pr <repo> <number> <strategy_flag>
#     Merges the PR. <strategy_flag> is one of --squash, --merge, --rebase.
#
# Extended interface — additional helpers used by scanner/reconciler:
#
#   backend_list_open_prs_raw <repo>
#     Returns a raw JSON array of all open PRs with fields:
#     number, body, createdAt, headRefName, title, labels, updatedAt
#
#   backend_list_merged_prs_raw <repo>
#     Returns a raw JSON array of recently merged PRs with fields:
#     number, body
#
#   backend_list_open_issues_raw <repo> <label>
#     Returns a raw JSON array of open issues with the given label, with fields:
#     number, title, labels, body, updatedAt
#
#   backend_issue_unmet_deps <repo> <number>
#     Print each unmet dependency (#NNN) declared in the issue's "## Dependencies"
#     section, one per line. Empty output = all deps met or none declared.

set -euo pipefail

_LOOP_BACKENDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LOOP_BACKEND_LOADED=""

# loop_load_backend — (re-)load the implementation for $BACKEND.
# Called automatically when this file is sourced, and should be called again
# after loop_load_project in any script that may process multiple projects
# with different backends.
loop_load_backend() {
    local backend="${BACKEND:-github}"
    if [ "$_LOOP_BACKEND_LOADED" = "$backend" ]; then
        return 0
    fi
    local impl="${_LOOP_BACKENDS_DIR}/${backend}.sh"
    if [ ! -f "$impl" ]; then
        echo "loop_load_backend: no implementation for backend '${backend}' at ${impl}" >&2
        return 1
    fi
    # shellcheck disable=SC1090
    source "$impl"
    _LOOP_BACKEND_LOADED="$backend"
}

# Auto-load with default (or already-exported) backend when sourced.
loop_load_backend

# (declare this alongside the other backend_* interface functions)
backend_issue_unmet_deps() { echo "backend_issue_unmet_deps not implemented" >&2; return 1; }

# backend_cli_note — emit a CLI reference block for agent prompts.
# On gitlab/jira-gitlab backends, prints a glab/gh equivalence table so
# the agent knows to use glab instead of gh. Prints nothing on github.
backend_cli_note() {
    case "${BACKEND:-github}" in
        gitlab|jira-gitlab) cat <<'CLINOTE'

BACKEND NOTICE: This project uses GitLab. Use glab commands instead of gh:
  gh issue view N --repo R --json body --jq .body
    → glab issue view N --repo R --output json | python3 -c "import json,sys; print(json.load(sys.stdin).get('description',''))"
  gh issue list --repo R --state all --limit 50
    → glab issue list --repo R --state all --limit 50
  gh issue edit N --repo R --add-label L --remove-label M
    → glab issue update N --repo R --add-label L --remove-label M
  gh issue comment N --repo R --body 'text'
    → glab issue comment N --repo R --body 'text'
  gh issue close N --repo R
    → glab issue close N --repo R
  gh issue create --repo R --title T --body B --label L
    → glab issue create --repo R --title T --description B --label L
  gh pr create --repo R --title T --body B --label L
    → glab mr create --repo R --title T --description B --label L
  gh pr view N --repo R --json state,merged
    → glab mr view N --repo R --output json
  gh pr diff N --repo R
    → glab mr diff N --repo R
  gh pr checks N --repo R
    → glab pipeline list --source-branch BRANCH --repo R
  gh pr review N --repo R --approve --body 'text'
    → glab mr approve N --repo R  (post review body as a separate comment)
  gh pr review N --repo R --request-changes --body 'text'
    → glab mr revoke N --repo R  (post review body as a separate comment)
  gh pr edit N --repo R --add-label L --remove-label M
    → glab mr update N --repo R --add-label L --remove-label M
  gh pr comment N --repo R --body 'text'
    → glab mr comment N --repo R --body 'text'
CLINOTE
        ;;
    esac
}
