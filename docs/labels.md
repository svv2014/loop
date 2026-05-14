# Labels

Loop drives every issue and PR through a label state machine. The vocabulary
is small and intentionally so: every state has exactly one canonical name
defined in `lib/labels.sh` (`LOOP_CANONICAL_LABELS`). Workflow YAMLs in
`config/workflows/` reference only canonical names; older synonyms still in
the wild are auto-renamed by the reconciler on its next tick.

## Label namespaces

All Loop-owned labels live under a `loop:` prefix, split across four
sub-namespaces:

| Sub-namespace | Set by | Purpose |
|---|---|---|
| `loop:action:*` | Operator | Queue-trigger labels — apply to start a pipeline stage |
| `loop:active:*` | Agent | Claim labels — agent sets while handling the work |
| `loop:result:*` | Agent / operator | Outcome labels — terminal or transition signals |
| `loop:stage:*` | Reconciler | Derived stage markers — read-only, never trigger handlers |

## Canonical taxonomy

Fifteen labels cover every Loop pipeline state.

### `loop:action:*` — operator-set queue triggers

| Canonical label | Object | Role |
|---|---|---|
| `loop:action:po` | issue | Rough idea — PO handler expands into a full spec |
| `loop:action:dev` | issue / PR | Issue: queued for implementation. PR: queued for rework after review rejection. |
| `loop:action:review` | PR | PR is open and waiting for code review |
| `loop:action:qa` | PR | Review approved; queued for the QA gate |

### `loop:active:*` — agent-set claim labels

| Canonical label | Object | Role |
|---|---|---|
| `loop:active:po` | issue | PO handler has claimed the issue and is expanding the spec |
| `loop:active:dev` | issue / PR | Dev or rework handler has claimed the work |
| `loop:active:review` | PR | Review handler has claimed the PR |

### `loop:result:*` — agent-set outcome labels

| Canonical label | Object | Role |
|---|---|---|
| `loop:result:qa-pass` | PR | QA passed; queued for merge. Also the "approved, ready to merge" signal in docs-only workflow. |
| `loop:result:qa-fail` | PR | QA failed; queued for dev rework |
| `loop:result:blocked` | issue / PR | Terminal until a human intervenes |
| `loop:result:done` | issue / PR | Terminal — issue closed or PR merged |

### `loop:stage:*` — reconciler-derived stage markers

Stage labels are maintained automatically by the reconciler. They are
read-only from the handler perspective — handlers must not set or strip them.
See the [Stage labels section in README.md](../README.md#label-namespaces) for
the full mapping.

A handful of orthogonal labels (`needs-clarification`, `safe-to-test`, plus
priority / semver / epic markers) are preserved as-is — they coexist with the
state-machine labels and are never stripped on terminal transitions other
than the strict pipeline-stage set in `LOOP_PIPELINE_STAGE_LABELS`.

## Operator-set vs agent-set

The taxonomy splits cleanly:

- **Operator-set**: `loop:action:po`, `loop:action:dev` on issues,
  `loop:result:blocked` (when humans intervene), occasional
  `loop:result:qa-pass` to force-merge.
- **Agent-set**: every `loop:active:*` claim label, every `loop:action:*`
  transition that a handler emits on completion (`loop:action:review`,
  `loop:action:qa`), every terminal outcome (`loop:result:qa-pass`,
  `loop:result:qa-fail`, `loop:result:done`), and `loop:result:blocked`
  after max retries.

This split exists so handlers can race safely: only one party owns a given
transition. Operators set the queue labels (`loop:action:po` /
`loop:action:dev`) and nothing else; agents own the in-flight (`loop:active:*`)
and outcome states.

## Deprecated alias table

These names are still recognised in the wild — `lib/labels.sh::LOOP_DEPRECATED_ALIAS_MAP`
is the source of truth, and `reconcile_alias_renames` rewrites them on every
reconciler tick. New code, new workflow YAMLs, and new handlers must reference
the canonical name only. Legacy names still work during the transition; the
reconciler rewrites them on its next sweep.

| Deprecated alias | Canonical replacement | Notes |
|---|---|---|
| `needs-po` | `loop:action:po` | Previous canonical name before namespace migration |
| `in-po` | `loop:active:po` | Previous claim label for PO stage |
| `needs-dev` | `loop:action:dev` | Previous canonical name before namespace migration |
| `in-dev` | `loop:active:dev` | Previous claim label for dev stage |
| `needs-review` | `loop:action:review` | Previous canonical name before namespace migration |
| `in-review` | `loop:active:review` | Previous claim label for review stage |
| `needs-qa` | `loop:action:qa` | Previous canonical name before namespace migration |
| `qa-pass` | `loop:result:qa-pass` | Previous canonical name before namespace migration |
| `qa-fail` | `loop:result:qa-fail` | Previous canonical name before namespace migration |
| `blocked` | `loop:result:blocked` | Previous canonical name before namespace migration |
| `done` | `loop:result:done` | Previous canonical name before namespace migration |
| `po-review` | `loop:action:po` | Old PO trigger label |
| `dev` | `loop:action:dev` | Old dev trigger label |
| `plan` | `loop:action:dev` | Old plan-stage trigger (minimal / docs-only) |
| `in-progress` | `loop:active:dev` | Pre-canonical claim label |
| `review-pending` | `loop:action:review` | Synonym for the review queue |
| `ready-for-qa` | `loop:action:qa` | Synonym for the QA queue |
| `needs-rework` | `loop:action:dev` | Rework collapses back into the dev queue (PR-side trigger) |
| `changes-requested` | `loop:action:dev` | GitHub-style synonym for review rejection |
| `in-rework` | `loop:active:dev` | Pre-canonical claim label for rework; unified with dev claim |

## Per-project label remapping

Workflows reference canonical names, but a project can still rename a label
on disk (for vocabulary preferences or to coexist with a pre-existing label
scheme on the GitHub repo). Set the override under the project's `labels:`
map in `config/projects.yaml`:

```yaml
projects:
  - slug: example
    repo: org/example
    workflow: default
    labels:
      loop:action:dev: backlog           # canonical → project-local
      loop:action:review: review-please
```

`lib/workflow.sh::loop_label_for` and `loop_polled_labels` apply the
override transparently — handlers, the scanner, and the reconciler always
work in canonical-label terms internally and only translate at the GitHub
API boundary. No code changes are required to support a renamed label.
