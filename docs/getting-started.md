# Getting Started with Loop

## Prerequisites

- `gh` CLI authenticated: `gh auth status`
- `python3` with `pyyaml`: `python3 -c "import yaml"`
- One of: `claude`, `codex`, `gemini`, or `aider` CLI installed and on PATH
- A GitHub repo you want to automate

## Step 1 — Clone and bootstrap

Bootstrap auto-detects your agent and writes `loop.env`. No manual editing
required for the happy path.

```bash
git clone https://github.com/svv2014/loop.git
cd loop
./install.sh --bootstrap
```

## Step 2 — Add your project

```bash
./install.sh /path/to/your/project
```

Or fully automatic:
```bash
./install.sh /path/to/your/project --auto
```

This adds the project to `config/projects.yaml`, creates labels on GitHub,
enables auto-merge, and copies issue/PR templates.

## Step 3 — Write CLAUDE.md in the project root

Copy `templates/CLAUDE.md.template` into `{root}/CLAUDE.md` and fill in:
- Stack (languages, frameworks, versions)
- Key files (entrypoints, tests, config)
- Development commands (install/build/test/lint)
- Conventions (branch naming, commit style, PR rules)

The dev handler instructs the agent to read this file before every task.

## Step 4 — Start the scanner

`--bootstrap` registers the scanner and reconciler automatically (launchd
on macOS, cron on Linux). To start them manually or for testing:

```bash
# Foreground (testing / dry-run)
bash scanner/scanner.sh --dry-run

# macOS — restart launchd service
launchctl kickstart -k gui/$(id -u)/com.user.loop-scanner

# Linux — restart cron wrapper or systemd unit
systemctl --user restart loop-scanner
```

## Step 6 — Create an issue

```bash
gh issue create --repo owner/repo --title "Add health check endpoint" --label dev
```

Within 5 minutes the pipeline picks it up. Watch with:
```bash
tail -f $(grep LOOP_LOG_DIR loop.env | cut -d= -f2)/loop-scanner.log
```

## Required pipeline labels

Every managed project must have the following labels (created automatically by `install.sh`):

| Label | Purpose |
|-------|---------|
| `po-review` | PO agent expands rough idea into full spec |
| `dev` | Issue ready for automated dev cycle |
| `in-progress` | Currently being worked on by dev agent |
| `in-review` | Reviewer is looking at the PR |
| `review-pending` | PR open, waiting for automated review |
| `ready-for-qa` | Approved, needs QA validation |
| `qa-pass` | QA passed, ready to merge |
| `qa-fail` | QA failed, back to dev for rework |
| `changes-requested` | Reviewer requested changes |
| `blocked` | Failed 3× — needs human intervention |
| `needs-clarification` | Dev agent hit ambiguity |
| `done` | Merged and closed |

The scanner only acts on these canonical labels and their registered aliases. Issues or PRs with non-standard label names will not be picked up. To audit a project for missing or non-standard labels, run:

```bash
scripts/label-audit.sh --slug <slug>
# or all projects at once:
scripts/label-audit.sh
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Scanner picks nothing up | `gh` auth broken in cron env | Check `LOOP_EXTRA_PATH` in `loop.env` |
| Handler runs but agent fails | Missing `CLAUDE.md` | Create the project's `CLAUDE.md` |
| PR stuck at `review-pending` | Lock held by another handler | Check `/tmp/loop-locks/` for zombie PIDs |
| Issue stuck at `blocked` | Failed 3x | Check handler logs, fix manually |
| Same event emitted every tick | Normal on first tick after restart | Dedup cache rebuilds automatically |
