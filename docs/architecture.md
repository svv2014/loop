# Loop architecture

Single-machine, label-driven autonomous dev pipeline. One scanner
process polls multiple GitHub repos and dispatches events to handlers.

## Process map

```
            ┌─────────────────────────────────────────────────────┐
            │                Operator's machine                   │
            │                                                     │
            │   launchd (macOS) / cron (Linux)                    │
            │            │                                        │
            │            ▼                                        │
            │   ┌─────────────────┐    every 5 min                │
            │   │   scanner.sh    │ ──────────────┐               │
            │   └────────┬────────┘               │               │
            │            │                        │               │
            │   per-tick │ load workflow,         │               │
            │            │ poll each project      │               │
            │            ▼                        │               │
            │   ┌─────────────────┐               │               │
            │   │ dispatch event  │               │               │
            │   └────────┬────────┘               │               │
            │            │                        │               │
            │     ┌──────┼──────┬─────────┬──────┼──────┐        │
            │     ▼      ▼      ▼         ▼      ▼      ▼        │
            │   po-    dev-   review-   qa-   merge-  dev-       │
            │   handler handler handler handler handler rework   │
            │     │      │      │         │      │      │        │
            │     └──────┼──────┴─────────┴──────┼──────┘        │
            │            │ acquire per-project lock              │
            │            ▼                                        │
            │   ┌─────────────────┐                              │
            │   │   AI agent      │ via $LOOP_AGENT              │
            │   │ (worktree-iso)  │                              │
            │   └─────────────────┘                              │
            │                                                     │
            │   reconciler.sh — every 15 min                      │
            │   (housekeeping: stuck PRs, dependency unblocks)    │
            │                                                     │
            └─────────────────┬───────────────────────────────────┘
                              │ HTTP POST /api/report (versioned)
                              ▼
            ┌─────────────────────────────────────────┐
            │  loop-monitor                            │
            │  http://127.0.0.1:18792                  │
            │  - live agent status                     │
            │  - bounty leaderboard                    │
            │  - AI judge → PR scorecard comments      │
            └─────────────────────────────────────────┘
```

## Components

### Scanner (`scanner/scanner.sh`)

Polls every project listed in `config/projects.yaml` on a 5-minute cadence
(KeepAlive on macOS, `*/5` on Linux). Per project:

1. Look up the active workflow (`workflow:` field; default `default`)
2. For each issue/PR stage in the workflow, poll GitHub for issues/PRs
   carrying that stage's `trigger_label` (with project label overrides
   applied)
3. For each match, emit a typed event into the dispatch system
4. Honor `MAX_CONCURRENT_PRS` per-project — skips dev_issue events when
   the cap is reached

The scanner does no work itself; it just emits events. Handlers do the
actual work.

### Handlers (`scripts/*-handler.sh`)

| Handler | Trigger | What it does |
|---|---|---|
| `po-handler.sh` | `po-review` on issue | Expands rough idea into structured spec; relabels for dev |
| `dev-handler.sh` | `plan` (or workflow-equivalent) on issue | Implements in worktree, opens PR, labels `needs-review` |
| `review-handler.sh` | `needs-review` on PR | AI reviewer reads diff, approves or requests changes |
| `dev-rework-handler.sh` | `needs-rework` or `qa-fail` on PR | Re-runs dev agent with rework context |
| `qa-handler.sh` | `needs-qa` on PR | Runs project's `validation_cmd`; passes/fails |
| `merge-handler.sh` | `qa-pass` on PR | Squash-merges, closes linked issue, records bounty |

Each handler:
- Acquires a per-project advisory lock (`/tmp/loop-locks/<slug>.lock`)
- Sources `lib/env.sh`, `lib/config.sh`, `lib/backends/backend.sh`
- Invokes the AI agent in an isolated git worktree
- Updates labels (the state machine)
- Reports a bounty event to loop-monitor (best-effort; never blocks)
- Releases its lock on exit

### Reconciler (`scanner/reconciler.sh`)

Every 15 minutes, sweeps for drift the scanner doesn't self-correct:

- Duplicate PRs (same `Closes #N`) — closes the older one
- Orphaned `needs-review` issues (PR was closed without merging) —
  resets to `plan`
- Stale PRs (>24h with no movement) — notification only
- Dependency unblock — parses `## Dependencies` section, re-labels
  to `plan` once all referenced issues are closed
- Missing-label routing — issues with no pipeline label get `po-review`

### Lock layer (`lib/lock.sh`)

Per-project advisory lock with TTL-based stale-lock stealing. Holders
record their PID; readers steal the lock if the holder is dead or
exceeded `LOOP_LOCK_TTL` (default: 2 hours). Cross-project parallelism
is allowed; same-project handlers serialize.

### Backend layer (`lib/backends/`)

Abstracts VCS/issue-tracker calls. Default: `github.sh` (uses `gh`
CLI). Alternates: `gitlab.sh`, `jira-gitlab.sh` (composite). Each
adapter implements a fixed interface so handlers don't care.

### Workflow layer (`lib/workflow.sh`)

Loads `config/workflows/<name>.yaml`, applies project label overrides
from `config/projects.yaml`. Public API: `loop_workflow_for_project`,
`loop_label_for`, `loop_polled_labels`, `loop_handler_for_label`,
`loop_workflow_validate`. Used by scanner and (selectively) by handlers
to look up canonical-vs-actual label names.

## Data flow on one feature

```
                                                 Time →
operator
  │
  └─ labels issue #42 "plan"   ····························
                                                            │
  scanner (next tick, ≤5 min)   ◀──────────────────────────┤
  │                                                         │
  ├─ load workflow for project ··                           │
  ├─ poll issues with trigger_label="plan"                  │
  └─ emit loop.dev_issue PR#42                              │
                                                            │
  dev-handler.sh                ◀──────────────────────────┤
  │                                                         │
  ├─ acquire lock                                           │
  ├─ create worktree at /tmp/loop-worktree-myproj-42       │
  ├─ invoke $LOOP_AGENT with issue body + CLAUDE.md ·······│
  │                                                         │ (agent
  ├─ agent commits, opens PR #100                           │  thinks
  ├─ relabel issue #42 in-progress→done                     │  ~5 min)
  ├─ label PR #100 needs-review                             │
  ├─ bounty_report dev_done                                 │
  └─ release lock                                           │
                                                            │
  scanner (next tick)            ◀──────────────────────────┤
  │                                                         │
  └─ emit loop.pr_review PR#100                             │
                                                            │
  review-handler.sh              ◀──────────────────────────┤
  │                                                         │
  ├─ invoke agent with diff + acceptance criteria           │
  ├─ agent says APPROVE                                     │
  ├─ relabel PR #100 needs-review→needs-qa                  │
  └─ bounty_report review_done                              │
                                                            │
  ... (qa-handler runs validation_cmd, on pass labels qa-pass)
                                                            │
  merge-handler.sh               ◀──────────────────────────┤
  │                                                         │
  ├─ gh pr merge #100 --squash --delete-branch              │
  ├─ close linked issue #42 (Closes #42 from PR body)       │
  ├─ append bounty record to data/bounties.jsonl            │
  ├─ run scripts/judge.sh → posts scorecard comment on PR   │
  └─ bounty_report merge_done

operator wakes up, checks loop-monitor:
                              total: +13 points
                              clean merge, no rework
```

Total elapsed: usually 10–20 min for a small feature, longer for QA-heavy
projects. The scanner cadence (5 min) is the floor.

## File layout

```
loop/
├── VERSION                         single source of truth for semver
├── CHANGELOG.md
├── ROADMAP.md
├── README.md
├── LICENSE
├── CONTRIBUTING.md
├── SECURITY.md
├── install.sh                      project onboarding + bootstrap
├── loop.env.example                operator-config template (not committed: loop.env)
├── config/
│   ├── projects.example.yaml       multi-project registry template
│   └── workflows/
│       ├── README.md               schema docs
│       ├── default.yaml            new-repo recommended workflow
│       ├── current.yaml            legacy-vocabulary mirror
│       └── minimal.yaml            solo prototype
├── lib/
│   ├── env.sh                      loads loop.env, sets PATH, sources version + workflow
│   ├── version.sh                  exposes LOOP_VERSION
│   ├── workflow.sh                 workflow loader + lookups
│   ├── config.sh                   parses projects.yaml
│   ├── github.sh                   gh CLI wrappers
│   ├── runner.sh                   dispatches to LOOP_AGENT
│   ├── lock.sh                     per-project file lock with TTL stealing
│   ├── bounty.sh                   versioned bounty event sender
│   ├── backends/                   github / gitlab / jira-gitlab adapters
│   └── notifiers/                  slack / stdout / email
├── scripts/
│   ├── po-handler.sh
│   ├── dev-handler.sh
│   ├── dev-rework-handler.sh
│   ├── review-handler.sh
│   ├── qa-handler.sh
│   ├── merge-handler.sh
│   ├── judge.sh                    AI judge — runs after merge
│   ├── bounty-board.sh             leaderboard CLI
│   ├── label-audit.sh              cross-repo label-coverage audit
│   ├── validate-workflow.sh        YAML schema validator
│   └── release.sh                  semver bump + tag + GitHub release
├── scanner/
│   ├── scanner.sh                  5-min polling loop
│   └── reconciler.sh               15-min housekeeping
├── templates/
│   ├── CLAUDE.md.template          per-project agent briefing
│   └── launchd/                    macOS plist templates
├── tests/                          bats shell tests
├── docs/
│   ├── architecture.md             this file
│   ├── quick-start.md
│   ├── security-model.md
│   ├── adoption.md
│   ├── backends.md
│   ├── getting-started.md
│   ├── label-lifecycle.md
│   └── projects-yaml-reference.md
└── .github/
    ├── CODEOWNERS
    ├── ISSUE_TEMPLATE/
    ├── pull_request_template.md
    └── workflows/                  CI for the repo (lint, qa-merge)
```
