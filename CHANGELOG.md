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


### Changed
- [LOOP-262] resolve rework trigger label per-project in pr-watchdog (#277)
- [LOOP-267] scanner: new `dev.pipeline_slots` gate (serial mode) +
  priority-aware pick order (`p0-critical` > `p1-high` > `p2-medium` >
  `p3-low` > unlabeled, then by number ascending), applied at every stage
- [LOOP-302] eliminate N+1 gh API calls in loop_gh_issues_with_label (#341)
## [0.4.0] - 2026-05-10

A 12-PR batch focused on making the autonomous pipeline self-correcting
across the full life of a ticket — root-causing the bugs that caused
the loop-monitor migration to stall for weeks, and giving handlers the
context they need to fix their own failures rather than retry-burn.

### Fixed — root-cause unblockers
- **#266** `loop_gh_issues_with_label` filters PRs out of \`gh issue list\`
  results. GitHub treats PRs as a kind of issue with shared number
  space; without the filter, a PR carrying \`needs-dev\` was emitted as
  a \`loop.dev_issue\` event with a PR-shaped payload (\`pr_number\` not
  \`issue_number\`), the event router's interpolator left \`{payload.issue_number}\`
  as a literal string, and dev-handler bailed on the resulting nonsense.
  This single fix unblocked the dependent project's entire pipeline (stalled 17 days).
- **#243** po-handler belt-and-braces guard recognises \`needs-dev\` (was
  only checking the deprecated synonym). Eliminates a silent skip path.
- **#239** \`_dedup_key\` portability: replace \`md5sum\` with a fallback
  chain that includes \`md5 -q\` for macOS hosts.
- **#241** Remove stale \`eval\`-based \`loop_notify\` from \`lib/env.sh\`
  (shell-injection vector when \`LOOP_NOTIFY\` contained metacharacters).

### Added — failure handling
- **#265** Untracked-data fail-fast classifier + opt-in
  \`dev.worktree_extra_paths\` per project. When the dev agent reports
  a missing file that looks like ML training data / model checkpoints
  (\`.npy\`/\`.pt\`/\`.ckpt\`/\`.h5\`/\`.parquet\`/\`.pkl\` extensions or
  \`/data/\`/\`/models/\`/\`/checkpoints/\` path hints), the issue is
  labelled \`blocked\` immediately with an actionable explanation
  instead of burning the retry counter.
- **#272** Reconciler auto-applies \`needs-rework\` when a loop-opened
  PR has red CI for >threshold. Stale PRs no longer sit waiting for
  a manual relabel.
- **#269** review-handler deterministic \`CHANGES_REQUESTED → needs-rework\`
  sync. Closes the lifecycle hole where review denied and nothing
  triggered the next move.

### Added — operability
- **#252** \`scripts/status.sh\` — one-shot health summary (scanner,
  orchestrator, event-queue, retry counters, active handlers, recent
  failures). \`--json\` flag for programmatic consumption.
- **#271** Daily-budget counter moved from \`/tmp/\` to
  \`\${LOOP_LOG_DIR}/budget/\`. Persistent across OS reboots; previously
  a mid-day reboot silently reset the day's tally to zero.

### Changed — agent contract
- **#273** dev-rework prompt now reads CI status (\`statusCheckRollup\`)
  and fetches the actual log of each FAILURE check via \`gh run view --log-failed\`.
  Agents no longer "fix" reviews while ignoring the lint output.
- **#274** dev-handler + dev-rework prompts discover validation
  commands by inspecting \`.github/workflows/\`, \`package.json\`,
  \`Makefile\`, \`pyproject.toml\`, \`pre-commit-config.yaml\` — not from
  a static \`DEV_VALIDATION_CMD\` operators have to keep in sync. The
  string is preserved as a hint but the discovered set is authoritative.
- **#275** Captured \`REBASE_CONFLICTS\` filenames threaded into the
  rework prompt so the agent goes straight to the conflicting files
  with a "resolve semantically — do not blindly --theirs/--ours"
  instruction. Saves a discovery roundtrip per rework.

### Migration

From v0.3.0:
1. \`git pull\` and restart scanner: \`launchctl kickstart -k gui/$(id -u)/com.user.loop-scanner\`.
2. **Optional but recommended:** delete \`/tmp/loop-budget-*.counter\`
   files; the new persistent location at \`\${LOOP_LOG_DIR}/budget/\`
   takes over fresh.
3. **For projects with gitignored runtime files** (ML data, models):
   add \`dev.worktree_extra_paths\` to the project entry in
   \`config/projects.yaml\` to pre-symlink them into worker worktrees.
4. **Operators relying on \`DEV_VALIDATION_CMD\`:** keep it as a hint
   if you want; it still works, but the agent now discovers and runs
   the CI-equivalent set on its own. Drift becomes self-healing.

## [0.3.0] - 2026-05-09

A two-week batch focused on operational stability: every cascading
failure mode observed in production has either an automated mitigation,
a budget guard, or a documented recovery recipe. Pipeline now drains
backlogs autonomously and reports its own health.

### Pipeline stability batch (2026-05-08 / 2026-05-09)

#### Added — autonomous recovery
- [#244] Scanner caps non-dev pipeline stages at N concurrent emits per
  tick (PO, senior-dev, review, QA, merge, rework). Default 1,
  configurable per-project via `pipeline.max_concurrent_handlers` or
  globally via `max_concurrent_handlers`. Closes the unbounded fan-out
  that produced 12 parallel PO runs from a single backlog.
- [#254] PR auto-rework watchdog (`scripts/pr-watchdog.sh`) — an
  independent 15-min poll loop that labels stale loop-authored PRs
  `needs-rework` so dev-rework picks them up. Catches PRs sitting in
  `mergeable=CONFLICTING` (default 30 min grace) or `ci=FAILURE`
  (default 60 min grace). Tunable via `LOOP_WATCHDOG_CONFLICT_GRACE` /
  `LOOP_WATCHDOG_CI_GRACE`. Idempotent — never re-labels a PR already
  in `needs-rework` / `blocked` / `needs-clarification`.
- [#255] Daily handler-time budget (`LOOP_DAILY_HANDLER_BUDGET_SECONDS`).
  Soft cap that stops the scanner from emitting new work once today's
  cumulative handler wall-clock seconds reach the cap. Counter at
  `/tmp/loop-budget-YYYYMMDD.counter` rolls over automatically. Single
  env var, opt-in, no behavior change when unset.
- [#257] `install.sh --bootstrap` registers the watchdog plist
  alongside scanner / reconciler / digest. Standard `__VAR__`
  placeholders. Idempotent.

#### Added — failure classification + diagnosis
- [#238] PO runs on opus 4.7 by default via per-call orchestrator model
  override. Worker continues on the orchestrator-config default
  (sonnet) for dev/qa work. Set `LOOP_PO_MODEL` to override.
- [#245, #253] Failure classifier (`lib/failure_classifier.sh`)
  distinguishes transient infra failures (Python tracebacks, network
  errors, orchestrator import failures) from genuine spec ambiguity.
  Transient → backoff retry without burning the counter. Permanent →
  existing path to `needs-clarification`.
- [#250] PO retry counter auto-clears when the issue's
  `needs-clarification` label is removed (re-queue detected). Fixes
  the stale-counter trap where re-queued tickets bounced back instantly.
- [#251] `needs-clarification` comments now include redacted log
  excerpt + run ID + model used. No more "see the log" black box.

#### Added — operations
- [#256] `docs/operations.md` — every state file, every recovery
  recipe, copy-pasteable commands. Replaces ad-hoc grep-the-codebase
  triage.
- [#240] `dev-handler` EXIT trap correctly restores the resolved
  trigger label (vs the original env-passed one) when killed mid-flight.
- [#242] Custom-agent invocation no longer evaluates strings via
  `eval` — closes a shell-injection vector if a custom command
  contains user-supplied content.

#### Documented
- `loop.env.example` documents `LOOP_DAILY_HANDLER_BUDGET_SECONDS`,
  `LOOP_WATCHDOG_CONFLICT_GRACE`, `LOOP_WATCHDOG_CI_GRACE` under a
  new "Resource governance" section.

### Reconciler stability + observability batch (2026-05-01 / 2026-05-02)

A multi-PR sweep addressing root causes of label ping-pong, set -e
foot-guns, vocab-migration drift, and lack of pathology visibility.
The pipeline became dramatically more debuggable and self-healing in
this batch.

#### Fixed (writer correctness)
- [#204] `_autopull_loop` returns 0 when no fast-forward — set -e was
  killing the entire reconciler whenever no merge happened upstream.
- [#206] `reconcile_alias_renames` is workflow-aware — stopped
  stripping live trigger labels from `workflow: current` projects
  (4 projects affected: ppl-study, NTC, vrefm-classifier, pa-scanner).
- [#207, #208] `LOOP_PIPELINE_LABELS` consolidated into
  `lib/labels.sh::LOOP_PIPELINE_TRACKED_LABELS`. Single source of
  truth so vocab additions can't drift.
- [#213] `LOOP_REQUIRED_LABELS` includes the canonical `needs-po`,
  `in-po`, `needs-dev`, `in-dev` so freshly-onboarded repos bootstrap
  them cleanly.
- [#216] `merge-handler.sh` recognises `Fixes` / `Resolves` keywords
  alongside `Closes` (matches GitHub's native auto-close vocabulary).
- [#217] `_rename_label_on_target` is add-then-remove with early-
  return on add-failure. No more label-less tickets when API flakes
  mid-rename.
- [#220] dev-handler strips the issue's stage trigger after opening a
  closing PR via `loop_strip_pipeline_labels`; `reconcile_lost_issues`
  skips Signal when an open PR closes the issue.
- [#221] `reconcile_stale_base` ends with explicit `return 0`. Static
  scan in `tests/reconciler-set-e-audit.bats` regression-guards every
  `reconcile_*` / `recovery_*` function against the same trailing-
  conditional `set -e` foot-gun.
- [#222] `reconcile_synonym_labels` + `reconcile_alias_renames` →
  thin wrappers over a shared `_reconcile_label_renames` helper. Net
  49-line reduction; alias renamer also gains the atomic ordering
  from #217 as a side effect.
- [#225] PO Path D enforces a hard cap (`LOOP_PO_MAX_CHILDREN`,
  default 4) and detects refactor-class epics (title/body keywords)
  so their children are chained via `Depends on #N` for serial
  processing — eliminates the merge-conflict storms on multi-file
  refactors.

#### Added (observability)
- [#214] `reconcile_lost_issues` is observational only — Signal +
  per-ticket cool-down, no auto-mutation. Eliminates the ping-pong
  with `reconcile_alias_renames` that produced 41+ comments on a
  single ticket.
- [#218] `scanner.sh` installs a SIGHUP trap that reopens stdout/
  stderr against `LOG_FILE`. Survives `logrotate copytruncate` /
  `newsyslog R` without going silent.
- [#223] `reconcile_anomalies` mines the reconciler log for tickets
  touched more than threshold times within a window. Configurable
  threshold (default 4), window (default 1h), cool-down (default 24h).
- [#224] `reconcile_agent_distress` scans recent agent-authored
  comments for narrative-pathology phrases (`reconciler keeps`,
  `human action required`, `no progress after N cycles`). Built-in
  phrase list overridable via `LOOP_DISTRESS_PHRASES_FILE`.

#### Refactored
- [#209, #219] `loop_label_is_trigger <slug> <kind> <label>` extracted
  to `lib/workflow.sh` with per-(slug, kind) caching. Replaces two
  duplicate copies of the gate in the reconciler.

#### Tests added
- 8 new bats files: `lost-issues-observational`, `rename-label-atomic`,
  `label-is-trigger`, `scanner-log-sighup`, `reconciler-set-e-audit`,
  `anomaly-detector`, `agent-distress`, `po-decomposition-instructions`.
  39+ new cases covering writer contracts, observational invariants,
  cool-downs, and prompt-text regression.


### Changed
- [LOOP-160] feat: add reconcile-on-startup entrypoint (#171)
- [LOOP-161] reconcile-on-startup: GC orphaned /tmp/loop-worktree-* dirs (#172)
- [LOOP-164] reconciler: surface author-gated tickets via digest + status counter (#173)
- [LOOP-163] author-gate: honour operator-approved label as per-ticket override (#177)
- [LOOP-169] workflow YAMLs (`default`, `minimal`, `docs-only`) now reference
  only the canonical label vocabulary defined in `lib/labels.sh`
  (`needs-po`, `in-po`, `needs-dev`, `in-dev`, `needs-review`, `in-review`,
  `needs-qa`, `qa-pass`, `qa-fail`, `blocked`, `done`). Deprecated synonyms
  (`po-review`, `dev`, `plan`, `needs-rework`, `changes-requested`,
  `merge-ready`, `ready-for-qa`, `review-pending`, `in-rework`,
  `in-progress`) are no longer valid trigger names in the shipped workflows.
- [LOOP-169] new `docs/labels.md` documents the canonical taxonomy, the
  operator-set-vs-agent-set split, and the deprecated-alias mapping.

- [LOOP-234] fix EXIT trap in dev-handler to restore resolved trigger label (#240)
- [LOOP-247] include redacted error context in needs-clarification comment (#251)
### Migration
- Existing tickets carrying deprecated labels are auto-renamed by
  `reconcile_alias_renames` (shipped in #168) on the next reconciler tick;
  per-project GitHub-side cleanup of the deprecated labels themselves is
  handled by `scripts/migrate-labels.sh` (#170). No operator action is
  required for projects on the shipped workflows.
## [0.2.0] - 2026-04-29

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
- [LOOP-90] add LOOP_SENIOR_MODEL and loop_run_senior_agent() helper (#118)
- [LOOP-88] PO handler: preserve original issue body under '## Original brief (preserved by PO)' marker on issue expand (#119)
- [LOOP-43] add `scripts/auto-release-pr.sh`: idempotent release PR + merge-handler tag/publish + semver labels in bootstrap (#120)

- [LOOP-96] Wolf mascot — loup/loop dual identity branding (#125)
- [LOOP-123] simplify README Install section to 3-command Claude+GitHub quickstart (#126)
- [LOOP-124] rewrite quick-start.md: Claude+GitHub MVP in 5 steps (#130)
- [LOOP-132] fix docs: replace plan with po-review/dev as pipeline entry points (#134)
- [LOOP-137] fix qa-handler: qa-failed → qa-fail label name (#138)
- [LOOP-131] resolve workflow labels in all handler prompts via loop_label_for (#135)
- [LOOP-133] 3-command onboarding: agent auto-detect + smoke test + loop status (#145)
- [LOOP-136] replace rubber-stamp QA with four-phase smart verification agent (#146)
### Added
- `tests/po-body-preserve.bats`: 5 tests for the original-brief extraction logic
- `scripts/auto-release-pr.sh`: new script that maintains one open `chore: release vX.Y.Z` PR; idempotent, computes next version from `semver:*` labels, promotes CHANGELOG, supports `--dry-run`

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
