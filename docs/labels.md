# Labels

Loop drives every issue and PR through a label state machine. The vocabulary
is small and intentionally so: every state has exactly one canonical name
defined in `lib/labels.sh` (`LOOP_CANONICAL_LABELS`). Workflow YAMLs in
`config/workflows/` reference only canonical names; older synonyms still in
the wild are auto-renamed by the reconciler on its next tick.

## Canonical taxonomy

Eleven labels cover every Loop pipeline state.

| Canonical label | Object | Triggers / role | Set by |
|---|---|---|---|
| `needs-po` | issue | Rough idea — PO handler will expand into a full spec | operator |
| `in-po` | issue | PO handler has claimed the issue and is expanding the spec | agent (po-handler) |
| `needs-dev` | issue / PR | Issue: queued for implementation. PR: review rejected, queued for rework. | operator (issue) / agent (PR, via review-handler reject) |
| `in-dev` | issue / PR | Dev or rework handler has claimed the work | agent (dev-handler / dev-rework-handler) |
| `needs-review` | PR | PR is open and waiting for code review | agent (dev-handler on PR open; dev-rework-handler on rework done) |
| `in-review` | PR | Review handler has claimed the PR | agent (review-handler) |
| `needs-qa` | PR | Review approved; queued for the QA gate | agent (review-handler on approve) |
| `qa-pass` | PR | QA passed; queued for merge. Also used by docs-only workflow as the "approved, ready to merge" signal. | agent (qa-handler) / operator (manual override) |
| `qa-fail` | PR | QA failed; queued for dev rework | agent (qa-handler) |
| `blocked` | issue / PR | Terminal until a human intervenes | agent (after max retries) / operator |
| `done` | issue / PR | Terminal — issue closed or PR merged | agent (merge-handler) |

A handful of orthogonal labels (`needs-clarification`, `safe-to-test`, plus
priority / semver / epic markers) are preserved as-is — they coexist with the
state-machine labels and are never stripped on terminal transitions other
than the strict pipeline-stage set in `LOOP_PIPELINE_STAGE_LABELS`.

## Operator-set vs agent-set

The taxonomy splits cleanly:

- **Operator-set**: `needs-po`, `needs-dev` on issues, `blocked` (when
  humans intervene), occasional `qa-pass` to force-merge.
- **Agent-set**: every `in-*` claim label, every `needs-*` transition that a
  handler emits on completion (`needs-review`, `needs-qa`), every terminal
  outcome (`qa-pass`, `qa-fail`, `done`), and `blocked` after max retries.

This split exists so handlers can race safely: only one party owns a given
transition. Operators set the queue labels (`needs-po` / `needs-dev`) and
nothing else; agents own the in-flight (`in-*`) and outcome states.

## Deprecated alias table

These names are still recognised in the wild — `lib/labels.sh::LOOP_DEPRECATED_ALIAS_MAP`
is the source of truth, and `reconcile_alias_renames` (see #168) rewrites
them on every reconciler tick. New code, new workflow YAMLs, and new
handlers must reference the canonical name only.

| Deprecated alias | Canonical replacement | Notes |
|---|---|---|
| `po-review` | `needs-po` | Old PO trigger label |
| `dev` | `needs-dev` | Old dev trigger label |
| `plan` | `needs-dev` | Old plan-stage trigger (minimal / docs-only) |
| `in-progress` | `needs-dev` | Pre-canonical claim label; handler now uses `in-dev` |
| `review-pending` | `needs-review` | Synonym for the review queue |
| `ready-for-qa` | `needs-qa` | Synonym for the QA queue |
| `needs-rework` | `needs-dev` | Rework collapses back into the dev queue (PR-side trigger) |
| `changes-requested` | `needs-dev` | GitHub-style synonym for review rejection |
| `in-rework` | `in-dev` | Pre-canonical claim label for rework; unified with dev claim |

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
      needs-dev: backlog          # canonical → project-local
      needs-review: review-please
```

`lib/workflow.sh::loop_label_for` and `loop_polled_labels` apply the
override transparently — handlers, the scanner, and the reconciler always
work in canonical-label terms internally and only translate at the GitHub
API boundary. No code changes are required to support a renamed label.
