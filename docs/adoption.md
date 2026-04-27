# Loop Adoption Guide

Step-by-step reference for getting Loop running on a new machine or team.

---

## 1. Pick an Agent

Set `LOOP_AGENT` in `loop.env`. The agent must be installed and on your PATH.

| Value | CLI binary | Notes |
|-------|-----------|-------|
| `claude` *(default)* | `claude` | Best tool use; recommended |
| `codex` | `codex` | OpenAI Codex; uses full-auto mode |
| `gemini` | `gemini` | Google Gemini; uses sandbox mode |
| `aider` | `aider` | Git-native; supports many model backends |
| `custom` | your script | Set `LOOP_AGENT_CMD` to the path of your wrapper |

Model can be overridden per-agent with `LOOP_AGENT_MODEL`.

---

## 2. Pick a Notifier

Set `LOOP_NOTIFY` to the path of a bundled adapter (relative to the Loop root)
or any executable that accepts a single string argument.

| Adapter | File | Extra variable(s) required | Notes |
|---------|------|---------------------------|-------|
| Slack | `lib/notifiers/slack.sh` | `SLACK_WEBHOOK_URL` | Uses `curl`; exits 1 if URL unset |
| Stdout | `lib/notifiers/stdout.sh` | — | Timestamped lines; always succeeds |
| Email | `lib/notifiers/email.sh` | `LOOP_NOTIFY_EMAIL` | Uses `mail(1)`; warns and skips if not in PATH |

**Discord:** Discord's incoming webhooks are compatible with the Slack format.
Point `SLACK_WEBHOOK_URL` at your Discord webhook URL and use `lib/notifiers/slack.sh` — no extra code needed.

**Signal / other channels:** bring your own script. Any executable that reads
`$1` as the message body and exits 0 on success works. Set `LOOP_NOTIFY` to
its absolute path.

Leave `LOOP_NOTIFY` unset (or empty) to disable notifications.

---

## 3. Pick a Process Manager

The scanner and reconciler are plain shell scripts. Run them with whichever
process manager fits your environment.

### cron (any POSIX system)

```bash
# Edit your crontab
crontab -e
```

Add:
```
*/5  * * * * /path/to/loop/scanner/scanner.sh --once >> /tmp/loop-scanner.log 2>&1
*/15 * * * * /path/to/loop/scanner/reconciler.sh     >> /tmp/loop-reconciler.log 2>&1
```

Set `LOOP_EXTRA_PATH` in `loop.env` so cron's minimal PATH can find `gh`,
your agent CLI, and `python3`.

### launchd (macOS)

Create `~/Library/LaunchAgents/com.user.loop-scanner.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>com.user.loop-scanner</string>
  <key>ProgramArguments</key>
  <array>
    <string>/path/to/loop/scanner/scanner.sh</string>
  </array>
  <key>KeepAlive</key>         <true/>
  <key>StandardOutPath</key>   <string>/tmp/loop-scanner.log</string>
  <key>StandardErrorPath</key> <string>/tmp/loop-scanner.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.user.loop-scanner.plist
```

### systemd (Linux)

Create `/etc/systemd/system/loop-scanner.service`:

```ini
[Unit]
Description=Loop Scanner

[Service]
ExecStart=/path/to/loop/scanner/scanner.sh
Restart=always
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now loop-scanner
```

---

## 4. Add Your First Project

```bash
# Interactive (prompts for repo, branch, validation commands)
./install.sh /path/to/your/project

# Non-interactive (auto-detects from git remote)
./install.sh --auto /path/to/your/project
```

`install.sh` will:
1. Add the project to `config/projects.yaml`
2. Create Loop labels on the GitHub repo
3. Enable auto-merge and delete-branch-on-merge
4. Copy issue/PR templates into the repo

---

## 5. Verify the Pipeline

```bash
# 1. Confirm the scanner can read your project config
bash scanner/scanner.sh --once

# 2. Create a test issue
gh issue create --repo owner/your-repo \
    --title "Test Loop pipeline" \
    --label dev

# 3. Watch the logs
tail -f /tmp/loop-scanner.log

# 4. Confirm the issue transitions through the label lifecycle:
#    dev → in-progress → review-pending → in-review → ready-for-qa → qa-pass → done
```

If the pipeline stalls, run the reconciler manually:

```bash
bash scanner/reconciler.sh
```

Full label lifecycle: `docs/label-lifecycle.md`
