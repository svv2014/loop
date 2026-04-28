# Quick start — Loop

Get from zero to your first merged PR.

## Prerequisites

- `gh` CLI authenticated (`gh auth status`)
- `python3` with `pyyaml` (`pip3 install pyyaml`)
- `claude` CLI installed and authenticated

## Step 1 — Clone and bootstrap

Clone Loop and run the one-time setup.

```bash
git clone https://github.com/svv2014/loop.git
cd loop
./install.sh --bootstrap
```

## Step 2 — Configure loop.env for Claude

Open `loop.env` (created by bootstrap) and set:

```bash
LOOP_AGENT=claude
LOOP_AGENT_MODEL=sonnet
```

## Step 3 — Add a GitHub project

Register your repo with the pipeline.

```bash
./install.sh /path/to/your-project
```

## Step 4 — Label an issue

Apply `po-review` to hand off a rough idea (the PO agent expands the spec, then implements). Use `dev` to skip PO and go straight to implementation.

```bash
gh issue edit N --repo owner/repo --add-label po-review
```

## Step 5 — Watch it ship

Tail the dev handler log to see the agent branch, commit, and open a PR.

```bash
tail -f ~/.loop/logs/loop-dev-handler.log
```

Labels progress automatically: `needs-review` → `needs-qa` → merged.

---

## Optional: loop-monitor dashboard

Install the companion dashboard for live agent status and bounty scores.

```bash
git clone https://github.com/svv2014/loop-monitor.git
cd loop-monitor
pip install -r requirements.txt
./run.sh
```

Open http://127.0.0.1:18792. Add `LOOP_BOUNTY_URL=http://127.0.0.1:18792` to `loop.env` to enable event reporting.

## Other agents & backends

Change `LOOP_AGENT` in `loop.env` to switch agents:

| Agent | `LOOP_AGENT` value |
|---|---|
| Anthropic Claude | `claude` |
| OpenAI Codex | `codex` |
| Google Gemini | `gemini` |
| Aider | `aider` |

For GitLab or Jira+GitLab backends, set `LOOP_BACKEND=gitlab` or `LOOP_BACKEND=jira-gitlab` in `loop.env`. See `lib/backends/` for adapter details.

## Troubleshooting

**Nothing happens after labelling:**
- Confirm labels match your workflow: `config/workflows/<workflow>.yaml`
- Check `~/.loop/logs/loop-scanner.log` for `scan: <slug>` lines.

**PR opened but no labels:**
- Check `~/.loop/logs/loop-dev-handler.log` for agent output.
- Fix manually: `gh pr edit N --add-label needs-review`

**QA fails every PR:** run your `validation_cmd` from the project root manually.

**More help:** open an issue with the `bug` label.

## Updating Loop

Review [CHANGELOG.md](../CHANGELOG.md) before upgrading — MINOR version bumps may change `loop.env` keys or the `config/projects.yaml` schema.

```bash
cd ~/projects/loop
git pull --ff-only
# Restart — macOS launchd
launchctl kickstart -k gui/$(id -u)/com.user.loop-scanner
launchctl kickstart -k gui/$(id -u)/com.user.loop-reconciler
```

On Linux, restart your cron wrapper or process supervisor (e.g. `systemctl --user restart loop-scanner`).

To roll back: `git checkout <previous-tag>` then restart services.

### Logs reference

| Log file | What it covers |
|---|---|
| `~/.loop/logs/loop-scanner.log` | Poller ticks, label events dispatched |
| `~/.loop/logs/loop-dev-handler.log` | Dev agent output per issue |
| `~/.loop/logs/loop-review-handler.log` | Review agent output |
| `~/.loop/logs/loop-qa-handler.log` | QA agent + validation output |
| `~/.loop/logs/loop-reconciler.log` | Reconciler housekeeping |
