# Loop Skill Reference

Quick reference for AI assistants working inside an Loop-managed project.

## Create work

Open an issue with a pipeline label to start the autonomous dev loop.

### GitHub

```bash
# Implement a fully-specified issue
gh issue create --repo owner/repo \
  --title "Add user profile page" \
  --label plan

# Expand a rough idea into a spec first (PO agent runs, then dev)
gh issue create --repo owner/repo \
  --title "[IDEA] user profile page" \
  --label po-review
```

### GitLab

```bash
# Implement a fully-specified issue
glab issue create --repo group/project \
  --title "Add user profile page" \
  --label plan

# Expand a rough idea into a spec first
glab issue create --repo group/project \
  --title "[IDEA] user profile page" \
  --label po-review
```

### Jira + GitLab

Jira issues start at a default status (e.g. "To Do"); Loop picks them up when
the status maps to `plan` (= "In Progress"). Create and transition in two steps:

```bash
# 1. Create the issue
ISSUE_KEY=$(curl -s -X POST \
  -u "$JIRA_USER:$JIRA_TOKEN" \
  -H "Content-Type: application/json" \
  "$JIRA_URL/rest/api/3/issue" \
  -d "{\"fields\":{\"project\":{\"key\":\"$JIRA_TICKET_PROJECT\"},\"summary\":\"Add user profile page\",\"issuetype\":{\"name\":\"Task\"}}}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['key'])")

# 2. Transition to "In Progress" so Loop's plan label mapping fires
TRANSITION_ID=$(curl -s \
  -u "$JIRA_USER:$JIRA_TOKEN" \
  "$JIRA_URL/rest/api/3/issue/$ISSUE_KEY/transitions" \
  | python3 -c "import json,sys; ts=json.load(sys.stdin)['transitions']; print(next(t['id'] for t in ts if t['name'].lower()=='in progress'))")

curl -s -X POST \
  -u "$JIRA_USER:$JIRA_TOKEN" \
  -H "Content-Type: application/json" \
  "$JIRA_URL/rest/api/3/issue/$ISSUE_KEY/transitions" \
  -d "{\"transition\":{\"id\":\"$TRANSITION_ID\"}}"
```

The scanner polls every 5 minutes; your issue will be picked up within that window.

## Label reference

Labels are the control plane. Always use canonical names for new issues and PRs.
Deprecated aliases still trigger the same events (the scanner polls both).

### Issue labels

| Canonical | Deprecated alias | Meaning |
|-----------|-----------------|---------|
| `plan` | `dev` | Trigger dev-handler to implement the issue |
| `build` | `in-progress` | Dev-handler is actively working |
| `needs-review` | `review-pending` | PR opened; awaiting code review |
| `in-review` | — | Review-handler has claimed the PR |
| `needs-rework` | `changes-requested` | Review requested changes; dev-rework-handler runs |
| `needs-qa` | `ready-for-qa` | Review approved; QA validation pending |
| `approved` | `qa-pass` | QA passed; merge-handler will squash-merge |
| `qa-failed` | `qa-fail` | QA failed; requires human or re-dev |
| `blocked` | — | Terminal: human attention required |
| `needs-clarification` | — | Waiting on issue author; no automation |
| `done` | — | Issue closed; PR merged |
| `po-review` | — | PO agent expands rough idea into full spec |

### State machine summary

```
plan → build → needs-review → in-review → needs-qa → approved → done
                                    └── needs-rework → build → needs-review
                                                                    └── qa-failed → blocked
```

Full state machine with all failure paths: `docs/label-lifecycle.md`

## Act on tickets

The pipeline is automatic once a label is set. This section describes what each
handler does so you can reason about current state.

| Label on issue/PR | Handler | Action |
|-------------------|---------|--------|
| `plan` / `dev` | `dev-handler` | Creates branch, runs agent, opens PR with `needs-review` |
| `needs-review` / `review-pending` (PR) | `review-handler` | Approves or adds `needs-rework` with feedback |
| `needs-qa` / `ready-for-qa` (PR) | `qa-handler` | Runs `validation_cmd`; sets `approved` or `qa-failed` |
| `approved` / `qa-pass` (PR) | `merge-handler` | Squash-merges PR, closes linked issue with `done` |
| `needs-rework` / `changes-requested` (issue) | `dev-rework-handler` | Addresses review feedback, rebases, re-opens for review |
| `po-review` (issue) | `po-handler` | Expands rough idea into spec with acceptance criteria |

To manually advance or reset a ticket, add and remove labels directly:

```bash
# Restart dev on a stalled issue
gh issue edit <N> --repo owner/repo --remove-label build --add-label plan

# Mark a PR ready for QA after manual review
gh pr edit <N> --repo owner/repo --remove-label in-review --add-label needs-qa
```

## Backend selection

Loop supports three backends. Set `backend:` in `config/projects.yaml`:

```yaml
projects:
  - name: My Project
    slug: myproj
    repo: owner/repo
    root: /path/to/checkout
    default_branch: main
    backend: github    # github | gitlab | jira-gitlab  (default: github)
```

### GitHub (default)

- CLI: `gh` (must be authenticated via `gh auth login`)
- Issues and PRs are GitHub Issues / Pull Requests
- Labels map 1-to-1 with Loop label names

### GitLab

- CLI: `glab` (must be authenticated via `glab auth login`)
- Merge Requests are transparently mapped to the PR abstraction
- For self-hosted instances, prefix the repo with the hostname:
  `repo: gitlab.example.com/group/project`
- Install labels: `./install.sh /path/to/project --backend=gitlab`

### Jira + GitLab composite (`jira-gitlab`)

Ticket state lives in Jira; code and MRs live in GitLab.

**Required env vars** (add to `loop.env`):

| Variable | Description |
|----------|-------------|
| `JIRA_URL` | Atlassian base URL, e.g. `https://yourorg.atlassian.net` (no trailing slash) |
| `JIRA_USER` | Atlassian account email |
| `JIRA_TOKEN` | Atlassian API token |
| `JIRA_TICKET_PROJECT` | Jira project key, e.g. `PROJ` |

**How Loop labels map to Jira transitions:**

| Loop label | Default Jira transition |
|-------------|------------------------|
| `plan` / `build` / `in-progress` | In Progress |
| `needs-review` / `review-pending` / `in-review` | In Review |
| `needs-qa` / `ready-for-qa` | QA |
| `approved` / `qa-pass` | QA |
| `qa-failed` / `qa-fail` | In Progress |
| `done` | Done |
| `blocked` / `needs-clarification` / `changes-requested` | Blocked |

Override any transition name via `LOOP_JIRA_STATE_*` env vars
(e.g. `LOOP_JIRA_STATE_REVIEW_PENDING`). The escape-hatch states (`blocked`,
`needs-clarification`, `changes-requested`) use `JIRA_BLOCKED_STATUS` instead
(default: `Blocked`). See `lib/backends/jira-gitlab.sh` for the full list.

**Install:**

```bash
./install.sh /path/to/project --backend=jira-gitlab
```

The installer validates credentials, tests connectivity to `/rest/api/3/myself`,
and prints a ready-to-paste `backend_config:` YAML block.
