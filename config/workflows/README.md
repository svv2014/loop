# Workflow definitions

A **workflow** declares the pipeline stages, the labels that drive each
stage, and which handler script runs. Each project in
`config/projects.yaml` references a workflow by name, and may override
individual label names if its repo already uses different vocabulary.

This dir contains starter workflows. Operators can author their own.

## Files

| File | Ships? | Purpose |
|---|---|---|
| `default.yaml` | Yes | Recommended for new repos. Clean canonical labels: `plan` / `needs-review` / `needs-qa` / `qa-pass` / `qa-fail`. |
| `minimal.yaml` | Yes | Two-stage pipeline (`plan → merge`). No review, no QA. Solo prototypes only. |
| `docs-only.yaml` | Yes | Three-stage pipeline (`plan → review → merge`). No QA. For documentation and content-only PRs. |
| `current.yaml` | **No — gitignored** | Operator-local legacy-vocabulary mirror. Not committed to this repo. See [Operator-local workflows](#operator-local-workflows) and [docs/migration-from-asdlc.md](../../docs/migration-from-asdlc.md). |

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

The validator checks: schema version, `name` matches filename, stage
required fields, no duplicate `trigger_label` within a workflow, at
least one stage exists, and all transition targets reference known
labels (trigger labels declared in the file or terminal labels below).
Missing handler scripts produce a warning but do not cause validation
to fail.

## Canonical label set

These are the canonical label names used in `default.yaml`. Projects may
override any of them via the `labels:` map in `config/projects.yaml`.

**Issue labels** (drive `issue_stages`):

| Label | Role |
|---|---|
| `po-review` | PO expansion stage — turns a rough idea into a spec |
| `plan` | Dev implementation stage |
| `blocked` | Terminal: issue cannot proceed; human attention required |
| `needs-clarification` | Terminal: issue body is ambiguous; awaiting author reply |

**PR labels** (drive `pr_stages`):

| Label | Role |
|---|---|
| `needs-review` | Code review stage |
| `needs-rework` | Sent back to dev after review rejection |
| `needs-qa` | QA / automated test stage |
| `qa-pass` | QA passed; triggers merge |
| `qa-fail` | QA failed; triggers rework or close |
| `done` | Terminal: PR merged and issue closed |

**Terminal labels** (valid transition targets, never trigger a stage):
`done`, `blocked`, `needs-clarification`, `qa-fail`

## `current` workflow label vocabulary

`current.yaml` is the operator-local legacy-vocabulary mirror. It uses a
different set of label names from `default.yaml` to preserve in-flight
labels on repos that were already running under the original svv2014 label
scheme before Loop's `default` workflow was introduced.

**Pipeline flow:**

```
po-review (issue) → dev (issue) → review-pending (PR) → ready-for-qa (PR)
    → qa-pass / qa-fail (PR) → merge → done
```

**Issue labels:**

| Label | Role |
|---|---|
| `po-review` | PO expansion stage (same as `default`) |
| `dev` | Dev implementation stage (`plan` in `default`) |
| `blocked` | Terminal: issue cannot proceed |
| `needs-clarification` | Terminal: awaiting author reply |

**PR labels:**

| Label | Role |
|---|---|
| `review-pending` | Code review stage (`needs-review` in `default`) |
| `changes-requested` | Sent back to dev after review rejection (`needs-rework` in `default`) |
| `ready-for-qa` | QA / automated test stage (`needs-qa` in `default`) |
| `qa-pass` | QA passed; triggers merge (same as `default`) |
| `qa-fail` | QA failed; triggers rework or close (same as `default`) |
| `done` | Terminal: PR merged and issue closed (same as `default`) |

See [docs/migration-from-asdlc.md](../../docs/migration-from-asdlc.md) for a full
side-by-side mapping and instructions for creating your own `current.yaml`.

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
