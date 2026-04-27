# Security policy

## Supported versions

Pre-1.0: only the latest minor release receives security fixes. From
1.0 onward, fixes target the latest minor + the previous minor (one
release of overlap).

| Version | Supported |
|---|---|
| 0.1.x | ✅ |
| < 0.1 | ❌ |

## Reporting a vulnerability

**Don't open a public issue for security reports.**

Use [GitHub Security Advisories](https://github.com/svv2014/loop/security/advisories/new)
to report privately. Include:

- A clear description of the vulnerability
- Reproduction steps or a proof of concept
- Affected versions
- Impact assessment

You should hear back within 7 days. Critical issues get prioritized;
non-critical ones land in the next minor release.

## Security model

Loop runs on a single operator machine and executes AI-generated code
with operator credentials. The threat model assumes:

- The **operator** is trusted (they chose to run Loop)
- The **AI agent** is partially trusted — its output is reviewed by a
  second AI in the review-handler stage, then validated in QA
- **External contributors** are untrusted at code-execution level until
  a maintainer applies `safe-to-test`
- **Random GitHub users** can open issues but cannot trigger pipeline
  events (collaborator-only labels gate everything)

## Attack surfaces

### 1. Pipeline activation

Pipeline triggers on labels (`plan`, `needs-review`, `needs-qa`, etc.)
which are **collaborator-only** by GitHub default. A drive-by attacker
can open an issue but cannot label it.

**If a collaborator account is compromised**, the attacker can label
issues and PRs and trigger the AI agent. Mitigations: use 2FA on all
collaborators, review labels in operator notifications.

### 2. Code execution from PR head

`qa-handler` runs each project's `validation_cmd` (e.g., `npm test`,
`make build`) against the PR head. For same-repo PRs this is operator
code. For external-fork PRs, the `safe-to-test` label is required —
maintainers must review the diff for anything that would execute
(postinstall scripts, malicious test fixtures) before applying it.

`dev-handler` runs the AI agent in an isolated git worktree but the
agent has shell access. The agent can in principle run anything on the
operator's machine. This is the same trust posture as Claude Code or
any other agent CLI.

### 3. Credentials

- `gh` CLI tokens — managed by `gh auth`, not stored in Loop config
- Agent CLI credentials — managed by each agent's own config
- `LOOP_NOTIFY` shell snippets — operator-controlled

Loop does not introduce new credential storage. If the host machine is
compromised, all credentials accessible to the operator are at risk —
this is unavoidable for a tool that runs locally.

### 4. Bounty event API

`POST /api/report` to loop-monitor accepts versioned bounty events. The
monitor does no authentication by default — it expects to run on
`127.0.0.1`. **Don't expose loop-monitor's port to a public network**
without adding authentication.

## Defense-in-depth

Recommended for production setups:

- Branch protection on `main` with required CODEOWNERS approval
- 2FA on all repo collaborators
- Periodic review of `safe-to-test` PRs (don't leave the label on
  stale fork PRs)
- Signed commits (optional but recommended)
- Loop-monitor bound to `127.0.0.1` only, never `0.0.0.0`

## Known limitations

- Loop-monitor has no built-in auth — relies on loopback binding
- No sandboxing of the AI agent — full operator-shell access
- No input rate-limiting on bounty events (loop-monitor can be flooded
  if multiple core nodes spam it; not a concern in single-machine use)

These are documented trade-offs, not bugs. PRs that address them are
welcome — open a feature issue first to align on approach.
