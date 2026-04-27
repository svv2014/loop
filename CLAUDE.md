# CLAUDE.md — Loop

This file is the agent's project briefing. Read it before implementing any change.
Keep it short, factual, and current.

## Stack

- Language: Bash (all scripts use `#!/usr/bin/env bash` + `set -euo pipefail`)
- Config parsing: python3 + pyyaml (required at runtime)
- GitHub integration: `gh` CLI (authenticated)
- Supported agent CLIs: `claude`, `codex`, `gemini`, `aider` (selected via `LOOP_AGENT` env var)
- macOS scheduler: launchd; Linux scheduler: cron
- No compiled artifacts — pure shell + Python snippets inlined with heredocs

## Key Files & Directories

```
install.sh                  # Bootstrap + project onboarding CLI
config/projects.yaml        # Per-project settings (repo, slug, prefix, validation cmd)
loop.env / loop.env.example  # Local runtime config (not committed)
lib/env.sh                  # Load loop.env; export LOOP_LOG_DIR, PATH, helpers
lib/config.sh               # loop_load_project <slug> → exports REPO ROOT etc.
lib/github.sh               # gh/jq wrappers: list issues/PRs, add/remove labels
lib/runner.sh               # loop_run_agent — invokes the selected agent CLI
lib/lock.sh                 # Per-project advisory lock (/tmp/loop-locks/<slug>.lock)
lib/backends/               # Adapter layer: github (default), gitlab, jira-gitlab
scanner/scanner.sh          # Continuous poller — emits events per project label state
scanner/reconciler.sh       # Periodic housekeeping (duplicate PRs, orphaned claims)
scripts/dev-handler.sh      # Handles loop.dev_issue — creates branch + PR via agent
scripts/review-handler.sh   # Handles loop.pr_review
scripts/qa-handler.sh       # Handles loop.pr_qa
scripts/merge-handler.sh    # Handles loop.pr_merge
scripts/po-handler.sh       # Handles loop.po_review (PO expansion)
scripts/dev-rework-handler.sh  # Handles loop.dev_rework (changes-requested / qa-fail)
templates/CLAUDE.md.template   # Template for per-project CLAUDE.md files
templates/launchd/          # macOS plist templates for scanner + reconciler
```

## Development Commands

```bash
# Bootstrap the Loop toolchain (first-time setup)
./install.sh --bootstrap

# Add a project to the pipeline
./install.sh /path/to/project [--auto]

# Syntax-check all scripts (matches CI)
for f in lib/*.sh scripts/*.sh scanner/*.sh install.sh; do bash -n "$f"; done

# Shellcheck (matches CI)
shellcheck -S warning lib/*.sh scripts/*.sh scanner/*.sh install.sh

# Run scanner once (dry-run to see events without dispatching)
./scanner/scanner.sh --dry-run

# Run reconciler against one project
./scanner/reconciler.sh --slug <slug> [--dry-run]

# Tail logs
tail -f ~/.loop/logs/loop-scanner.log
tail -f ~/.loop/logs/loop-dev-handler.log
```

## Conventions

- **Branch naming:** `fix/issue-N-slug` or `feat/issue-N-slug`
- **Commit title:** `[ASD-N] <short description>` (prefix from `config/projects.yaml` → `dev.commit_prefix`)
- **PR body:** must include `Closes #N`
- **Labels** drive the pipeline state machine — never skip the label-swap step in handlers
- **Agent selection:** set `LOOP_AGENT` in `loop.env` to `claude`, `codex`, `gemini`, or `aider`; `lib/runner.sh` dispatches accordingly
- **No hardcoded paths:** use `$LOOP_ROOT`, `$ROOT`, `$HOME` — never literal `/Users/...` paths
- **No personal identifiers** in committed files (CI grep enforces this)
- Each handler sources `lib/env.sh`, `lib/config.sh`, `lib/backends/backend.sh` — maintain this pattern
- Python snippets are inlined via heredoc (`<<'PY'`) — do not introduce `.py` source files
- `loop.env` is never committed (`.gitignore`); `loop.env.example` is the canonical reference

## QA Process

CI runs on every PR (`ci.yml`) and again on `ready-for-qa` label (`qa-build-test.yml`):

1. `bash -n` syntax check on `lib/*.sh scripts/*.sh scanner/*.sh install.sh`
2. `shellcheck -S warning` on the same set
3. Personal-identifiers grep — fails if operator-specific names or local absolute paths appear in committed files (see `.github/workflows/ci.yml` for the exact pattern list)
4. On `ready-for-qa`: squash-merge + delete branch if all checks pass; labels PR `qa-fail` otherwise

**Before opening a PR:** run `bash -n` locally (step above) and confirm no personal identifiers.

## Agent Rules

- Read this file before starting any implementation task.
- Work only inside the isolated git worktree provided (`$WORKTREE_ROOT`). Do not touch `$ROOT` directly.
- Branch off `origin/$DEFAULT_BRANCH` — never commit directly to the default branch.
- After completing a dev task, the issue **must** end with label `review-pending` (or `needs-clarification` if blocked). Verify:
  ```bash
  gh issue view <N> --repo <REPO> --json labels
  ```
- If the issue body declares a `## Dependencies` section, check unmet deps before proceeding.
- If a pre-existing remote branch conflicts, delete it first:
  ```bash
  git push origin --delete <branch-name>
  ```
- Do not add new runtime dependencies without updating `install.sh` bootstrap checks.
- Do not modify `loop.env` or `config/projects.yaml` — those are operator-managed files.
