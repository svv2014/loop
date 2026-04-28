# Quick start — Loop in 5 minutes

This walkthrough takes a fresh repo from zero to a working pipeline.

## Prerequisites

- macOS or Linux
- `gh` CLI authenticated (`gh auth status`)
- `python3` with `pyyaml` (`pip3 install pyyaml`)
- An AI agent CLI: `claude`, `codex`, `gemini`, or `aider`

## 1. Install Loop

```bash
git clone https://github.com/svv2014/loop.git
cd loop
./install.sh --bootstrap
```

The bootstrap:
- Verifies tools
- Copies `loop.env.example` → `loop.env`
- Copies `config/projects.example.yaml` → `config/projects.yaml`
- Registers the scanner + reconciler with launchd (macOS) or cron
  (Linux)

Verify the scanner is running:

```bash
launchctl list | grep loop          # macOS
crontab -l | grep loop              # Linux
tail -f ~/.loop/logs/loop-scanner.log
```

You should see scanner ticks every 5 minutes — they'll be empty (no
projects yet) until step 3.

## 2. Configure your AI agent

Edit `loop.env`:

```bash
LOOP_AGENT=claude              # or codex, gemini, aider
LOOP_AGENT_MODEL=sonnet        # optional
```

Test the agent works:

```bash
echo "say hi" | claude          # for claude users
```

## 3. Add your first project

```bash
./install.sh /path/to/your-project
```

The installer prompts for:
- GitHub repo (`owner/repo`)
- Project slug (short prefix, e.g. `myapp`)
- Default branch (`main` / `master`)
- Workflow choice (`default` recommended for new repos)
- Validation commands (your `npm test`, `make`, etc.)

It then:
- Adds the project to `config/projects.yaml`
- Creates Loop labels in the GitHub repo (`plan`, `needs-review`,
  `needs-qa`, etc.)
- Enables auto-merge + delete-branch-on-merge
- Restarts the scanner

## 4. Try a feature

Open an issue in your project:

```bash
gh issue create --repo owner/your-project \
  --title "Add a hello world endpoint" \
  --body "Add GET /hello that returns 'world' as text/plain." \
  --label plan
```

Within ~5 minutes the scanner picks it up and the dev handler starts.
Watch:

```bash
tail -f ~/.loop/logs/loop-dev-handler.log
```

You'll see the agent log its work, commit, and open a PR. The PR
labels go through `needs-review` → `needs-qa` → `qa-pass` → merged.
Total elapsed for a small feature: 10–20 minutes.

## 5. Optional — install loop-monitor for visibility

```bash
git clone https://github.com/svv2014/loop-monitor.git
cd loop-monitor
pip install -r requirements.txt
./run.sh
```

Open http://127.0.0.1:18792. You'll see live agent status, role-level
bounty points, and (after the next merge) an AI judge verdict on the PR.

In `loop.env`, set:

```bash
LOOP_BOUNTY_URL=http://127.0.0.1:18792
```

…to enable the bounty event reporting from Loop core to the monitor.

## What's next

- **Choose or author a workflow** — `config/workflows/README.md`
  documents the schema. Default workflow has 5 stages; you can author
  one with 3 (skip review for solo projects) or 7 (add a security
  audit stage).
- **Add more projects** — re-run `./install.sh /path/to/another-project`.
  One scanner manages all of them.
- **Tune `pipeline_slots`** in `config/projects.yaml` to cap how many
  PRs are in flight per project.
- **Review the security model** — `docs/security-model.md` covers the
  collaborator-only label gate and the `safe-to-test` flow for fork PRs.

## Common operations

```bash
# Check status
launchctl list | grep loop
tail -50 ~/.loop/logs/loop-scanner.log

# Pause the scanner (keeps reconciler running)
launchctl unload ~/Library/LaunchAgents/com.user.loop-scanner.plist

# Resume
launchctl load ~/Library/LaunchAgents/com.user.loop-scanner.plist

# One-shot scan
./scanner/scanner.sh --once --dry-run    # preview without dispatching

# Force a reconciler sweep
./scanner/reconciler.sh --slug myapp

# Show version
./install.sh --version
```

## Troubleshooting

**Scanner is running but nothing is happening:**
- Confirm your project's labels match the workflow's expected names
  (`config/workflows/<your-workflow>.yaml`). Maybe you need a `labels:`
  override in `projects.yaml`.
- Check `~/.loop/logs/loop-scanner.log` for `scan: <slug>` lines.

**Dev handler runs but PR has no labels:**
- Check `~/.loop/logs/loop-dev-handler.log` for the agent output.
- The handler's belt-and-braces should add `needs-review` if the agent
  forgot. If not, re-run with `gh pr edit N --add-label needs-review`.

**QA workflow fails on every PR:**
- Run your `validation_cmd` manually from the project root. If it
  fails, fix the project; if it passes, check the QA workflow logs.

**More help:** open an issue with the `bug` label.

## Updating Loop

### What changes between versions

Review [CHANGELOG.md](../CHANGELOG.md) before upgrading. Pre-1.0, MINOR
version bumps (`0.1 → 0.2`) may change `loop.env` keys or the
`config/projects.yaml` schema; the changelog always includes a migration
recipe. PATCH bumps are safe to apply without reading the changelog.

### How to update (manual, until `update.sh` ships — see [#17](https://github.com/svv2014/loop/issues/17))

```bash
# 1. Pull Loop core
cd ~/projects/loop
git pull --ff-only

# 2. Pull loop-monitor (if installed)
cd ~/projects/loop-monitor
git pull --ff-only

# 3. Restart services — macOS launchd
launchctl kickstart -k gui/$(id -u)/com.user.loop-scanner
launchctl kickstart -k gui/$(id -u)/com.user.loop-reconciler
```

On Linux, restart however your cron wrapper or process supervisor is
configured (e.g. `systemctl --user restart loop-scanner`).

### How to roll back

```bash
cd ~/projects/loop
git checkout <previous-tag>     # e.g. git checkout v0.1.0
# then restart services as above
```

Tag history: `git tag --sort=-version:refname | head -10`

### If a launchd service fails to restart

1. Check the exit code:
   ```bash
   launchctl list | grep loop
   ```
   A non-zero PID column means it crashed on start.

2. Read the error log:
   ```bash
   tail -50 ~/.loop/logs/loop-scanner.log
   tail -50 ~/.loop/logs/loop-reconciler.log
   ```

3. Common causes:
   - A new `loop.env` key is required — compare `loop.env` against
     `loop.env.example` and add the missing variable.
   - A shell-syntax error in a newly updated script — run
     `bash -n lib/*.sh scripts/*.sh scanner/*.sh install.sh` to find it.

4. Once fixed, reload:
   ```bash
   launchctl kickstart -k gui/$(id -u)/com.user.loop-scanner
   ```

### Where logs live

| Log file | What it covers |
|---|---|
| `~/.loop/logs/loop-scanner.log` | Poller ticks, label events dispatched |
| `~/.loop/logs/loop-dev-handler.log` | Dev agent output per issue |
| `~/.loop/logs/loop-review-handler.log` | Review agent output |
| `~/.loop/logs/loop-qa-handler.log` | QA agent + validation output |
| `~/.loop/logs/loop-reconciler.log` | Reconciler housekeeping |
