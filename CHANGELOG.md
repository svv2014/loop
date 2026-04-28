# Changelog

All notable changes to Loop are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Loop adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0: MINOR releases may include breaking schema or env-var changes;
each such release documents the breakage and a migration recipe under
its **Changed** or **Removed** section. After 1.0, strict semver: only
MAJOR releases break documented contracts (workflow schema, env vars,
projects.yaml schema, bounty event API, CLI flags, lock dir, log dir).

## [Unreleased]

### Fixed
- Resolved unmerged git conflict markers in `scripts/review-handler.sh`,
  `scripts/po-handler.sh`, and `scripts/dev-rework-handler.sh` left from
  the LOOP-29 merge; all three now correctly use `backend_comment_*` (no
  direct `gh` bypass) and post a short safe message (no internal prompt
  content leaked into public comments).
- Added `EXIT`/`TERM`/`INT` trap to `scripts/dev-handler.sh` and
  `scripts/po-handler.sh`: if a handler is killed or `set -e` fires between
  claiming `in-progress` and the explicit cleanup paths, the issue is
  automatically restored to `dev` (or `po-review`) so the scanner re-queues
  it on the next tick instead of leaving it permanently orphaned.
- Added reconciler Check 10 (`reconcile_orphaned_in_progress`): every 15 min
  the reconciler now resets any `in-progress` issue whose handler lock has no
  live PID (covers SIGKILL and machine reboots that the EXIT trap cannot
  catch).

### Changed
- [LOOP-29] Fix backend abstraction bypass and loop_run_agent cwd handling (#52)
- Draft: [LOOP-68] bounty: add loop_id field to every event payload (#77)
- Draft: [LOOP-30] add lib/cli-hint.sh and inject glab hint into handler prompts (#80)
- Draft: [LOOP-89] Add daily operator digest of stuck pipeline items (#94)
- Draft: [LOOP-87] detect draft PRs in review-handler and qa-handler (#95)
## [0.1.0] - 2026-04-27

Initial public release. Loop is the public rebrand of a prior internal
codebase, with fresh-start git history and three new architectural
commitments: workflow-as-config, semver-from-day-1, and a versioned
bounty event API.

### Added

- **Workflow-as-config** — pipeline stages and the labels that drive them
  are defined per-project in `config/workflows/<name>.yaml`. Three starter
  workflows ship: `default` (clean canonical labels), `minimal` (two-stage
  plan → merge, no review or QA), and `docs-only` (plan → review → merge,
  no QA gate). Operators can author their own workflow files. `current.yaml`
  is reserved as an operator-local gitignored file for legacy-label
  migration.
- **Per-project workflow + label overrides** — `config/projects.yaml` v1
  schema lets each project pick a workflow and override individual label
  names if needed.
- **Versioning** — `VERSION` file at repo root, surfaced via
  `lib/version.sh`. Scanner banner, `install.sh --version`, and bounty
  event payloads all carry the running version.
- **Bounty event API v1.0** — payload contract between Loop core and
  loop-monitor. Versioned with major.minor; monitor accepts `1.x` and
  rejects unsupported majors with HTTP 426.
- 24/7 autonomous polling — scanner runs via launchd (macOS) or cron
  (Linux); KeepAlive for the scanner, 15-min interval for the reconciler.
- Multi-project orchestration from a single install — one operator,
  many repos, per-project locks and `pipeline_slots` concurrency caps.
- Multi-agent CLI dispatch — `claude`, `codex`, `gemini`, `aider`, or
  custom via `LOOP_AGENT`.
- Backend abstraction (`lib/backends/`) — GitHub default, GitLab, and
  Jira-GitLab composite adapters available.
- Bounty + judge layer (companion: loop-monitor) — role-level points,
  AI judge verdicts, PR scorecard comments, leaderboard.
- Six pipeline handlers: `po-handler`, `dev-handler`, `dev-rework-handler`,
  `review-handler`, `qa-handler`, `merge-handler`.
- Reconciler housekeeping: duplicate PRs, orphaned claims, stale PRs,
  dependency unblock (parses `## Dependencies` bulleted sections),
  needs-clarification reminders, missing-label routing.
- Per-project advisory lock with TTL-based stale-lock stealing and
  configurable `pipeline_slots` PR concurrency cap.
- Bootstrap installer (`install.sh --bootstrap`) — checks tools, copies
  example configs, registers services, chmods scripts.
- OSS-readiness baseline: MIT LICENSE, CODEOWNERS, ROADMAP, CONTRIBUTING,
  SECURITY, ISSUE_TEMPLATE, PULL_REQUEST_TEMPLATE.

### Migration from a prior `asdlc` install

If you ran the prior internal codebase under the `asdlc` name, the
quick path:

1. Stop the old launchd services
2. Clone Loop: `git clone https://github.com/svv2014/loop.git`
3. Copy your `asdlc.env` to `loop.env` and rename keys: `sed -i'' -e
   's/^ASDLC_/LOOP_/g' loop.env`
4. Copy `config/projects.yaml` and add `version: 1` plus a `workflow:
   current` line under each project
5. Move logs: `mv ~/.asdlc ~/.loop`
6. Run `./install.sh --bootstrap`
7. Verify: `launchctl list | grep loop`; `tail -f
   ~/.loop/logs/loop-scanner.log`

[Unreleased]: https://github.com/svv2014/loop/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/svv2014/loop/releases/tag/v0.1.0
