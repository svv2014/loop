# Loop — Autonomous Dev Pipeline for GitHub Projects

<img src="assets/wolf-logo.svg" alt="Loop wolf mascot" width="120">

> *Loop — the pack that ships.*

> Label an issue. Walk away. Loop opens a PR, reviews it, runs QA, merges.
> 24/7. Multi-project. Bring-your-own AI agent.

The name is a nod to _loup_, French for wolf — a predator that hunts in packs, never stops, and always ships.

```
   You label an issue                  ┌──────────────────────────────┐
                                       │                              │
        │                              │   24/7 scanner               │
        ▼                              │   one operator, many repos   │
  ┌──────────┐   ┌──────────┐   ┌──────┴────┐   ┌──────────────┐     │
  │   Plan   │──▶│  Review  │──▶│    QA     │──▶│  Auto-Merge  │─────┘
  │ implement│   │  approve │   │ build/test│   │  squash +    │
  │ + open PR│   │  or ask  │   │ validate  │   │  close issue │
  └──────────┘   └──────────┘   └───────────┘   └──────────────┘
        │             │              │
        ▼             ▼              ▼
       blocked   needs-rework    qa-fail → dev-rework
```

**What's different about Loop:**

- **24/7 autonomous** — runs as a background scanner (launchd / cron). No
  slash-commands, no human invocation. You label an issue at midnight, you
  see a PR by morning.
- **Multi-project from one install** — manage a dozen repos with one
  scanner and one config file. Per-project locks, concurrency caps, and
  workflow choices.
- **Bring-your-own workflow** — pipeline stages and the labels that drive
  them are declared in `config/workflows/<name>.yaml`. Ship one of three
  starters or write your own. Per-project label overrides supported.
- **Bring-your-own AI** — `claude`, `codex`, `gemini`, `aider`, or a
  custom CLI via `LOOP_AGENT`. No vendor lock-in.
- **Bounty + judge layer** — companion [loop-monitor](https://github.com/svv2014/loop-monitor)
  dashboard tracks role-level points across the pipeline and runs an AI
  judge that posts a scorecard comment on every merged PR.
- **Backend agnostic** — GitHub default; GitLab and Jira+GitLab adapters
  ship in `lib/backends/`.

## Install

Three commands. No file editing required.

```bash
git clone https://github.com/svv2014/loop.git && cd loop
./install.sh --bootstrap            # auto-detects agent, writes loop.env, registers scanner
./install.sh /path/to/your-project  # registers project + smoke-tests the scanner
```

Bootstrap auto-detects your agent (`claude`, `codex`, `gemini`, or `aider`) and writes
`LOOP_AGENT` to `loop.env`. No manual editing needed for the happy path.

Then label an issue to start the pipeline:

```bash
# Rough idea — PO agent expands the spec, then implements:
gh issue edit <number> --repo owner/repo --add-label po-review

# Already have a full spec — skip PO and go straight to implementation:
gh issue edit <number> --repo owner/repo --add-label dev
```

The scanner picks it up within 5 minutes and opens a PR automatically.

```bash
# Check that everything is healthy at any time:
./install.sh status
```

<details>
<summary>Advanced config — agent override, GitLab, other agents, loop-monitor</summary>

To override the detected agent, edit `loop.env`:

```bash
LOOP_AGENT=codex           # or: gemini, aider, custom
LOOP_AGENT_MODEL=o4-mini   # optional model override
```

Or re-bootstrap with an explicit agent:

```bash
LOOP_AGENT=gemini ./install.sh --bootstrap
```

For GitLab, Jira+GitLab, loop-monitor integration, and full configuration reference —
see [docs/quick-start.md](docs/quick-start.md).

</details>

## How a feature flows through Loop

1. **You** open an issue, write what you want, label it `po-review` (rough idea — PO agent expands the spec first) or `dev` (pre-written spec — skip straight to implementation).
2. **Scanner** notices the label within 5 minutes, fires the dev handler.
3. **Dev handler** invokes your AI agent in an isolated git worktree.
   Agent reads the issue, writes code, opens a PR, labels it
   `needs-review`.
4. **Review handler** sends the diff back to an AI agent for an
   approve/reject decision. On approve → `needs-qa`. On reject →
   `needs-rework` and back to step 3.
5. **QA handler** runs four-phase smart QA: verifies acceptance criteria,
   creates targeted tests, runs regression on touched modules, then runs
   the project's `validation_cmd`. Posts a structured `### QA verification`
   comment. On pass → `qa-pass`. On fail → `qa-fail` → dev-rework.
6. **Merge handler** squash-merges, closes the linked issue, records a
   bounty event, triggers the judge for a PR scorecard.
7. **Reconciler** runs every 15 minutes to clean up stuck states,
   duplicate PRs, dependency unblocks, and red-CI PRs (see below).

The whole flow is just labels on issues and PRs. You can intervene at
any stage by manually labeling.

## Workflows (bring your own)

Loop ships three starter workflows in `config/workflows/`:

| Workflow | When to use |
|---|---|
| `default.yaml` | New repos. Clean canonical labels: `po-review` / `dev` / `needs-review` / `needs-qa` / `qa-pass`. Five-stage pipeline with PO expansion + rework loop. |
| `minimal.yaml` | Solo prototypes. Two stages: `plan → merge`. No review, no QA. |
| `docs-only.yaml` | Documentation and content PRs. Three stages: `plan → review → merge`. No QA gate. |

`current.yaml` is an operator-local workflow (gitignored). If you're migrating from a repo that already uses legacy labels (`dev` / `review-pending` / `ready-for-qa`), create it locally — see [`docs/migration-from-asdlc.md`](docs/migration-from-asdlc.md) for a full label mapping and setup instructions.

Per-project workflow + label overrides in `config/projects.yaml`:

```yaml
version: 1
projects:
  - name: My App
    slug: myapp
    repo: owner/my-app
    workflow: default              # references config/workflows/default.yaml
    labels:                        # optional — sparse overrides
      plan: dev                    # repo uses 'dev' instead of 'plan'
      qa-pass: approved
```

Author your own — see [`config/workflows/README.md`](config/workflows/README.md).

## Configuration

- `loop.env` — operator-specific env (log dir, agent choice, dispatch mode,
  notifications, PATH extras). Copy from `loop.env.example`. **Not committed.**
- `config/projects.yaml` — your project registry. **Not committed.**
- `config/projects.example.yaml` — annotated schema reference.
- `config/workflows/*.yaml` — pipeline workflow definitions. Committed.

## Auto-label orphan issues

Operator-filed issues sometimes land in a repo without any pipeline label —
a priority tag at best, sometimes nothing — and the scanner skips them
silently because no trigger label fires. The reconciler now picks these
orphans up on each tick and applies `needs-po` so the PO handler claims
them on the following scan.

The sweep is conservative: it acts only on open issues with no workflow
trigger label (`needs-po`, `in-po`, `po-review`, `dev`, `plan`,
`needs-dev`, `in-progress`), no terminal label (`needs-clarification`,
`blocked`, `done`), and no `epic` / `tracker` umbrella tags. Issues whose
author is outside `ALLOWED_AUTHORS` are skipped unless they carry the
`operator-approved` override label. An `auto_labeled_needs_po` event is
posted to loop-monitor (when `LOOP_MONITOR_URL` is set) for observability.

**Opt out** by setting `LOOP_AUTO_NEEDS_PO=false` in `loop.env`. Disable
this if your repo has issues that should stay unlabeled (e.g. discussion
threads) or if you prefer to label every issue manually.

## Auto-close finished trackers

Tracker / epic issues collect a list of child issue references in the body.
Once every referenced child is closed, the umbrella issue is effectively
done, but it rarely gets closed by hand. Each reconciler tick now runs
`reconcile_tracker_issues`, which parses child references out of each open
issue labelled `tracker` or `epic`, verifies each child's state via `gh`,
and closes the tracker (with a comment listing the shipped children) only
when **all** referenced children are closed.

Parsing is intentionally narrow — false negatives (a child reference we
don't recognise) are fine; false positives (closing a tracker while open
work remains) are not. Recognised patterns:

- GitHub task list checkboxes: `- [ ] #123` or `- [x] #123` (the box is
  treated as a hint only — the child's real state on the server wins, so a
  manually-ticked `[x]` won't close the tracker if the issue is still open)
- Plain `#N` inside list items: `- See #45 for context`
- Keyword references: `Tracks #N`, `Sub-issue #N`, `Child: #N`,
  `Closes #N`, `Fixes #N`, `Resolves #N` (case-insensitive)

Trackers with no parseable children are skipped — we never close without
proof. A `tracker_closed` event is posted to loop-monitor (when
`LOOP_MONITOR_URL` is set) for observability.

**Opt out** by setting `LOOP_AUTO_CLOSE_TRACKERS=false` in `loop.env`.

## Auto-rework on red CI

When Loop opens a PR (branch convention `feat/issue-N-*`) and a **required**
CI check fails, the reconciler automatically applies `needs-rework` to the PR
and strips the parent issue's trigger label so the dev agent can fix the
failures on the next cycle. The reconciler is a no-op when:

- The PR already carries `needs-rework` or `changes-requested`.
- A human reviewer has approved or requested changes.
- The failing check is not marked as **required** in the repository settings.

A `pr_ci_failed` event is posted to loop-monitor (if `LOOP_MONITOR_URL` is
set in `loop.env`) for observability.

**To opt out per project**, add `dev.auto_rework_on_ci: false` to the project
entry in `config/projects.yaml`:

```yaml
projects:
  - slug: myapp
    repo: owner/my-app
    dev:
      auto_rework_on_ci: false   # disable reconciler auto-rework on red CI
```

### Auto-promote on green CI

When Loop opens a PR (branch convention `feat/issue-N-*`) and **all required**
CI checks reach `SUCCESS`, the reconciler automatically promotes the PR from
`needs-dev` to the project's review-stage trigger label (typically
`needs-review`) so it enters the human-review phase without manual
intervention. The reconciler is a no-op when:

- The PR does not carry `needs-dev`.
- The PR already carries `needs-review`, `changes-requested`, or `needs-rework`.
- A human reviewer has left an `APPROVED`, `CHANGES_REQUESTED`, or `COMMENTED`
  review (reviewers in `ALLOWED_AUTHORS` are excluded from this check).
- Any required check is not yet `SUCCESS` (e.g. `PENDING`, `IN_PROGRESS`,
  `EXPECTED`, `QUEUED`, or `FAILURE`).
- No required checks are configured and the PR is not `MERGEABLE` (guard
  against promoting unverified PRs in repos with no branch protection).

A `pr_ci_passed` event is posted to loop-monitor (if `LOOP_MONITOR_URL` is
set in `loop.env`) for observability.

**To opt out per project**, set `AUTO_PROMOTE_ON_CI=false` in `loop.env`, or
configure it in `config/projects.yaml` and ensure the env var is exported
before the reconciler runs:

```yaml
projects:
  - slug: myapp
    repo: owner/my-app
    dev:
      auto_promote_on_ci: false   # disable reconciler auto-promote on green CI
```

### Auto-rebase on base-move

When Loop opens a PR (branch convention `feat/issue-N-*`) and the base branch
advances so that the PR's `mergeStateStatus` becomes `DIRTY` or `mergeable`
becomes `CONFLICTING`, the reconciler automatically attempts a rebase.

**Clean rebase path:** the rebased branch is pushed with
`--force-with-lease` (never plain `--force` — a concurrent developer push
causes the push to be rejected rather than clobbered). Labels are NOT changed:
CI re-runs naturally, and the green-CI sweep (Sweep 1) promotes the PR once
checks pass.

**Conflict path:** `git rebase --abort` is called. A diagnostic comment is
posted on the PR listing each conflicted file and the most recent base commit
that touched it:

```
Reconciler: auto-rebase onto `origin/<base>` failed with conflicts. Routing to `needs-rework`.

Conflicted files:
- `lib/runner.sh` — recent base commit: `abc1234 update runner fallback logic`
- `scanner/reconciler.sh` — recent base commit: `def5678 add ci-red sweep`
```

`needs-rework` is applied to the PR; trigger labels (`needs-dev`, `in-dev`,
`dev`, `in-progress`) are stripped from the linked issue so the dev agent
handles the conflict on the next cycle. A `pr_rebase_conflict` event is
emitted to loop-monitor (if `LOOP_MONITOR_URL` is set).

**No-op conditions:**

- The PR already carries `needs-rework`, `changes-requested`, or `blocked`.
- A human reviewer has approved or requested changes on the PR.
- `mergeStateStatus` is not `DIRTY` and `mergeable` is not `CONFLICTING`.

**To opt out per project**, add `dev.auto_rebase_on_base_move: false` to the
project entry in `config/projects.yaml` (mirrors the `AUTO_REBASE_ON_BASE_MOVE`
env var):

```yaml
projects:
  - slug: myapp
    repo: owner/my-app
    dev:
      auto_rebase_on_base_move: false   # disable reconciler auto-rebase on base-move
```

### Label-state convergence

Stage handlers each touch a narrow set of labels, and occasionally leave a
ticket in a workflow-illegal combination — e.g. a PR with both `qa-pass` AND
`needs-dev`, or a PR carrying `qa-fail` but no `needs-rework`. These
combinations confuse the next handler: sometimes the wrong role claims,
sometimes nothing claims and the ticket stalls.

Every reconciler tick runs `reconcile_label_consistency`, which enforces
per-stage exclusivity rules so the label state always represents a single
workflow stage.

**PR rules:**

- `qa-pass` present → strip `needs-dev`, `needs-review`, `needs-rework`,
  `changes-requested`, `qa-fail`, `in-review`, `in-rework`.
- `qa-fail` or `changes-requested` present → ensure `needs-rework` is set
  (add if missing); strip `qa-pass` and `needs-review`.
- `needs-review` present → never co-exists with `needs-dev`, `needs-rework`,
  or `changes-requested`. On conflict, the rework signal wins and
  `needs-review` is removed.
- `ready-for-qa` present → strip `needs-review`, `needs-dev`.

**Issue rules:**

- `needs-dev` present → strip `needs-po`, `in-po`, `po-review`, `plan`.
- `needs-po` present → strip `needs-dev`, `in-progress`, `dev`.
- `blocked` present → terminal state; strip every trigger label
  (`needs-po`, `needs-dev`, `in-po`, `in-progress`, `dev`, etc).

Each convergence emits a `label_state_converged` event to loop-monitor (if
`LOOP_MONITOR_URL` is set) with the added/removed labels for observability.

**Opt-out:** set `LOOP_LABEL_CONVERGE=false` in `loop.env` to disable the
sweep. The check honours `DRY_RUN` (logs intended mutations, makes no API
calls).

## Stage labels (`loop:stage:*`)

Every open issue carries a single `loop:stage:<name>` label that names its
current pipeline stage.  The reconciler derives and maintains this label
automatically — no handler needs to set it.

### Stage namespace

| Stage label          | Meaning                        | Primary trigger label |
|----------------------|--------------------------------|-----------------------|
| `loop:stage:po`      | PO triage queue                | `needs-po`            |
| `loop:stage:dev`     | Development queue              | `needs-dev`           |
| `loop:stage:review`  | Waiting for human review       | `needs-review`        |
| `loop:stage:qa`      | QA / build gate                | `needs-qa`            |
| `loop:stage:merge`   | Approved, ready to merge       | `qa-pass`             |
| `loop:stage:blocked` | Blocked / needs clarification  | `blocked`             |
| `loop:stage:done`    | Merged / closed                | —                     |

The stage label is a **derived, read-only** marker.  Trigger labels remain
the scanner's dispatch mechanism — the `loop:stage:*` label exists purely so
tooling can answer "what stage is this ticket in?" with a single label lookup.

### Reconciler behaviour

Each reconciler tick runs `reconcile_stage_labels`, which:

1. **No stage label** → derives the correct stage from the trigger labels
   present and adds `loop:stage:<name>`.
2. **Stage label disagrees with trigger labels** → the stage label wins;
   reconciler reapplies the canonical trigger label for that stage and
   removes any contradicting trigger labels.
3. **Multiple stage labels** → removes extras, keeps the one that matches
   the highest-priority trigger label (merge > qa > review > dev > po).
4. **No trigger labels** → leaves the ticket alone (no stage label
   invented); the existing lost-issue path surfaces it.

### Bootstrap / backfill

To apply stage labels to all existing open tickets in a project:

```bash
# Dry-run first (default):
scripts/backfill-stage-labels.sh --slug <slug>

# Apply for real:
scripts/backfill-stage-labels.sh --slug <slug> --apply

# All projects:
scripts/backfill-stage-labels.sh --apply
```

The script is idempotent — a second pass makes zero changes when all labels
are already correct.

## Pipeline concurrency & priority

Loop's scanner picks issues to claim every 5 minutes. Two knobs control how
it picks:

**`dev.pipeline_slots`** (per-project, optional) — cap the number of
in-flight tickets per project across *all* pipeline stages
(`needs-po` through `needs-qa` / `qa-pass`). When the project already has
that many tickets in flight, the scanner refuses to emit fresh claims at
the first issue stage; downstream stages (review / qa / merge for existing
work) keep flowing so in-flight tickets drain to completion.

- `pipeline_slots: 1` → **serial mode** (recommended when you want to fully
  finish one ticket before starting the next; useful for repos where mid-
  flight rework is expensive or PO/dev failures tend to leave half-done state).
- `pipeline_slots: N` (N ≥ 2) → cap concurrent tickets at N.
- Omit to disable the gate (legacy behaviour: `dev.max_concurrent_prs`
  is the only cap).

```yaml
projects:
  - slug: myapp
    repo: owner/my-app
    dev:
      pipeline_slots: 1   # serial: finish one before starting the next
```

**Priority-aware pick order.** Whenever multiple candidates carry a trigger
label, the scanner orders them by priority label before claiming:

> `p0-critical` → `p1-high` → `p2-medium` → `p3-low` → unlabeled

Tiebreaker: lower issue/PR number (oldest first). This applies regardless
of `pipeline_slots`, so multi-slot projects still drain `p1-high` work
before `p3-low`.

**Serial vs parallel — which to pick?**

| Use serial (`pipeline_slots: 1`) | Use parallel (default / `max_concurrent_prs > 1`) |
|---|---|
| Solo project where context-switching is expensive | Big repo with many independent issues |
| Recent failures left half-done tickets | Mature pipeline with reliable PO/dev/QA |
| You want one ticket fully merged before the next starts | You want to maximise throughput per scan tick |

## Supported AI agents

Set `LOOP_AGENT` in `loop.env`:

| `LOOP_AGENT` | CLI | Notes |
|---|---|---|
| `claude` (default) | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | First-class support; default model `sonnet`. |
| `codex` | OpenAI Codex CLI | |
| `gemini` | Google Gemini CLI | |
| `aider` | [Aider](https://aider.chat) | |
| `custom` | `LOOP_AGENT_CMD=<path>` | Roll your own — Loop pipes the prompt to stdin. |

## Architecture

Single scanner process polls GitHub every 5 minutes across all configured
projects. For each project, it asks the active workflow which labels to
poll, then dispatches events to handlers. Handlers acquire a per-project
lock, invoke the AI agent in a worktree, swap labels, exit. The
reconciler runs every 15 minutes to fix drift.

See [`docs/architecture.md`](docs/architecture.md) for the full diagram
and component breakdown.

## Security model

Loop is a single-machine automation tool — it runs the AI agent's code
on your machine, with your shell, and your `gh` credentials. Treat it
accordingly:

- **Pipeline labels are collaborator-only.** Anyone with write access to
  the repo can apply `plan`, `needs-qa`, etc. and trigger the pipeline.
  External users cannot.
- **Fork PRs are gated.** `qa-handler` refuses to run a project's
  `validation_cmd` against external-fork PR code unless a maintainer
  applies the `safe-to-test` label first.
- **Branch protection is required for production repos.** Configure
  `require code-owner approval` on `main` so even the operator's own
  PRs need a CODEOWNERS-listed reviewer.

See [`docs/security-model.md`](docs/security-model.md).

## Status check

Get a one-shot runtime health summary of the running pipeline:

```bash
./scripts/status.sh
```

Example output:

```
loop status — 2026-05-09 14:22:11

scanner              OK       (PID 60401, last tick 4m12s ago, interval 30m)
orchestrator         --       (LOOP_ORCHESTRATOR not set)
event-queue          --       (LOOP_EVENT_QUEUE_URL not set)
retry-counters       OK
  loop-monitor#119 (2/2 — needs-clarification)
active-handlers      OK
  PO PID 9821 (started 1m38s ago)
recent-failures      OK       (none in last 24h)
```

Machine-readable output:

```bash
./scripts/status.sh --json
# {"status":"ok","checks":{...},"retry_counters":[...],"active_handlers":[...],"recent_failures":[...]}
```

Exit codes: `0` = all OK, `2` = any DEGRADED, `1` = any FAIL.

> **Note:** `./install.sh status` is the install-time variant that checks env
> files, agent CLI availability, and `gh` auth. `scripts/status.sh` is the
> runtime variant that checks live pipeline state.

## Recovery

When a ticket ends up in a confused label state (mis-labelled after a partial
mass-merge, stuck handler left a bad label, etc.) use `scripts/loop-recover.sh`
to roll it back to a specific pipeline stage without hand-editing labels.

### Usage

```bash
scripts/loop-recover.sh <issue-or-pr-number> [--slug <slug>] [--to-stage <stage>] [--dry-run]
```

| Flag | Description |
|---|---|
| `<number>` | Issue or PR number to recover |
| `--slug <slug>` | Project slug from `config/projects.yaml` (required when multiple projects are configured) |
| `--to-stage <stage>` | Force the ticket to a specific stage: `po`, `dev`, `review`, `qa`, or `merge` |
| `--dry-run` | Print planned label add/remove and comment without mutating GitHub |

### Auto-detection (without `--to-stage`)

Without `--to-stage`, the script reads the event log at `$LOOP_MONITOR_LOG`
(defaults to `$LOOP_LOG_DIR/loop-monitor-events.jsonl`), finds the most
recent `*_done` event for the ticket, and computes the stage to restore:

| Last event | Restored stage | Label applied |
|---|---|---|
| `po_done` | `dev` | `needs-dev` |
| `dev_done` | `review` | `needs-review` |
| `review_done` | `qa` | `needs-qa` |
| `qa_done` | `merge` | `qa-pass` |

If no matching event exists, the script exits with a message asking you to
use `--to-stage` explicitly.

Set `LOOP_MONITOR_LOG` in `loop.env` to the path where your loop-monitor
instance (or a log shipper) writes its JSONL event stream.

### Examples

```bash
# Preview what would happen without changing anything:
scripts/loop-recover.sh 123 --slug myapp --dry-run

# Auto-detect last known-good stage and restore:
scripts/loop-recover.sh 123 --slug myapp

# Force ticket #456 to the qa stage regardless of event history:
scripts/loop-recover.sh 456 --slug myapp --to-stage qa

# Single-project setup — slug auto-detected:
scripts/loop-recover.sh 78 --to-stage dev
```

### Behaviour

- Removes all pipeline-stage labels from the ticket, then adds the target
  stage's trigger label.
- Posts a comment explaining the rollback (target stage, reason,
  operator-invoked).
- **Idempotent:** running the same command twice produces the same end state
  and posts at most one new comment per run (skipped when the last comment
  already contains the recovery marker).
- Labels only — no branch state, commits, or PRs are modified.

## Development

```bash
# Lint
bash -n lib/*.sh scripts/*.sh scanner/*.sh install.sh
shellcheck -S warning lib/*.sh scripts/*.sh scanner/*.sh install.sh

# Tests
bats tests/

# Validate workflow YAML files
./scripts/validate-workflow.sh
```

## Versioning

Loop adheres to [Semantic Versioning](https://semver.org). Pre-1.0,
MINOR releases may include breaking schema/env changes; each such
release documents the breakage in [CHANGELOG.md](CHANGELOG.md) with a
migration recipe. Post-1.0, strict semver: only MAJOR breaks documented
contracts.

The bounty event API between Loop and loop-monitor is independently
versioned (currently `1.0`).

## Status

`v0.2.0` — production-tested across multiple repos. Introduces four-phase
smart QA (AC verification, targeted test creation, module regression,
`validation_cmd`), 3-command onboarding with agent auto-detect, and
automated release PRs with tag + publish on merge. The pipeline,
workflow-as-config, and the versioned bounty API are first-class
commitments going forward.

[Roadmap](ROADMAP.md) tracks what's next: spec-blind validator stage,
domain specialist agents (frontend / backend / data / devops), expanded
backend coverage.

## Contributing

External contributions welcome. PRs require an approval from a
[CODEOWNERS](.github/CODEOWNERS)-listed reviewer before merging. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE).
