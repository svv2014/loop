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
| `dev-handler.sh` | `dev` (or workflow-equivalent) on issue | Implements in worktree, opens PR, labels `needs-review` |
| `review-handler.sh` | `needs-review` on PR | AI reviewer reads diff, approves or requests changes |
| `dev-rework-handler.sh` | `needs-rework` or `qa-fail` on PR | Re-runs dev agent with rework context |
| `qa-handler.sh` | `needs-qa` on PR | Four-phase smart QA: AC verification, targeted test creation, module regression, `validation_cmd`; posts structured `### QA verification` comment; applies `qa-pass` or `qa-fail` |
| `merge-handler.sh` | `qa-pass` on PR | Squash-merges, closes linked issue, records bounty; if PR carries `release-pr` label, tags the merged commit and publishes a GitHub release |

Each handler also has a short-name alias (`builder.sh`, `planner.sh`,
`reviewer.sh`, `reviser.sh`, `tester.sh`, `merger.sh`) that is a thin
`exec` wrapper to the canonical handler script above.

Each handler:
- Acquires a per-project advisory lock (`/tmp/loop-locks/<slug>.lock`)
- Sources `lib/env.sh`, `lib/config.sh`, `lib/backends/backend.sh`
- Invokes the AI agent in an isolated git worktree
- Updates labels (the state machine)
- Reports a bounty event to loop-monitor (best-effort; never blocks)
- Releases its lock on exit

### Reconciler (`scanner/reconciler.sh`)

Every 15 minutes, sweeps each configured project for drift the scanner
doesn't self-correct. Two distinct classes of check:

**Mutating checks** (corroboration-gated, never speculative):
- Required-label bootstrap — creates any missing canonical Loop labels
  on the repo (`needs-po`, `needs-dev`, `needs-review`, `needs-qa`, etc.)
- Synonym + alias renames — rewrites deprecated label names to the
  workflow's live trigger labels. Workflow-aware (won't strip a label
  that IS a trigger for the project; won't apply one that isn't).
  Atomic add-then-remove so add-failure preserves the original label.
- Duplicate PRs (same `Closes #N`) — closes the older one
- Obsolete open PRs (issue already closed by a merged PR) — closes
  with reason
- Dependency unblock — parses `blocked by #N`, `depends on #N`,
  `## Dependencies` sections via `lib/dep_parser.sh`. Skips when an
  open PR already closes the issue (work is on PR side, no requeue).
- Stale-base auto-rebase — PRs whose base SHA diverged from main get
  rebased automatically when conflict-free.
- QA-failure transient retry vs repeated-failure clarification.
- Conflict-blocked PR auto-recycle — closes a CONFLICTING PR and
  re-queues the source issue to `dev`.
- Orphaned in-progress reset — issue stuck `in-progress` >10 min with
  no live handler lock → resets to `dev` (or canonical equivalent).
- Closed-issue label scrub — strips stale pipeline labels off issues
  closed in the last 7 days that the merge-handler didn't catch.
- PR label audit — strips issue-only labels (`tracker`, `epic`,
  `needs-clarification`) accidentally applied to PRs.

**Observational checks** (Signal-only, no mutation):
- Lost-issues detector — open issues with no pipeline label and no
  closing PR get a Signal once per ticket per 24h cool-down. Operator
  applies a trigger label or closes. Was the source of repeated label
  ping-pong before #214 made it observational.
- Anomaly detector — mines the reconciler's own log for ticket-level
  pathology (one ticket touched ≥4 times within 1h). Threshold,
  window, cool-down all tunable via env.
- Agent-distress detector — scans agent-authored comments on
  recently-updated tickets for narrative-pathology phrases ("reconciler
  keeps", "human action required", "no progress after N cycles").
  Surfaces to operator before the cycle escalates.
- Author-gated digest — counts tickets skipped due to ALLOWED_AUTHORS
  gate so an external user's request doesn't go silently unseen.

The split between mutating and observational is intentional: mutators
fight each other when they all run on the same ticket within one tick
on stale data. Observational checks just report — operator decides.

### Lock layer (`lib/lock.sh`)

Per-project advisory lock with TTL-based stale-lock stealing. Holders
record their PID; readers steal the lock if the holder is dead or
exceeded `LOOP_LOCK_TTL` (default: 2 hours). Cross-project parallelism
is allowed; same-project handlers serialize.

### Backend layer (`lib/backends/`)

Abstracts VCS/issue-tracker calls. Default: `github.sh` (uses `gh`
CLI). Alternates: `gitlab.sh`, `jira-gitlab.sh` (composite). Each
adapter implements a fixed interface so handlers don't care.

### Notify layer (`lib/notify.sh`)

Provides `loop_notify()` — a one-liner helper sourced by all handlers.
When `LOOP_NOTIFY` is set in `loop.env`, every handler calls
`eval "$LOOP_NOTIFY" <event>` at key lifecycle points (start, done,
error). No-ops silently when unset. Concrete notifier scripts live in
`lib/notifiers/` (`slack.sh`, `email.sh`, `stdout.sh`).

### Workflow layer (`lib/workflow.sh`)

Loads `config/workflows/<name>.yaml`, applies project label overrides
from `config/projects.yaml`. Public API: `loop_workflow_for_project`,
`loop_label_for`, `loop_polled_labels`, `loop_label_is_trigger`,
`loop_handler_for_label`, `loop_workflow_validate`. Used by scanner
and (selectively) by handlers to look up canonical-vs-actual label
names. `loop_label_is_trigger` caches per-(slug, kind) trigger sets in
env vars so a tick with many label candidates pays one workflow YAML
read per project.

## Data flow on one feature

```
                                                 Time →
operator
  │
  └─ labels issue #42 "dev"   ····························
                                                            │
  scanner (next tick, ≤5 min)   ◀──────────────────────────┤
  │                                                         │
  ├─ load workflow for project ··                           │
  ├─ poll issues with trigger_label="dev"                  │
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
│       ├── docs-only.yaml          documentation-only pipeline (dev→review→done)
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
│   ├── notify.sh                   loop_notify() helper; evaluates LOOP_NOTIFY fragment
│   ├── backends/                   github / gitlab / jira-gitlab adapters
│   └── notifiers/                  slack / stdout / email notifier scripts
├── scripts/
│   ├── po-handler.sh               PO expansion (canonical)
│   ├── dev-handler.sh              implementation (canonical)
│   ├── dev-rework-handler.sh       rework after review/QA (canonical)
│   ├── review-handler.sh           AI code review (canonical)
│   ├── qa-handler.sh               validation / QA (canonical)
│   ├── merge-handler.sh            squash-merge + bounty (canonical)
│   ├── planner.sh                  thin alias → po-handler.sh
│   ├── builder.sh                  thin alias → dev-handler.sh
│   ├── reviser.sh                  thin alias → dev-rework-handler.sh
│   ├── reviewer.sh                 thin alias → review-handler.sh
│   ├── tester.sh                   thin alias → qa-handler.sh
│   ├── merger.sh                   thin alias → merge-handler.sh
│   ├── auto-release-pr.sh          open/update a "chore: release vX.Y.Z" PR; merge-handler tags + publishes
│   ├── adopt.sh                    heuristic label-mapping for existing repos
│   ├── judge.sh                    AI judge — runs after merge
│   ├── bounty-board.sh             leaderboard CLI
│   ├── label-audit.sh              cross-repo label-coverage audit
│   ├── validate-workflow.sh        workflow YAML schema validator
│   ├── validate-config.sh          projects.yaml schema validator
│   ├── update.sh                   self-update with BREAKING change gate
│   └── release.sh                  semver bump + tag + GitHub release
├── scanner/
│   ├── scanner.sh                  5-min polling loop
│   └── reconciler.sh               15-min housekeeping
├── skills/
│   └── loop/                       Claude Code skill definition for Loop
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
