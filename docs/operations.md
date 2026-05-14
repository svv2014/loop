# Operations cheatsheet

Practical reference for unsticking loop when something goes wrong. Pair this with `docs/failure-handling.md` (handler-internal classification) and `docs/architecture.md` (component overview).

## State locations

Every piece of mutable state loop creates, in one place:

| Path | Purpose | Safe to delete? |
|---|---|---|
| `/tmp/loop-po-retries-<slug>-<num>` | PO retry counter (1–`MAX_RETRIES`). Auto-cleared when an issue's `needs-clarification` label is removed. | Yes — issue gets a fresh attempt next emit. |
| `/tmp/loop-scanner-dedup/<hash>` | Per-event "emitted within last 30 min" cache. | Yes — scanner re-emits within 30 min. |
| `${LOOP_LOG_DIR}/budget/YYYYMMDD.counter` | Daily handler-time budget tally (seconds spent today). Auto-rotates at midnight. Persists across OS reboots. | Yes — drops today's tally to 0. |
| `${LOOP_LOG_DIR}/budget/YYYYMMDD.counter.lock` | Lock file for the budget counter. | Yes (only if no handler is running). |
| `/tmp/loop-scanner.lock` | Single-instance lock for the scanner process. | Only if scanner is confirmed not running. |
| `${LOOP_LOG_DIR}/loop-scanner.log` | Scanner heartbeat + emit log. | Logrotate-safe (scanner reopens on SIGHUP). |
| `${LOOP_LOG_DIR}/loop-po-handler.log` | PO transcripts. Append-only. | Logrotate-safe with care. |
| `${LOOP_LOG_DIR}/loop-pr-watchdog.log` | Watchdog tick log (if installed). | Logrotate-safe. |

Other state is in GitHub: issue / PR labels, handler-posted comments. Those reflect ground truth — when in doubt, `gh issue view` and `gh pr view`.

## Recovery recipes

### "Loop is stuck on infra failures"

Symptoms: many tickets failing with the same generic error; PO `needs-clarification` count climbing.

1. Find the actual error:
   ```bash
   tail -200 ${LOOP_LOG_DIR}/loop-po-handler.log | less
   ```
   Look for tracebacks or `error:` lines.
2. Fix the infra. Common causes:
   - boba-orchestrator missing module → `cd $ORCHESTRATOR_DIR && git pull`
   - GH rate limit → wait + check `gh api rate_limit`
   - `claude` CLI auth expired → `claude auth login`
3. Restart the scanner so it sees fixed state:
   ```bash
   launchctl kickstart -k gui/$(id -u)/com.user.loop-scanner
   ```
4. If retry counters are stale (tickets stuck at 2/2):
   ```bash
   rm /tmp/loop-po-retries-*
   ```
5. Re-queue any ticket sitting in `needs-clarification` whose root cause is fixed:
   ```bash
   gh issue edit <num> --remove-label needs-clarification --add-label needs-po
   ```

### "PRs are piling up with conflicts or failing CI"

Symptoms: open PRs sitting on `mergeable=CONFLICTING` or red CI for hours; scanner emits but no PRs merge.

If the **PR auto-rework watchdog** is installed (recommended): it'll relabel them within 15 min on its own. To force a sweep now:

```bash
$LOOP_ROOT/scripts/pr-watchdog.sh --dry-run    # see what it would do
$LOOP_ROOT/scripts/pr-watchdog.sh              # do it
```

Without the watchdog, label manually:

```bash
gh pr edit <num> --repo <owner/repo> --add-label needs-rework
```

The dev-rework handler picks up `needs-rework` PRs at the next scanner tick.

### "Tokens are spiking — slow loop down"

Three knobs, in order of preference:

1. **Daily budget cap** (in `loop.env`):
   ```bash
   LOOP_DAILY_HANDLER_BUDGET_SECONDS=14400   # 4 hours/day total
   ```
   Then restart the scanner. When today's spend reaches the cap, scanner stops emitting until midnight.
2. **Per-stage concurrency cap** (in `config/projects.yaml`):
   ```yaml
   pipeline:
     max_concurrent_handlers: 1   # default
   ```
3. **Slow the scan cadence** (in `loop.env`):
   ```bash
   LOOP_SCANNER_INTERVAL=1800   # 30 min (default 300)
   ```
   Then restart the scanner.

### "Scanner doesn't appear to be running"

```bash
launchctl list | grep loop-scanner
```

If empty:
```bash
launchctl load ~/Library/LaunchAgents/com.user.loop-scanner.plist
```

If listed but no recent log activity (>2× scan interval):
```bash
launchctl kickstart -k gui/$(id -u)/com.user.loop-scanner
tail -f ${LOOP_LOG_DIR}/loop-scanner.log
```

### "I want to take loop offline temporarily"

```bash
launchctl unload ~/Library/LaunchAgents/com.user.loop-scanner.plist
# in-flight handlers continue; no new work emitted
```

To resume:
```bash
launchctl load ~/Library/LaunchAgents/com.user.loop-scanner.plist
```

## Reconciler branch matching

Reconciler sweeps (`reconcile_ci_red_prs`, `reconcile_ci_green_prs`, `reconcile_pr_base_moved`) identify loop-opened PRs by matching their head branch against a regex.

- **`LOOP_BRANCH_PATTERN`** (default `^(?:feat|fix|chore|docs)/issue-(\d+)-`) — full regex. Capture group 1 must be the issue number. Override this if your project uses a different convention.
- **`LOOP_BRANCH_PREFIX`** (legacy) — single-prefix shortcut. If set and non-empty, it overrides `LOOP_BRANCH_PATTERN` and is interpreted as `^<escaped-prefix>(\d+)-`. Prefer `LOOP_BRANCH_PATTERN` for new setups.

If a PR's head branch does not match, all three sweeps will silently ignore it (no auto-promote, no auto-rework, no auto-rebase).

## Quick verification

After any recovery action, confirm loop is alive and processing:

```bash
# Scanner heartbeat — should show a recent tick
tail -20 ${LOOP_LOG_DIR}/loop-scanner.log

# Active handlers — should match expectations
pgrep -af 'po-handler|dev-handler|qa-handler|review-handler|merge-handler|dev-rework-handler'

# Today's spend (if budget is enabled)
cat "${LOOP_LOG_DIR}/budget/$(date +%Y%m%d).counter" 2>/dev/null || echo "budget not yet tallied today"
```
