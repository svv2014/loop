#!/usr/bin/env bash
# lib/cli-hint.sh — backend-aware CLI hint for agent prompts.
#
# Outputs nothing for the github backend (the default).
# When BACKEND=gitlab, prints a glab equivalents table so the agent
# knows which commands to use instead of gh.

set -euo pipefail

# loop_cli_hint — call inside a prompt heredoc via $(loop_cli_hint).
loop_cli_hint() {
    [ "${BACKEND:-github}" = "gitlab" ] || return 0
    cat <<'HINT'

## GitLab CLI reference (BACKEND=gitlab — use glab instead of gh)

This project uses a GitLab backend. Replace every `gh` command in the steps
below with the `glab` equivalent shown in the tables.

### Issues

| gh command                                              | glab equivalent                                              |
|---------------------------------------------------------|--------------------------------------------------------------|
| gh issue list --repo R --state all --limit N            | glab issue list --repo R --state all --per-page N            |
| gh issue view N --repo R --json body,labels             | glab issue view N --repo R --output json                     |
| gh issue edit N --repo R --add-label L                  | glab issue edit N --repo R --label L                         |
| gh issue edit N --repo R --remove-label L               | glab issue edit N --repo R --unlabel L                       |
| gh issue edit N --repo R --body-file FILE               | glab issue update N --repo R --description "$(cat FILE)"     |
| gh issue comment N --repo R --body 'TEXT'               | glab issue note N --repo R --message 'TEXT'                  |
| gh issue close N --repo R                               | glab issue close N --repo R                                  |
| gh issue view N --repo R --json labels,state            | glab issue view N --repo R --output json                     |

### Merge Requests (gh pr → glab mr)

| gh command                                              | glab equivalent                                              |
|---------------------------------------------------------|--------------------------------------------------------------|
| gh pr create --repo R --title T --body B --label L      | glab mr create --repo R --title T --description B --label L  |
| gh pr view N --repo R --json state,merged               | glab mr view N --repo R --output json                        |
| gh pr view N --repo R --json title,body,headRefName,... | glab mr view N --repo R --output json                        |
| gh pr view N --repo R --json body,reviews,comments,...  | glab mr view N --repo R --output json                        |
| gh pr view N --repo R --json labels                     | glab mr view N --repo R --output json                        |
| gh pr diff N --repo R                                   | glab mr diff N --repo R                                      |
| gh pr checks N --repo R                                 | glab ci status --repo R (pipeline for the MR branch)         |
| gh pr edit N --repo R --add-label L                     | glab mr update N --repo R --label L                          |
| gh pr edit N --repo R --remove-label L                  | glab mr update N --repo R --unlabel L                        |
| gh pr comment N --repo R --body 'TEXT'                  | glab mr note N --repo R --message 'TEXT'                     |
| gh pr comment N --repo R --body-file FILE               | glab mr note N --repo R --message "$(cat FILE)"              |
| gh pr review N --repo R --approve --body 'TEXT'         | glab mr approve N --repo R && glab mr note N --repo R --message 'TEXT' |
| gh pr review N --repo R --request-changes --body 'TEXT' | glab mr revoke N --repo R && glab mr note N --repo R --message 'TEXT' |
| gh pr list --repo R --state open --json ...             | glab mr list --repo R --state opened --output json           |
HINT
}
