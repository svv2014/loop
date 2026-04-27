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

## v0.1.x — incremental polish

- Demo GIF in README hero (catch one during a busy pipeline window)
- Loop-monitor dashboard screenshot in README
- Mermaid label-state-machine diagram in `docs/architecture.md`
- One-line install script (`curl … | bash`)
- Issue-label coverage audit between repo + active workflow
- Smaller follow-ups as they surface

## v0.2.0 — quality gates

The two biggest capability gaps versus competing projects are quality
and specialization:

- **Spec-blind validator stage** — a separate AI agent that reads the
  ticket's `## Acceptance Criteria` + the merged-PR diff (not the
  implementation prompt or PR description) and verdicts each AC as
  pass/fail/unclear. New `spec-validator.sh` handler between QA and
  merge. Workflow opt-in (default-off) to start.
- **Reconciler unblock for cross-section deps** — currently single-repo;
  extend to `org/other-repo#N` references where the reconciler can
  also read merged status of cross-repo deps.

## v0.3.0 — specialist agents

Domain-specialized handlers routed by label or filepath analysis:

- `frontend` — UI/UX, components, styling, design tokens
- `backend` — APIs, business logic, DB queries
- `data` — migrations, schemas, ETL pipelines
- `devops` — CI/CD, infra-as-code, deploys
- `designer` — visual standards, illustrations, design assets

Per-role prompts in `prompts/<role>.md`, dispatcher logic in
`scripts/dev-handler.sh`. Generalist fallback preserved.

## v0.4.0 — operational improvements

- Container-based QA validation (sandbox `validation_cmd` execution)
- Multi-LLM-per-role tuning (e.g. Sonnet for backend, Haiku for docs)
- Wave-based parallel execution within one feature
- Auto-revoke `safe-to-test` when PR head changes
- Built-in workflow validator step in CI

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
