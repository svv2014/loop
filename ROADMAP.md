# Loop roadmap

What's coming. Issues drive the actual work; this doc reflects intent.

## Shipped — v0.1.0 (initial public release)

- Workflow-as-config (per-project pipelines via YAML)
- Versioning baked in (semver core, integer schema versions, semver
  bounty API)
- 24/7 autonomous polling (launchd / cron)
- Multi-project orchestration with per-project locks + `pipeline_slots`
- Multi-agent dispatch (claude / codex / gemini / aider / custom)
- Backend abstraction (github / gitlab / jira-gitlab)
- Bounty + judge layer via [loop-monitor](https://github.com/svv2014/loop-monitor)
- Six pipeline handlers: po, dev, dev-rework, review, qa, merge
- Reconciler housekeeping with dependency-unblock parser

## Shipped — v0.4.0 (self-correcting pipeline, 2026-05-10)

Made the autonomous pipeline self-correcting across the full life of a
ticket rather than relying on operator intervention when a stage failed.

- `loop_gh_issues_with_label` filters PRs out of issue-list results —
  single fix that unblocked multi-week stalled pipelines (#266)
- Untracked-data fail-fast classifier + `dev.worktree_extra_paths`
  per-project escape hatch (#265)
- Auto-`needs-rework` on red CI past threshold (#272); deterministic
  `CHANGES_REQUESTED → needs-rework` sync from review-handler (#269)
- Dev-rework prompt reads `statusCheckRollup` + `gh run view
  --log-failed` so agents fix lint failures alongside review feedback
  (#273); validation-cmd discovery from `.github/workflows/`,
  `package.json`, `Makefile`, `pyproject.toml`, `pre-commit-config.yaml`
  rather than a static `DEV_VALIDATION_CMD` (#274)
- `scripts/status.sh` one-shot health summary (#252); budget counter
  moved off `/tmp` so a reboot no longer resets the day's tally (#271)

## Shipped — v0.5.0 (security + self-convergence, 2026-05-14)

See [CHANGELOG.md](CHANGELOG.md) for the full entry. Headlines:

- **External-PR review-only path** and **`safe-to-test` gate** before
  any QA `validation_cmd` runs on fork PR code (#355, #372)
- **Delimited-untrust wrapper** for every text surface that reaches an
  agent prompt (#375); **trusted-author comment filter** (#331);
  **fork auto-merge disabled** (#338); **`validation_cmd`
  dangerous-pattern guard** (#351)
- **Reconciler self-convergence**: auto-promote green-CI PRs (#282),
  auto-rebase on base-move with configurable `LOOP_BRANCH_PATTERN`
  (#283, #380), label-set convergence (#288), orphan-issue auto-PO
  (#286), tracker auto-close (#290), review-handler stuck-state sweep
  (#330), DIRTY rework escalation (#329), diff-aware QA baseline (#328)
- **SQLite jobs queue scaffolding** as additive groundwork for
  replacing label-state + /tmp-lock concurrency (#353, #369, #373,
  #374)
- **`loop:stage:*` label namespace** with reconciler sync (#332)
- **Scanner serial mode + priority pick order** (#285); per-stage
  handler emit cap (#367); PO parse/decision migrated to Python (#339)
- **`scripts/loop-recover.sh`** operator rollback command (#340);
  structured `failure_reason` on `*_failed` events (#308); judge
  start/done bounty events (#370); prompt-injection defenses
  documented in `docs/security-model.md` (#368)

## v0.5.x — incremental polish (open)

- Demo GIF in README hero (catch one during a busy pipeline window)
- Loop-monitor dashboard screenshot in README
- Mermaid label-state-machine diagram in `docs/architecture.md`
- One-line install script (`curl … | bash`)
- Issue-label coverage audit between repo + active workflow

## v0.6.0 — quality gates (next)

The two biggest remaining capability gaps versus competing projects are
quality and specialization:

- **Spec-blind validator stage** — a separate AI agent that reads the
  ticket's `## Acceptance Criteria` + the merged-PR diff (not the
  implementation prompt or PR description) and verdicts each AC as
  pass/fail/unclear. New `spec-validator.sh` handler between QA and
  merge. Workflow opt-in (default-off) to start.
- **Reconciler unblock for cross-repo deps** — currently single-repo;
  extend to `org/other-repo#N` references where the reconciler can
  also read merged status of cross-repo deps.
- **Auto-revoke `safe-to-test` on PR head change** — close the loophole
  documented in `docs/security-model.md` where a contributor can land
  the label on a clean diff then push malware.
- **Mandatory `ALLOWED_AUTHORS` at scanner startup** (#346) — refuse to
  start without an explicit allow-list or explicit opt-out env var.

## v0.7.0 — specialist agents

Domain-specialized handlers routed by label or filepath analysis:

- `frontend` — UI/UX, components, styling, design tokens
- `backend` — APIs, business logic, DB queries
- `data` — migrations, schemas, ETL pipelines
- `devops` — CI/CD, infra-as-code, deploys
- `designer` — visual standards, illustrations, design assets

Per-role prompts in `prompts/<role>.md`, dispatcher logic in
`scripts/dev-handler.sh`. Generalist fallback preserved.

## v0.8.0 — operational improvements

- Container-based QA validation (sandbox `validation_cmd` execution)
- Multi-LLM-per-role tuning (e.g. Sonnet for backend, Haiku for docs)
- Wave-based parallel execution within one feature
- Built-in workflow validator step in CI
- Complete jobs-queue cutover — drop label-state + /tmp-lock
  concurrency in favour of the SQLite jobs table scaffolded in v0.5.0

## v1.0.0 — stable contracts

Promise of strict semver from this point. Pre-1.0 schemas, env vars,
CLI flags, log/lock dir layouts may change in MINOR releases; from
1.0, only MAJOR.

Targets:

- Workflow YAML schema v1 stable (no breaking changes)
- `projects.yaml` schema v1 stable
- `LOOP_*` env vars stable
- Bounty event API v1 stable

## Out of scope

These come up regularly but are not currently planned:

- **GUI / web UI for Loop core.** Use [loop-monitor](https://github.com/svv2014/loop-monitor)
  for visibility. CLI is the primary interface.
- **Hosted / SaaS version.** Loop is a single-machine tool by design.
- **Replacing the `gh` CLI dependency.** Too many edge cases to
  re-implement; `gh` is well-maintained and ubiquitous.
- **Forks of major AI agents.** Loop wraps existing CLIs; we don't
  build agent runtimes.

If your use case hits one of these, open an issue to discuss before
investing in code.
