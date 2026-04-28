# Migrating from the legacy label set to Loop workflows

This guide is for operators whose repos were already using the original
label vocabulary (sometimes called the "asdlc" or "svv2014" label set)
before Loop's `default` workflow was introduced. It explains how to keep
those existing labels working during a migration window using the
`current` workflow.

## Label mapping: `default` workflow vs `current` workflow

| Stage | `default` label | `current` label | Shared? |
|---|---|---|---|
| PO expansion (issue) | `po-review` | `po-review` | Yes |
| Dev implementation (issue) | `plan` | `dev` | No |
| Code review (PR) | `needs-review` | `review-pending` | No |
| Sent back for rework (PR) | `needs-rework` | `changes-requested` | No |
| QA / automated tests (PR) | `needs-qa` | `ready-for-qa` | No |
| QA passed / merge gate (PR) | `qa-pass` | `qa-pass` | Yes |
| QA failed (PR) | `qa-fail` | `qa-fail` | Yes |
| Closed / shipped (PR+issue) | `done` | `done` | Yes |
| Blocked — needs human (issue) | `blocked` | `blocked` | Yes |
| Awaiting author reply (issue) | `needs-clarification` | `needs-clarification` | Yes |

In short: four labels differ (`plan`→`dev`, `needs-review`→`review-pending`,
`needs-rework`→`changes-requested`, `needs-qa`→`ready-for-qa`); everything
else is identical.

## Creating your `current.yaml`

`config/workflows/current.yaml` is **gitignored by design** — it is
operator-local and must not be committed to the Loop repo. Create it on
each machine where the Loop scanner runs.

Copy the schema below into `config/workflows/current.yaml`:

```yaml
# Operator-local workflow — DO NOT COMMIT.
# Mirrors the legacy svv2014 label vocabulary for in-flight repos.
# See docs/migration-from-asdlc.md for context.

version: 1
name: current
description: |
  Legacy-vocabulary mirror. Preserves in-flight labels for repos already
  using the original label set before Loop's default workflow landed.
  Pipeline: po-review → dev → review-pending → ready-for-qa → qa-pass/qa-fail → done.

issue_stages:
  - id: po
    trigger_label: po-review
    handler: po-handler
    on_done: dev
    on_blocked: blocked
    on_clarification: needs-clarification

  - id: dev
    trigger_label: dev
    handler: dev-handler
    on_done: review-pending
    on_failed_after_max: blocked

pr_stages:
  - id: review
    trigger_label: review-pending
    handler: review-handler
    decisions:
      approve: ready-for-qa
      reject: changes-requested

  - id: rework
    trigger_label: changes-requested
    handler: dev-rework-handler
    on_done: review-pending
    on_failed_after_max: blocked

  - id: qa
    trigger_label: ready-for-qa
    handler: qa-handler
    on_pass: qa-pass
    on_fail: qa-fail

  - id: merge
    trigger_label: qa-pass
    handler: merge-handler
    on_done: done

  - id: qa-rework
    trigger_label: qa-fail
    handler: dev-rework-handler
    on_done: review-pending
    on_failed_after_max: blocked
```

Validate after saving:

```bash
./scripts/validate-workflow.sh config/workflows/current.yaml
```

## Opting a project into the `current` workflow

In `config/projects.yaml`, set `workflow: current` for any project whose
repo uses the legacy label vocabulary:

```yaml
projects:
  - name: My Legacy Repo
    slug: myrepo
    repo: owner/my-repo
    workflow: current
```

No `labels:` overrides are needed — the `current` workflow already uses
the legacy vocabulary as its canonical names.

## Migration path to `default`

When you are ready to cut over a repo to the `default` workflow:

1. Wait until all in-flight issues and PRs are closed or relabelled.
2. Rename the legacy labels in GitHub (repo Settings → Labels) to the
   `default` names: `dev`→`plan`, `review-pending`→`needs-review`,
   `changes-requested`→`needs-rework`, `ready-for-qa`→`needs-qa`.
3. Change `workflow: current` to `workflow: default` in `config/projects.yaml`.
4. Restart the scanner.

This is an operator task and does not require changes to the Loop repo.
