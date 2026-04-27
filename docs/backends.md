# Loop Backend Interface

Loop separates pipeline logic from the underlying VCS/issue-tracker via a
thin backend adapter layer in `lib/backends/`.

## How it works

`lib/backends/backend.sh` is the dispatcher. Every script that needs
to talk to GitHub (or another host) sources it at startup:

```bash
source "$LOOP_ROOT/lib/backends/backend.sh"
```

After loading a project (`loop_load_project "$slug"`), the script calls:

```bash
loop_load_backend
```

This reads `$BACKEND` (exported by `loop_load_project` from `projects.yaml`,
default `github`) and sources `lib/backends/${BACKEND}.sh`.

## Selecting a backend

Add a `backend:` field to your project entry in `config/projects.yaml`:

```yaml
projects:
  - name: My Project
    slug: myproj
    repo: owner/repo
    root: /path/to/checkout
    default_branch: main
    backend: github   # default — can be omitted
```

## Core interface

Every backend implementation must provide these 14 functions:

| Function | Description |
|---|---|
| `backend_list_issues_with_label <repo> <label>` | Priority-sorted open issues with label, one JSON object per line |
| `backend_list_prs_with_label <repo> <label>` | Priority-sorted open PRs with label, one JSON object per line |
| `backend_add_label <repo> <number> <label>` | Add a label to an issue or PR |
| `backend_remove_label <repo> <number> <label>` | Remove a label from an issue or PR |
| `backend_issue_has_any_label <repo> <number> <label...>` | Returns 0 if issue has any of the labels |
| `backend_pr_has_any_label <repo> <number> <label...>` | Returns 0 if PR has any of the labels |
| `backend_issue_view <repo> <number> [flags...]` | Fetch issue data; extra flags passed through |
| `backend_pr_view <repo> <number> [flags...]` | Fetch PR data; extra flags passed through |
| `backend_open_pr <repo> <title> <body_file> <label>` | Open a PR; returns URL on stdout |
| `backend_close_issue <repo> <number>` | Close an issue |
| `backend_close_pr <repo> <number> [--delete-branch]` | Close a PR, optionally deleting the branch |
| `backend_comment_issue <repo> <number> <body>` | Post a comment on an issue |
| `backend_comment_pr <repo> <number> <body>` | Post a comment on a PR |
| `backend_merge_pr <repo> <number> <strategy_flag>` | Merge a PR (`--squash`, `--merge`, or `--rebase`) |

### Extended interface (used by reconciler/scanner)

| Function | Description |
|---|---|
| `backend_list_open_prs_raw <repo>` | JSON array of all open PRs with number, body, createdAt, headRefName, title, labels, updatedAt |
| `backend_list_merged_prs_raw <repo>` | JSON array of recently merged PRs with number, body |
| `backend_list_open_issues_raw <repo> <label>` | JSON array of open issues with the label, with number, title, labels, body, updatedAt |

## Adding a new backend

1. Create `lib/backends/<name>.sh`.
2. Implement all 14 core functions and the 3 extended functions listed above.
3. The file is sourced in the caller's shell — all functions must be defined at
   the top level (no subshells).
4. Use `lib/github.sh` as the reference implementation.
5. Set `backend: <name>` in `config/projects.yaml` for the projects that should
   use it.

### Minimal skeleton

```bash
#!/usr/bin/env bash
# lib/backends/mybackend.sh — Loop adapter for MyBackend

backend_list_issues_with_label() { ... }
backend_list_prs_with_label()    { ... }
backend_add_label()              { ... }
backend_remove_label()           { ... }
backend_issue_has_any_label()    { ... }
backend_pr_has_any_label()       { ... }
backend_issue_view()             { ... }
backend_pr_view()                { ... }
backend_open_pr()                { ... }
backend_close_issue()            { ... }
backend_close_pr()               { ... }
backend_comment_issue()          { ... }
backend_comment_pr()             { ... }
backend_merge_pr()               { ... }

# Extended
backend_list_open_prs_raw()      { ... }
backend_list_merged_prs_raw()    { ... }
backend_list_open_issues_raw()   { ... }
```

## GitLab backend

Uses the `glab` CLI. Merge Requests are mapped transparently to the PR abstraction.

### Prerequisites

```bash
# Install (macOS)
brew install glab

# Authenticate (gitlab.com)
glab auth login

# Authenticate (self-hosted)
glab auth login --hostname gitlab.example.com
```

### Repo format

| GitLab instance | `repo` field in projects.yaml |
|-----------------|-------------------------------|
| gitlab.com | `group/project` |
| Self-hosted | `gitlab.example.com/group/project` |

When three or more slash-separated components are present the first is treated as
the hostname. `GITLAB_HOST` is exported automatically so all subsequent `glab`
calls target the right instance. You can also set `GITLAB_HOST` globally in
`loop.env`.

### Installing labels

```bash
./install.sh /path/to/project --backend=gitlab [--auto]
```

Calls `glab label create` for each canonical Loop label (colour values are
prefixed with `#` as GitLab requires). If `glab` is not found, a warning is
printed and label creation is skipped so the rest of the setup continues.

Auto-merge and branch-deletion settings are not configured automatically for
GitLab — enable them in the project's **Settings → Merge Requests** screen.

### GitLab-specific notes

- `backend_issue_view` / `backend_pr_view` return native `glab` JSON (fields
  such as `iid`, `web_url`, `source_branch`). GitHub-style `--json`/`--jq`
  flags are **not** forwarded.
- `backend_close_pr --delete-branch` deletes the source branch via
  `glab api DELETE /projects/:encoded_path/repository/branches/:branch`.
- `backend_merge_pr` maps `--squash` → `--squash`, `--rebase` → `--rebase`,
  and `--merge` → default merge commit. `--remove-source-branch` is always
  passed.

## Adding a fourth backend

1. **Create `lib/backends/<name>.sh`.**

2. **Add the double-source guard at the top:**
   ```bash
   [ -n "${_LOOP_BACKEND_<NAME>_LOADED:-}" ] && return 0
   _LOOP_BACKEND_<NAME>_LOADED=1
   ```

3. **Implement all 14 core functions and 3 extended functions.** Use
   `lib/backends/github.sh` as the reference. Every function that
   lists items must emit priority-sorted JSONL in the schema expected
   by the scanner (see the table above).

4. **Register in `projects.yaml`:**
   ```yaml
   backend: <name>
   repo: <platform-specific-identifier>
   ```

5. **Add a label-creation branch to `install.sh`** (copy the `gitlab`
   branch inside the labels section and adapt the CLI calls).

6. **Validate:**
   ```bash
   bash -n lib/backends/<name>.sh
   bash scanner/scanner.sh --dry-run
   ```

## Jira+GitLab composite backend

Uses Jira for ticket tracking (issues, status transitions) and GitLab for code
hosting and Merge Requests. This is the `jira-gitlab` backend.

### How it works

`lib/backends/jira-gitlab.sh` sources `lib/backends/gitlab.sh` at load time to
inherit all MR/PR functions. It then overrides the issue/ticket functions with
Jira REST API v3 calls. `backend_merge_pr` is a passthrough to GitLab.

### Prerequisites

| Requirement | Details |
|-------------|---------|
| `glab` CLI  | Authenticated (`glab auth login`) |
| Jira API token | Generate at https://id.atlassian.com/manage-profile/security/api-tokens |
| Jira project | Must have statuses that match `state_map` entries |

### Auth setup

Add to `loop.env`:

```bash
JIRA_URL=https://yourorg.atlassian.net   # no trailing slash
JIRA_USER=you@example.com
JIRA_TOKEN=<atlassian-api-token>

# Optional: status name for escape-hatch states (default: "Blocked")
JIRA_BLOCKED_STATUS="Blocked"

# Jira project key (also set in backend_config.ticket_project)
JIRA_TICKET_PROJECT=PROJ
```

### Installation

```bash
./install.sh /path/to/project --backend=jira-gitlab
```

The installer validates `JIRA_URL`, `JIRA_USER`, `JIRA_TOKEN`, verifies
connectivity with `/rest/api/3/myself`, and prints a ready-to-paste
`backend_config:` YAML block. GitLab labels are created with `glab`.

### projects.yaml configuration

```yaml
- name: My Jira+GitLab Project
  slug: jira-sample
  backend: jira-gitlab
  repo: gitlab.com/mygroup/myrepo   # GitLab repo — used for MR operations
  root: /absolute/path/to/jira-sample
  default_branch: main

  dev:
    commit_prefix: PROJ   # should match your Jira project key

  backend_config:
    ticket_project: PROJ  # Jira project key; issues are addressed as PROJ-N
    state_map:
      dev: "In Progress"
      in-progress: "In Progress"
      review-pending: "In Review"
      in-review: "In Review"
      ready-for-qa: "QA"
      qa-pass: "QA"
      qa-fail: "In Progress"
      done: "Done"
      needs-clarification: "Blocked"
      changes-requested: "Blocked"
      blocked: "Blocked"
```

### Transition mapping

When the pipeline adds a label (e.g. `review-pending`), the backend maps it to
the corresponding Jira transition name and calls:

```
POST /rest/api/3/issue/{key}/transitions
{"transition": {"id": "<transition-id>"}}
```

To list valid transition names for a sample issue:

```bash
curl -s -u "$JIRA_USER:$JIRA_TOKEN" \
     "$JIRA_URL/rest/api/3/issue/PROJ-1/transitions" \
  | jq '.transitions[] | .name'
```

### Escape-hatch states

States `needs-clarification`, `changes-requested`, and `blocked` signal that
the pipeline cannot continue without human intervention.

**Behaviour:**

1. Loop tries to transition the issue to `JIRA_BLOCKED_STATUS` (default: `Blocked`).
2. If that transition is unavailable in the project's workflow, Loop posts a
   comment instead: `Loop: state=needs-clarification` (or the actual state).

Override the fallback status globally in `loop.env`:

```bash
JIRA_BLOCKED_STATUS="On Hold"
```

### Smoke test (read-only)

```bash
# Verify credentials
curl -s -u "$JIRA_USER:$JIRA_TOKEN" \
     "$JIRA_URL/rest/api/3/myself" | jq .displayName

# List "In Progress" issues in PROJ without triggering any transitions
curl -s -u "$JIRA_USER:$JIRA_TOKEN" \
     "$JIRA_URL/rest/api/3/search?jql=project=PROJ+AND+status=%22In+Progress%22&fields=summary,status" \
  | jq '.issues[] | {key, summary: .fields.summary}'
```

## Available adapters

| Backend | File | CLI | Status |
|---------|------|-----|--------|
| `github` | `lib/backends/github.sh` | `gh` | shipped |
| `gitlab` | `lib/backends/gitlab.sh` | `glab` | shipped (#3) |
| `jira-gitlab` | `lib/backends/jira-gitlab.sh` | `glab` + Jira REST | shipped (#4) |
