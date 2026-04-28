# Contributing to Loop

Loop is an open-source autonomous dev pipeline. External contributions
are welcome — and Loop dogfoods its own pipeline, so contributions land
through the same flow your own projects would use.

## Quick rules

- One concern per PR — don't bundle unrelated changes
- Branch naming: `fix/issue-N-short-slug` or `feat/issue-N-short-slug`
- Commit titles: `[LOOP-N] verb subject` (matches issue number)
- PR body must contain `Closes #N`
- All CI checks must pass: `bash -n`, `shellcheck -S warning`,
  personal-info grep, workflow validation
- Approval from a [CODEOWNERS](.github/CODEOWNERS) reviewer is required
  before merge — even the operator's own PRs need this gate
- Don't modify operator config: `loop.env`, `config/projects.yaml`

## Local dev

```bash
# Lint everything CI checks
bash -n lib/*.sh scripts/*.sh scanner/*.sh install.sh
shellcheck -S warning lib/*.sh scripts/*.sh scanner/*.sh install.sh

# Personal-info check (CI runs the same)
git grep -iE 'YOUR_PERSONAL_PATTERN' || echo "clean"

# Tests
bats tests/

# Validate workflow files
./scripts/validate-workflow.sh
```

## Submitting a PR

1. Fork the repo and create a branch: `git checkout -b fix/issue-42-thing`
2. Make your change. Keep the diff focused.
3. Run lint + tests locally. Push.
4. Open a PR with `Closes #42` in the body and a clear test plan.
5. Wait for CI to go green and a CODEOWNERS reviewer to approve. The
   merge gate enforces this; the maintainer cannot bypass it.
6. After approval, the pipeline (or maintainer) labels `needs-qa`
   which triggers the QA workflow + auto-merge on pass.

## External-fork PRs and `safe-to-test`

PRs from forks **do not** automatically run the project's
`validation_cmd` — that's a security gate to prevent untrusted code
running on operator machines. A maintainer reviews the diff for
anything that would execute (postinstall scripts, `Makefile` targets,
test fixtures that exec) and applies `safe-to-test` once confirmed
safe. Then `needs-qa` triggers the build/test as normal.

If you submit a fork PR and CI seems stuck, ping a maintainer to
review for the `safe-to-test` label.

## Versioning

Loop follows [SemVer](https://semver.org). Schema and env-var changes
that break operator configs are documented in [CHANGELOG.md](CHANGELOG.md)
under a `BREAKING:` line with a migration recipe.

If your PR changes any of:
- workflow YAML schema
- `projects.yaml` schema
- env vars (anything `LOOP_*`)
- bounty event API
- CLI flags
- log/lock dir layout

…add a `BREAKING:` line to the `[Unreleased]` section of CHANGELOG.md
explaining what changed and how operators migrate.

**`BREAKING:` format** — the line must start with the literal word `BREAKING:`
followed by a plain-English description and (where applicable) a migration
recipe or link. `scripts/update.sh` scans for this token and halts the
operator's upgrade until they acknowledge with `--yes`. Keep the line
self-contained; multi-line continuations are ignored by the scanner.

Example:

```markdown
### Changed
- BREAKING: LOOP_AGENT_MODEL renamed to LOOP_AGENT. Set in loop.env.
```

## Out of scope (not currently accepting)

- GUI / web UI — Loop is a CLI tool. Use loop-monitor for visibility.
- Cloud/hosted version — Loop runs on the operator's machine.
- Replacing the `gh` CLI dependency for the GitHub backend.

If you have a use case that hits one of these, open an issue and let's
talk first.

## Conduct

Be kind. Critique code, not people. No harassment, racism, sexism, or
personal attacks. Disagreements are normal — handle them in the PR
discussion or open a separate issue. Maintainers may close discussions
that go off the rails.

Reports: open a [security advisory](https://github.com/svv2014/loop/security/advisories/new)
for anything sensitive, or use a public issue otherwise.
