# Workflow definitions

A **workflow** declares the pipeline stages, the labels that drive each
stage, and which handler script runs. Each project in
`config/projects.yaml` references a workflow by name, and may override
individual label names if its repo already uses different vocabulary.

This dir contains starter workflows. Operators can author their own.

## Files

| File | Purpose |
|---|---|
| `default.yaml` | Recommended for new repos. Clean canonical labels: `plan` / `needs-review` / `needs-qa` / `qa-pass` / `qa-fail`. |
| `current.yaml` | Legacy-vocabulary mirror. Uses `dev` instead of `plan`; matches the label set in svv2014 projects at v0.1.0 migration. |
| `minimal.yaml` | Two-stage pipeline (`plan → merge`). No review, no QA. Solo prototypes only. |

## Schema (v1)

```yaml
version: 1                    # integer; bumped on breaking schema change
name: default                 # workflow id; must match the filename
description: |                # free-text; surfaces in `loop --workflows`
  Standard plan → review → QA → merge pipeline.

# Polled on issues
issue_stages:
  - id: plan                  # stable identifier within the workflow
    trigger_label: plan       # label that, when applied, fires this stage
    handler: dev-handler      # base name of scripts/<handler>.sh
    on_done: needs-review     # label applied to PR (or issue) on success
    on_failed_after_max: blocked
    on_blocked: blocked       # only meaningful on po stage
    on_clarification: needs-clarification   # only meaningful on po stage

# Polled on PRs
pr_stages:
  - id: review
    trigger_label: needs-review
    handler: review-handler
    decisions:                # used by stages with binary outcomes
      approve: needs-qa
      reject: needs-rework

  - id: qa
    trigger_label: needs-qa
    handler: qa-handler
    on_pass: qa-pass
    on_fail: qa-fail

  - id: merge
    trigger_label: qa-pass
    handler: merge-handler
    on_done: done
```

### Required fields

- `version: 1`
- `name`
- At least one stage (anywhere in `issue_stages` or `pr_stages`)
- Each stage: `id`, `trigger_label`, `handler`

### Validation

```bash
./scripts/validate-workflow.sh config/workflows/default.yaml
# or:
source lib/workflow.sh
loop_workflow_validate config/workflows/default.yaml
```

The validator checks: schema version, name presence, stage required
fields, no duplicate `trigger_label` within a workflow, at least one
stage exists.

## Per-project overrides

In `config/projects.yaml`:

```yaml
projects:
  - name: My App
    slug: myapp
    repo: owner/my-app
    workflow: default                # which workflow file to use
    labels:                          # OPTIONAL — overrides for this repo
      plan: dev                      # this repo uses 'dev' instead of 'plan'
      qa-pass: approved              # different name for the merge gate
```

Overrides are sparse: include only the labels whose names differ from
the workflow's canonical vocabulary. The scanner and handlers do the
translation transparently.

## Authoring your own workflow

1. Copy `default.yaml` to `your-name.yaml` in this directory
2. Edit stages — add, remove, rename `trigger_label` values
3. Validate: `./scripts/validate-workflow.sh config/workflows/your-name.yaml`
4. Reference it: in `projects.yaml`, set `workflow: your-name`
5. Restart the scanner: `launchctl unload && launchctl load
   ~/Library/LaunchAgents/com.user.loop-scanner.plist`

Possible custom workflow shapes:

- **Strict**: add a `spec-validator` stage between `qa-pass` and `merge`
  (planned: see roadmap)
- **Docs-only**: drop the `qa` stage; merge after review
- **Compliance**: add a `security-audit` stage with required human
  approval before merge

## Operator-local workflows

Workflow files are not all meant to ship publicly. The repo ships
`default.yaml` and `minimal.yaml` as starters. Operator-specific workflows
(e.g., legacy-vocabulary mirrors, internal compliance pipelines) should
be **local-only**, not committed.

Two conventions for keeping a workflow local:

1. **Named files** — `config/workflows/current.yaml` is gitignored by default
   (reserved for the operator's "preserve existing in-flight vocabulary"
   workflow during a migration window).
2. **`*.local.yaml` glob** — any file matching `config/workflows/*.local.yaml`
   is gitignored. Use this for additional operator-specific workflows
   (e.g., `corp-compliance.local.yaml`).

Operator-local workflows reference the same schema (v1) as committed ones
and validate via `./scripts/validate-workflow.sh`.
