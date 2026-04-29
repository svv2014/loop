# Label Lifecycle

Loop drives issues and PRs through a label-based state machine. Handlers advance
labels on success; the scanner uses labels to decide what's actionable.

## Issue states

```
(new)
  │
  │  human opens issue with label: po-review (rough idea → PO expands spec)
  │                             or dev (pre-written spec → straight to implementation)
  ▼
po-review ──► po-handler expands spec ──► dev
dev ──────────────────────────────────────► build (in-progress)
                                               │
                                               │ dev-handler runs agent, opens PR
                                               ▼
                                          needs-review (review-pending)  (on issue; also set on PR)
                                               │
                                               │ merge-handler closes issue when PR merges
                                               ▼
                                             done  (issue closed)

 Failure paths:
    build ──► (retries < 3) ──► cleared, scanner re-emits next tick
    build ──► (retries ≥ 3) ──► blocked  (terminal until human intervenes)
    build ──► needs-clarification  (agent gave up with a comment)
```

## PR states

```
(new)                                 created by dev-handler
  │                                   with label needs-review (review-pending)
  ▼
needs-review (review-pending)
  │ review-handler claims
  ▼
in-review
  │
  ├── approve ──► needs-qa (ready-for-qa)
  │                   │
  │                   │ qa-handler validates (or QA workflow for Loop repo)
  │                   ├── pass ──► approved (qa-pass) ──► merge-handler ──► merged + branch deleted
  │                   │
  │                   └── fail ──► qa-fail (qa-failed) (requires human or re-dev)
  │
  └── reject ──► needs-rework (changes-requested) (back to dev-handler with feedback)
```

## Scanner filters

The scanner emits an event only when the label **phase** matches and no
downstream "claimed" label is present. That's how we dedup across ticks.

Both the new canonical name and its deprecated alias trigger the same event.

| Source | Emits event type | Claimed if any of these labels present |
|---|---|---|
| Issue has `po-review` | `loop.po_review` | build, in-progress, blocked, needs-review, review-pending, needs-qa, ready-for-qa, approved, qa-pass, done |
| Issue has `dev` | `loop.dev_issue` | build, in-progress, blocked, needs-review, review-pending, needs-qa, ready-for-qa, approved, qa-pass, done |
| PR has `needs-review` or `review-pending` | `loop.pr_review` | in-review, needs-qa, ready-for-qa, approved, qa-pass, done |
| PR has `needs-qa` or `ready-for-qa` | `loop.pr_qa` | approved, qa-pass, done |
| PR has `approved` or `qa-pass` | `loop.pr_merge` | (none — idempotent until merged) |

## Terminal labels

- `done` — issue closed, PR merged. No further events.
- `blocked` — needs human attention. No automation until a human removes the label.
- `needs-clarification` — waiting on issue author.
- `qa-fail` (`qa-failed`) — canonical failure label; waiting on human review. `qa-failed` is the deprecated alias.

## QA handler — four-phase smart verification

The QA handler (`scripts/qa-handler.sh`) performs four phases before reaching a verdict:

1. **AC verification** — reads the issue body, checks each acceptance criterion against the diff
2. **Targeted test creation** — writes tests for any AC that lacks coverage
3. **Module regression** — runs existing tests for all modules touched by the PR
4. **`validation_cmd`** — runs the project's configured validation command (e.g. `npm test`, `make`)

The agent posts a structured `### QA verification` comment on the PR summarising each phase, then applies either `qa-pass` or `qa-fail`. Labels are resolved via `loop_label_for` so per-project overrides are respected.

## Loop repo (dogfooding)

Loop dogfoods its own pipeline. The GitHub Actions QA workflow
(`.github/workflows/qa-build-test.yml`) acts as the validation gate:

1. Triggered when a PR is labeled `ready-for-qa`
2. Runs shellcheck + `bash -n` validation + personal identifier check
3. On failure: labels `qa-fail`, comments with the run link
4. On success: removes `ready-for-qa`, adds `qa-pass`
5. The pipeline's merge-handler then merges the PR and closes linked issues
