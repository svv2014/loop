# Failure Handling in Loop Handlers

## Failure Classes

Loop distinguishes two classes of handler failure:

### Transient (Infra) Failures

Caused by infrastructure problems, not by the issue spec itself. The ticket
should not be penalised — the problem needs operator attention.

**Recognised signatures:**

| Pattern | Origin |
|---|---|
| `ImportError` / `ModuleNotFoundError` | Python dependency missing in orchestrator |
| `ConnectionError` / `ConnectionRefusedError` | Orchestrator or model API unreachable |
| `TimeoutError` | Network or model API timeout |
| HTTP `429` | Model API rate limit |
| HTTP `5xx` | Model API server error |
| `rate limit`, `timeout`, `connection refused`, `econnreset`, `service unavailable` | Generic network / auth signals (via `_loop_is_recoverable`) |
| `401`, `403 auth` | Authentication failure |

Classification is provided by `lib/failure_classifier.sh`:

```bash
source "$LOOP_ROOT/lib/failure_classifier.sh"
if loop_is_transient_failure "$stderr_tail" "$exit_code"; then
    sig=$(loop_failure_signature "$stderr_tail")
    ...
fi
```

### Non-Transient (Spec) Failures

All other failures — bad spec, agent logic error, unexpected output format.
These are counted against the per-issue retry counter and eventually trigger
`needs-clarification`.

---

## Counter Files

Two separate counter files exist per issue in the PO handler:

| File | Purpose |
|---|---|
| `/tmp/loop-po-retries-<slug>-<issue>` | Non-transient failure count |
| `/tmp/loop-po-transient-<slug>-<issue>` | Consecutive transient failure count |

The transient counter is reset to zero on any successful run or when the issue
is escalated to `blocked`. The retry counter is managed independently.

---

## PO Handler Behaviour

### Transient failure path

1. Handler captures runner stderr to a temp file.
2. On non-zero exit, `loop_is_transient_failure` inspects the last 50 lines.
3. If transient:
   - The **retry counter is NOT incremented**.
   - The transient counter is incremented.
   - If transient count < `MAX_TRANSIENT_RETRIES` (default 3):
     - Restores the PO trigger label so the scanner re-emits next tick.
   - If transient count ≥ `MAX_TRANSIENT_RETRIES`:
     - Labels the issue `blocked` (not `needs-clarification`).
     - Calls `loop_notify_human_required` with `"infra: <signature>"`.
     - Clears the transient counter.

### Non-transient failure path

Unchanged from prior behaviour:
1. Retry counter incremented.
2. If count < `MAX_RETRIES` (default 2): restores PO trigger for next attempt.
3. If count ≥ `MAX_RETRIES`: labels issue `needs-clarification` and notifies.

---

## Operator Escalation Path

When a `blocked` label appears with reason `infra: <signature>`, the operator
should:

1. Check `~/.loop/logs/loop-po-handler.log` for the full stderr tail.
2. Fix the underlying infrastructure issue (install missing Python module,
   rotate API keys, check model API status).
3. Remove the `blocked` label and re-add the PO trigger label to re-queue.

Example (GitHub):

```bash
gh issue edit <number> --repo <repo> --remove-label blocked --add-label loop.po_review
```

---

## Adding Transient Classification to Other Handlers

The same pattern can be applied to `dev-handler.sh`, `qa-handler.sh`, etc. by:

1. Sourcing `lib/failure_classifier.sh` (which requires `lib/runner.sh` sourced first).
2. Redirecting runner stderr to a temp file.
3. Calling `loop_is_transient_failure` on the tail and branching accordingly.

See `scripts/po-handler.sh` for the reference implementation.
