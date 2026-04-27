# Loop security model

Loop runs AI-generated code on the operator's machine, with operator
shell privileges and operator credentials. This document describes the
trust boundaries, the gates that enforce them, and the operational
practices that keep the system safe.

## Threat model

Trusted:
- The **operator** (you) — chose to install Loop, configured `loop.env`,
  controls `gh auth`
- The **operator's machine** — local disk, env vars, `~/.gitconfig`,
  agent CLI credentials

Partially trusted:
- The **AI agent** — its output is reviewed by a second AI in the
  review-handler stage, then validated in QA
- **Repo collaborators** — they can apply pipeline labels and trigger
  agent work; assumed to act in good faith but compromise is possible

Untrusted at code-execution level:
- **External contributors** opening fork PRs
- **Drive-by GitHub users** opening issues or comments
- **Unknown HTTP clients** that might POST to loop-monitor

## Three security gates

### Gate 1 — pipeline activation requires labels (collaborator-only)

The scanner only acts on issues/PRs carrying a workflow trigger label
(`plan`, `needs-review`, `needs-qa`, etc.). GitHub permissions enforce
that **only repo collaborators can apply labels**. A drive-by user can
open an issue but cannot label it; the scanner will ignore it.

If a collaborator account is compromised, the attacker can label issues
and PRs and trigger the AI agent. Mitigations:
- 2FA on all collaborator accounts (mandatory for production setups)
- Review label changes via operator notifications
- CODEOWNERS gate on `main` requires a second approval before merge

### Gate 2 — fork PRs require `safe-to-test` for code execution

The QA handler runs each project's `validation_cmd` (e.g. `npm test`,
`make build`, `cargo test`) against the PR head's working tree. For
PRs from internal branches (same repo) this is operator code. For PRs
from forks, the handler **refuses to run** unless a maintainer has
applied the `safe-to-test` label.

The maintainer's job before applying `safe-to-test`:
1. Read the diff
2. Look for anything that would execute during validation:
   - `package.json` postinstall / preinstall scripts
   - `Makefile` targets that shell out to unfamiliar commands
   - Test fixtures that exec()
   - Build configurations that download/run code
3. If the diff looks safe, apply `safe-to-test`. The QA handler then
   proceeds normally.
4. If the diff includes new build scripts or unfamiliar tooling, ask
   the contributor to split or simplify before testing.

`safe-to-test` is **not** revoked when the PR head changes — a
malicious contributor could push a clean diff, get the label, then
push malware. Operationally: re-review on every push to fork PRs, or
remove the label after testing. (Future: auto-revoke on push event,
tracked in the roadmap.)

### Gate 3 — branch protection + CODEOWNERS approval gates merge

Branch protection on `main` (configured per repo) requires:
- PR to be opened (no direct pushes — even from operator)
- CI status checks to pass (`lint`, `qa-merge`)
- An approval from a [CODEOWNERS](.github/CODEOWNERS)-listed reviewer

The operator's own PRs need this gate too. The operator can self-approve
via review (you're listed as a CODEOWNER), but the gate ensures every
merge gets an explicit "approved" decision rather than a silent push.

For production repos: never disable this gate. If something is broken
and you need to push a hotfix, follow the regular flow.

## Surface-by-surface analysis

### Pipeline activation surface

- **Trigger:** GitHub label change events (collaborator-only)
- **Sensitive operation:** Agent CLI invocation in operator shell
- **Defense:** GitHub permissions; operator review of label changes
- **Failure mode:** Compromised collaborator account → arbitrary agent
  invocation. 2FA + monitoring mitigate.

### Code execution surface

- **Trigger:** PR labeled `needs-qa`
- **Sensitive operation:** Run `validation_cmd` against PR head code
- **Defense:** `safe-to-test` gate for fork PRs; same-repo PRs
  considered trusted
- **Failure mode:** Malicious fork PR with hidden code execution →
  full operator-shell access. Maintainer review required.

### Agent autonomy surface

- **Trigger:** Issue labeled `plan`
- **Sensitive operation:** Agent CLI runs with operator shell access
- **Defense:** Agent runs in an isolated git worktree (file scope), but
  shell access is full. Same trust posture as Claude Code or any
  agent CLI.
- **Failure mode:** Prompt injection via issue body → agent runs
  unintended commands. Operator monitors via logs and bounty
  scorecards.

### Credential surface

- **`gh` tokens:** Managed by `gh auth`; not stored by Loop
- **Agent CLI tokens:** Managed by each agent's own config
- **`LOOP_NOTIFY` shell snippets:** Operator-controlled
- **Bounty event API:** No auth (loopback only)

Loop introduces no new credential storage.

### Bounty event API surface

- **Trigger:** `POST /api/report` to loop-monitor
- **Defense:** loop-monitor binds to `127.0.0.1` by default; not
  exposed to the network
- **Failure mode:** If exposed publicly without auth, anyone can spam
  bounty events or poll telemetry. Don't expose without adding auth.

## Recommended setup for production repos

1. **Branch protection on `main`:**
   - Require PR before merging
   - Require status checks: `lint`, `qa-merge`
   - Require linear history
   - Require code-owner approval (CODEOWNERS file populated)
   - Block force-pushes and deletions

2. **2FA on all collaborators**

3. **Loop-monitor on loopback only:**
   - Don't bind to `0.0.0.0`
   - Don't expose port 18792 to the network

4. **Periodic review of `safe-to-test` PRs:**
   - Remove the label from stale fork PRs
   - Re-review fork PRs after new commits

5. **Notification integration:**
   - Set `LOOP_NOTIFY` to alert on label changes, blocked tickets, and
     reconciler interventions
   - Read the alerts; don't let them rot

6. **Periodic bounty audit:**
   - Skim `data/bounties.jsonl` weekly for outliers (e.g. unusual
     rework counts on a particular project) — these often surface
     prompt-injection attempts or label-misuse before they cause harm

## Reporting issues

Use [GitHub Security Advisories](https://github.com/svv2014/loop/security/advisories/new)
for vulnerabilities. Public issues for non-sensitive bugs.

## Out of scope (known trade-offs)

- **Sandboxing the AI agent.** Full operator-shell access is the
  current trust posture, matching agent CLIs at large. Containerized
  agent execution is on the roadmap for v0.4.
- **Authenticated bounty events.** Loop-monitor expects loopback. Add
  your own auth proxy if you need network exposure.
- **Auto-revoking `safe-to-test`.** On the roadmap. Until then,
  manual operator vigilance on fork PRs.
