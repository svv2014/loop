# Security notes

For the full threat model and trust boundaries, see
[`docs/security-model.md`](./security-model.md). This file documents
narrow security-relevant operator contracts.

## `operator-approved` label — per-ticket override of the author allow-list

When `ALLOWED_AUTHORS` is configured for a project, the scanner silently
skips any issue or PR whose author is not on the list. Applying the
`operator-approved` label to a single ticket bypasses that check **for
that ticket only**, leaving the allow-list intact as the default
boundary.

### Semantics

- Scope is per-ticket. The label has no effect on sibling issues/PRs.
- Removing the label restores normal author-gate behaviour on the next
  scan tick.
- Tickets carrying the label are excluded from the
  `author_gated_pending` digest emitted by the reconciler — they are
  considered approved, not parked.

### Trust model

The label is a **documentation/operator contract**, not an enforcement
mechanism. Loop does not verify who applied the label. The label is
meaningful only when applied by an allow-listed user; preventing
untrusted users from applying it is the job of GitHub repository
permissions (e.g. branch protection, restricting the
`operator-approved` label to maintainers, or requiring write access to
edit labels).

If your repo permits arbitrary users to set labels, the override is
worth nothing — treat label-application authority as part of your
allow-list policy.
