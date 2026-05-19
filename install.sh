#!/usr/bin/env bash
# install.sh — Add a project to the Loop pipeline, or bootstrap the toolchain.
#
# Usage:
#   ./install.sh --bootstrap                 # first-time setup: checks tools, writes loop.env,
#                                            # registers scanner + reconciler (launchd/cron)
#   ./install.sh <project-path>              # interactive setup
#   ./install.sh <project-path> --auto       # auto-detect everything from git
#
# --bootstrap checks (idempotent):
#   1. gh CLI authenticated
#   2. python3 + pyyaml installed
#   3. at least one agent CLI present (claude / codex / gemini / aider)
#   4. writes loop.env from loop.env.example (skips if already exists)
#   5. writes config/projects.yaml from config/projects.example.yaml (skips if already exists)
#   6. macOS: installs launchd plists for scanner (KeepAlive) + reconciler (15 min)
#      Linux:  adds crontab entries (scanner */5, reconciler */15)
#
# --bootstrap is independent of <project-path> / --auto.
# After bootstrap, run ./install.sh <project-path> [--auto] for each project.
#
# What it does NOT touch:
#   - CLAUDE.md (project-owned, never templated)
#   - Existing loop.env (never overwritten)
#   - Existing config/projects.yaml (never overwritten — operator-specific, gitignored)
#   - Any launchd plists (macOS; scanner handles all projects)
#   - Existing labels (only creates missing ones)
#
# Requirements:
#   - gh CLI authenticated
#   - python3 + pyyaml

set -euo pipefail

LOOP_ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_YAML="$LOOP_ROOT/config/projects.yaml"

AUTO_MODE=false
BOOTSTRAP_MODE=false
BACKEND_MODE="github"
PROJECT_PATH=""

# ─────────────────────────────────────────────────────────────────────────────
# Bootstrap helpers — invoked only when --bootstrap is passed
# ─────────────────────────────────────────────────────────────────────────────

# Check required toolchain. Returns 1 if any hard requirement is missing.
bootstrap_check_tools() {
    local ok=true
    echo "[check] Verifying required tools..."

    if ! command -v gh >/dev/null 2>&1; then
        echo "  [fail] 'gh' not found — install from https://cli.github.com/" >&2
        ok=false
    elif ! gh auth status >/dev/null 2>&1; then
        echo "  [fail] 'gh' not authenticated — run: gh auth login" >&2
        ok=false
    else
        echo "  [ok]   gh authenticated"
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "  [fail] 'python3' not found" >&2
        ok=false
    elif ! python3 -c "import yaml" 2>/dev/null; then
        echo "  [fail] python3 'pyyaml' not installed — run: pip3 install pyyaml" >&2
        ok=false
    else
        echo "  [ok]   python3 + pyyaml"
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo "  [fail] 'sqlite3' not found — install it:" >&2
        echo "           macOS:  brew install sqlite" >&2
        echo "           Debian/Ubuntu: apt install sqlite3" >&2
        ok=false
    else
        local sqlite_version
        sqlite_version=$(sqlite3 --version 2>/dev/null | awk '{print $1}')
        echo "  [ok]   sqlite3 $sqlite_version (need >= 3.35.0 for RETURNING)"
    fi

    local agent_found=false
    local _agent
    for _agent in claude codex gemini aider; do
        if command -v "$_agent" >/dev/null 2>&1; then
            echo "  [ok]   agent CLI: $_agent"
            agent_found=true
            break
        fi
    done
    if ! $agent_found; then
        echo "  [warn] no standard agent CLI found (claude/codex/gemini/aider)" >&2
        echo "         configure LOOP_AGENT_CMD in loop.env to use a custom agent" >&2
    fi

    echo
    [ "$ok" = "true" ]
}

# Detect the first available agent CLI and write LOOP_AGENT to loop.env.
# If LOOP_AGENT is already set in the environment, honour it without probing PATH.
# Returns 1 if no agent is found.
bootstrap_detect_agent() {
    local env_file="$LOOP_ROOT/loop.env"
    local detected=""
    local _agent

    # Honour explicit env override — do not probe PATH when the caller already
    # knows which agent to use.
    if [ -n "${LOOP_AGENT:-}" ]; then
        detected="$LOOP_AGENT"
        echo "[agent] Using LOOP_AGENT from environment: $detected"
        if [ -f "$env_file" ]; then
            if grep -q '^LOOP_AGENT=' "$env_file"; then
                python3 - "$env_file" "$detected" <<'PY'
import sys, re
path, agent = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
content = re.sub(r'^LOOP_AGENT=.*$', f'LOOP_AGENT="{agent}"', content, flags=re.MULTILINE)
with open(path, 'w') as f:
    f.write(content)
PY
                echo "[agent] Updated LOOP_AGENT=\"$detected\" in loop.env"
            else
                echo "LOOP_AGENT=\"$detected\"" >> "$env_file"
                echo "[agent] Appended LOOP_AGENT=\"$detected\" to loop.env"
            fi
        else
            echo "LOOP_AGENT=\"$detected\"" > "$env_file"
            echo "[agent] Created loop.env with LOOP_AGENT=\"$detected\""
        fi
        return 0
    fi

    for _agent in claude codex gemini aider; do
        if command -v "$_agent" >/dev/null 2>&1; then
            detected="$_agent"
            break
        fi
    done

    if [ -z "$detected" ]; then
        cat >&2 <<'ERR'
[agent] ERROR: No supported agent CLI found in PATH.
        Install one of the following, then re-run --bootstrap:
          - claude   https://docs.anthropic.com/en/docs/claude-code
          - codex    https://github.com/openai/codex
          - gemini   https://github.com/google-gemini/gemini-cli
          - aider    https://aider.chat

        To override: LOOP_AGENT=<name> ./install.sh --bootstrap
ERR
        return 1
    fi

    echo "[agent] Detected: $detected"

    # Write or update LOOP_AGENT in loop.env
    if [ -f "$env_file" ]; then
        if grep -q '^LOOP_AGENT=' "$env_file"; then
            # Replace existing value
            python3 - "$env_file" "$detected" <<'PY'
import sys, re
path, agent = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
content = re.sub(r'^LOOP_AGENT=.*$', f'LOOP_AGENT="{agent}"', content, flags=re.MULTILINE)
with open(path, 'w') as f:
    f.write(content)
PY
            echo "[agent] Updated LOOP_AGENT=\"$detected\" in loop.env"
        else
            echo "LOOP_AGENT=\"$detected\"" >> "$env_file"
            echo "[agent] Appended LOOP_AGENT=\"$detected\" to loop.env"
        fi
    else
        echo "LOOP_AGENT=\"$detected\"" > "$env_file"
        echo "[agent] Created loop.env with LOOP_AGENT=\"$detected\""
    fi

    echo "[agent] To override: LOOP_AGENT=<other> ./install.sh --bootstrap"
    echo "        Available: claude, codex, gemini, aider"
}

# Write loop.env from loop.env.example (skips if already exists).
# Substitutes ${HOME} with the actual home directory for launchd/cron safety.
bootstrap_write_env() {
    local env_file="$LOOP_ROOT/loop.env"
    local example="$LOOP_ROOT/loop.env.example"

    if [ -f "$env_file" ]; then
        echo "[env] loop.env already exists — skipping"
        return 0
    fi

    if [ ! -f "$example" ]; then
        echo "[env] WARNING: loop.env.example not found — skipping" >&2
        return 0
    fi

    python3 - "$example" "$env_file" "$HOME" <<'PY'
import sys
src, dst, home = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    content = f.read()
content = content.replace('${HOME}', home).replace('$HOME', home)
with open(dst, 'w') as f:
    f.write(content)
PY
    echo "[env] Created loop.env (HOME=$HOME)"
}

# Write config/projects.yaml from config/projects.example.yaml (skips if already exists).
# projects.yaml is operator-specific (gitignored); the example is the template.
bootstrap_write_projects_yaml() {
    local target="$LOOP_ROOT/config/projects.yaml"
    local example="$LOOP_ROOT/config/projects.example.yaml"

    if [ -f "$target" ]; then
        echo "[config] projects.yaml already exists — skipping"
        return 0
    fi

    if [ ! -f "$example" ]; then
        echo "[config] WARNING: projects.example.yaml not found — skipping" >&2
        return 0
    fi

    cp "$example" "$target"
    echo "[config] Created config/projects.yaml from example — edit it to register your projects"
}

# Read LOOP_LOG_DIR from loop.env (or use default).
bootstrap_resolve_log_dir() {
    local val=""
    if [ -f "$LOOP_ROOT/loop.env" ]; then
        val=$(grep '^LOOP_LOG_DIR=' "$LOOP_ROOT/loop.env" 2>/dev/null \
              | head -1 | cut -d= -f2- | tr -d '"')
        val="${val/\$\{HOME\}/$HOME}"
        val="${val/\$HOME/$HOME}"
    fi
    echo "${val:-$HOME/.loop/logs}"
}

# Read LOOP_EXTRA_PATH from loop.env (or use default).
bootstrap_resolve_extra_path() {
    local val=""
    if [ -f "$LOOP_ROOT/loop.env" ]; then
        val=$(grep '^LOOP_EXTRA_PATH=' "$LOOP_ROOT/loop.env" 2>/dev/null \
              | head -1 | cut -d= -f2- | tr -d '"')
    fi
    echo "${val:-/opt/homebrew/bin:/usr/local/bin}"
}

# Register scanner + reconciler via launchd (macOS). Idempotent: skips if plist exists.
bootstrap_register_launchd() {
    local log_dir="$1" extra_path="$2"
    local agents_dir="$HOME/Library/LaunchAgents"
    local template_dir="$LOOP_ROOT/templates/launchd"

    mkdir -p "$agents_dir"

    local scanner_plist="$agents_dir/com.user.loop-scanner.plist"
    local reconciler_plist="$agents_dir/com.user.loop-reconciler.plist"
    local reconcile_plist="$agents_dir/com.user.loop-reconcile.plist"

    # One-shot startup audit (RunAtLoad). Installed before scanner so it
    # fires once on agent load before the first scan tick.
    if [ -f "$reconcile_plist" ]; then
        echo "[launchd] com.user.loop-reconcile already registered — skipping"
    else
        sed \
            -e "s|__LOOP_ROOT__|$LOOP_ROOT|g" \
            -e "s|__LOG_DIR__|$log_dir|g" \
            -e "s|__HOME__|$HOME|g" \
            -e "s|__EXTRA_PATH__|$extra_path|g" \
            "$template_dir/com.user.loop-reconcile.plist.template" > "$reconcile_plist"
        if launchctl load "$reconcile_plist" 2>/dev/null; then
            echo "[launchd] com.user.loop-reconcile loaded (one-shot at load)"
        else
            echo "[launchd] WARNING: could not load com.user.loop-reconcile (check Console.app)" >&2
        fi
    fi

    if [ -f "$scanner_plist" ]; then
        echo "[launchd] com.user.loop-scanner already registered — skipping"
    else
        sed \
            -e "s|__LOOP_ROOT__|$LOOP_ROOT|g" \
            -e "s|__LOG_DIR__|$log_dir|g" \
            -e "s|__HOME__|$HOME|g" \
            -e "s|__EXTRA_PATH__|$extra_path|g" \
            "$template_dir/com.user.loop-scanner.plist.template" > "$scanner_plist"
        if launchctl load "$scanner_plist" 2>/dev/null; then
            echo "[launchd] com.user.loop-scanner loaded (KeepAlive)"
        else
            echo "[launchd] WARNING: could not load com.user.loop-scanner (check Console.app)" >&2
        fi
    fi

    if [ -f "$reconciler_plist" ]; then
        echo "[launchd] com.user.loop-reconciler already registered — skipping"
    else
        sed \
            -e "s|__LOOP_ROOT__|$LOOP_ROOT|g" \
            -e "s|__LOG_DIR__|$log_dir|g" \
            -e "s|__HOME__|$HOME|g" \
            -e "s|__EXTRA_PATH__|$extra_path|g" \
            "$template_dir/com.user.loop-reconciler.plist.template" > "$reconciler_plist"
        if launchctl load "$reconciler_plist" 2>/dev/null; then
            echo "[launchd] com.user.loop-reconciler loaded (every 15 min)"
        else
            echo "[launchd] WARNING: could not load com.user.loop-reconciler (check Console.app)" >&2
        fi
    fi

    # PR auto-rework watchdog — labels stale loop-authored PRs needs-rework so
    # the dev-rework handler picks them up. Independent of scanner; runs every
    # 15 min on its own cadence. Only acts on PRs whose author is in the
    # project's ALLOWED_AUTHORS, so disabled for any project that hasn't opted
    # into a loop bot account.
    local pr_watchdog_plist="$agents_dir/com.user.loop-pr-watchdog.plist"
    if [ -f "$pr_watchdog_plist" ]; then
        echo "[launchd] com.user.loop-pr-watchdog already registered — skipping"
    else
        sed \
            -e "s|__LOOP_ROOT__|$LOOP_ROOT|g" \
            -e "s|__LOG_DIR__|$log_dir|g" \
            -e "s|__HOME__|$HOME|g" \
            -e "s|__EXTRA_PATH__|$extra_path|g" \
            "$template_dir/com.user.loop-pr-watchdog.plist.template" > "$pr_watchdog_plist"
        if launchctl load "$pr_watchdog_plist" 2>/dev/null; then
            echo "[launchd] com.user.loop-pr-watchdog loaded (every 15 min)"
        else
            echo "[launchd] WARNING: could not load com.user.loop-pr-watchdog (check Console.app)" >&2
        fi
    fi

    # Scanner liveness watchdog — kills and restarts a wedged scanner process.
    # Fires every 5 min; considers the scanner stale if its heartbeat file is
    # older than 2× LOOP_SCANNER_INTERVAL (default 600s). KeepAlive on the
    # scanner plist means launchd restarts it automatically after the kill.
    local scanner_watchdog_plist="$agents_dir/com.user.loop-scanner-watchdog.plist"
    if [ -f "$scanner_watchdog_plist" ]; then
        echo "[launchd] com.user.loop-scanner-watchdog already registered — skipping"
    else
        sed \
            -e "s|__LOOP_ROOT__|$LOOP_ROOT|g" \
            -e "s|__LOG_DIR__|$log_dir|g" \
            -e "s|__HOME__|$HOME|g" \
            -e "s|__EXTRA_PATH__|$extra_path|g" \
            "$template_dir/com.user.loop-scanner-watchdog.plist.template" > "$scanner_watchdog_plist"
        if launchctl load "$scanner_watchdog_plist" 2>/dev/null; then
            echo "[launchd] com.user.loop-scanner-watchdog loaded (every 5 min)"
        else
            echo "[launchd] WARNING: could not load com.user.loop-scanner-watchdog (check Console.app)" >&2
        fi
    fi

    local digest_plist="$agents_dir/com.user.loop-digest.plist"
    if [ -f "$digest_plist" ]; then
        echo "[launchd] com.user.loop-digest already registered — skipping"
    else
        sed \
            -e "s|__LOOP_ROOT__|$LOOP_ROOT|g" \
            -e "s|__LOG_DIR__|$log_dir|g" \
            -e "s|__HOME__|$HOME|g" \
            -e "s|__EXTRA_PATH__|$extra_path|g" \
            "$template_dir/com.user.loop-digest.plist.template" > "$digest_plist"
        if launchctl load "$digest_plist" 2>/dev/null; then
            echo "[launchd] com.user.loop-digest loaded (08:00 + 18:00 daily)"
        else
            echo "[launchd] WARNING: could not load com.user.loop-digest (check Console.app)" >&2
        fi
    fi
}

# Register scanner + reconciler via crontab (Linux). Idempotent: skips if marker present.
bootstrap_register_cron() {
    local log_dir="$1"
    local scanner_marker="# loop-scanner"
    local reconciler_marker="# loop-reconciler"
    local scanner_watchdog_marker="# loop-scanner-watchdog"
    local scanner_entry="*/5 * * * * $LOOP_ROOT/scanner/scanner.sh --once >> $log_dir/loop-scanner.log 2>&1 $scanner_marker"
    local reconciler_entry="*/15 * * * * $LOOP_ROOT/scanner/reconciler.sh >> $log_dir/loop-reconciler.log 2>&1 $reconciler_marker"
    local scanner_watchdog_entry="*/5 * * * * $LOOP_ROOT/scanner/scanner-watchdog.sh >> $log_dir/loop-scanner-watchdog.log 2>&1 $scanner_watchdog_marker"

    local current_cron new_cron updated=false
    current_cron=$(crontab -l 2>/dev/null || true)
    new_cron="$current_cron"

    if echo "$current_cron" | grep -qF "$scanner_marker"; then
        echo "[cron] scanner entry already exists — skipping"
    else
        new_cron="${new_cron}"$'\n'"$scanner_entry"
        updated=true
        echo "[cron] Added scanner (*/5 min)"
    fi

    if echo "$current_cron" | grep -qF "$reconciler_marker"; then
        echo "[cron] reconciler entry already exists — skipping"
    else
        new_cron="${new_cron}"$'\n'"$reconciler_entry"
        updated=true
        echo "[cron] Added reconciler (*/15 min)"
    fi

    if echo "$current_cron" | grep -qF "$scanner_watchdog_marker"; then
        echo "[cron] scanner-watchdog entry already exists — skipping"
    else
        new_cron="${new_cron}"$'\n'"$scanner_watchdog_entry"
        updated=true
        echo "[cron] Added scanner-watchdog (*/5 min)"
    fi

    if $updated; then
        echo "$new_cron" | crontab -
        echo "[cron] crontab saved"
    fi
}

# Ensure scripts shipped without an executable bit (e.g., judge.sh on some
# checkouts) become executable. Idempotent.
bootstrap_chmod_scripts() {
    local f
    for f in "$LOOP_ROOT"/scripts/*.sh "$LOOP_ROOT"/scanner/*.sh; do
        [ -f "$f" ] || continue
        if [ ! -x "$f" ]; then
            chmod +x "$f"
            echo "[chmod] $(basename "$f") -> +x"
        fi
    done
}

# Register scanner + reconciler for the current OS.
bootstrap_register_services() {
    echo "[services] Registering scanner and reconciler..."
    local log_dir extra_path
    log_dir=$(bootstrap_resolve_log_dir)
    extra_path=$(bootstrap_resolve_extra_path)
    mkdir -p "$log_dir"
    mkdir -p "${LOOP_STATE_DIR:-$HOME/.loop/state}"

    if [ "$(uname -s)" = "Darwin" ]; then
        bootstrap_register_launchd "$log_dir" "$extra_path"
    else
        bootstrap_register_cron "$log_dir"
    fi
    echo
}

# Entry point for --bootstrap mode.
bootstrap_pipeline() {
    echo "═══════════════════════════════════════════════"
    echo " Loop — Bootstrap (first-time setup)"
    echo " Loop — the pack that ships."
    echo "═══════════════════════════════════════════════"
    echo

    bootstrap_check_tools || return 1
    bootstrap_write_env
    bootstrap_detect_agent || return 1
    bootstrap_write_projects_yaml
    bootstrap_chmod_scripts
    bootstrap_register_services

    local log_dir
    log_dir=$(bootstrap_resolve_log_dir)

    cat <<DONE
═══════════════════════════════════════════════
 Bootstrap complete!
═══════════════════════════════════════════════

Log paths:
  Scanner:    $log_dir/loop-scanner.log
  Reconciler: $log_dir/loop-reconciler.log
  Digest:     $log_dir/loop-digest.log

Next step:
  $0 /path/to/your/project

To check health:
  $0 status

DONE
}

# ─────────────────────────────────────────────────────────────────────────────
# Status subcommand — one-shot health check
# ─────────────────────────────────────────────────────────────────────────────

status_check() {
    local all_ok=true
    local env_file="$LOOP_ROOT/loop.env"

    echo "Loop Status"
    echo "─────────────────────────────────────────────────"

    # 1. loop.env present + LOOP_AGENT set
    if [ -f "$env_file" ]; then
        local agent_val
        agent_val=$(grep '^LOOP_AGENT=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
        if [ -n "$agent_val" ]; then
            echo "  [ok]  loop.env present, LOOP_AGENT=$agent_val"
        else
            echo "  [!!]  loop.env present but LOOP_AGENT not set"
            all_ok=false
        fi
    else
        echo "  [!!]  loop.env not found — run: ./install.sh --bootstrap"
        all_ok=false
        agent_val=""
    fi

    # 2. Agent CLI in PATH
    local _detected_agent=""
    if [ -f "$env_file" ]; then
        _detected_agent=$(grep '^LOOP_AGENT=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    fi
    if [ -n "$_detected_agent" ]; then
        if command -v "$_detected_agent" >/dev/null 2>&1; then
            echo "  [ok]  agent CLI '$_detected_agent' in PATH"
        else
            echo "  [!!]  agent CLI '$_detected_agent' not found in PATH"
            all_ok=false
        fi
    else
        local _found_agent=""
        local _a
        for _a in claude codex gemini aider; do
            if command -v "$_a" >/dev/null 2>&1; then
                _found_agent="$_a"
                break
            fi
        done
        if [ -n "$_found_agent" ]; then
            echo "  [ok]  agent CLI '$_found_agent' in PATH (LOOP_AGENT not set)"
        else
            echo "  [!!]  no agent CLI found (claude/codex/gemini/aider)"
            all_ok=false
        fi
    fi

    # 3. gh auth status
    if command -v gh >/dev/null 2>&1; then
        if gh auth status >/dev/null 2>&1; then
            echo "  [ok]  gh authenticated"
        else
            echo "  [!!]  gh not authenticated — run: gh auth login"
            all_ok=false
        fi
    else
        echo "  [!!]  gh CLI not found"
        all_ok=false
    fi

    # 4. Scanner running
    local scanner_running=false
    if [ "$(uname -s)" = "Darwin" ]; then
        if launchctl list 2>/dev/null | grep -q "com.user.loop-scanner"; then
            echo "  [ok]  scanner running (launchd)"
            scanner_running=true
        else
            echo "  [!!]  scanner not running — run: ./install.sh --bootstrap"
            all_ok=false
        fi
    else
        if crontab -l 2>/dev/null | grep -q "loop-scanner"; then
            echo "  [ok]  scanner registered (cron)"
            scanner_running=true
        else
            echo "  [!!]  scanner not registered — run: ./install.sh --bootstrap"
            all_ok=false
        fi
    fi

    # 5. Reconciler running
    if [ "$(uname -s)" = "Darwin" ]; then
        if launchctl list 2>/dev/null | grep -q "com.user.loop-reconciler"; then
            echo "  [ok]  reconciler running (launchd)"
        else
            echo "  [!!]  reconciler not running — run: ./install.sh --bootstrap"
            all_ok=false
        fi
    else
        if crontab -l 2>/dev/null | grep -q "loop-reconciler"; then
            echo "  [ok]  reconciler registered (cron)"
        else
            echo "  [!!]  reconciler not registered — run: ./install.sh --bootstrap"
            all_ok=false
        fi
    fi

    # 6. Latest scanner tick within 2x POLL_INTERVAL (default: 5 min → 10 min window)
    local log_dir
    log_dir=$(bootstrap_resolve_log_dir)
    local scanner_log="$log_dir/loop-scanner.log"
    if [ -f "$scanner_log" ]; then
        local poll_interval=300
        if [ -f "$env_file" ]; then
            local _pi
            _pi=$(grep '^POLL_INTERVAL=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
            [ -n "$_pi" ] && poll_interval="$_pi"
        fi
        local threshold=$(( poll_interval * 2 ))
        local last_modified
        last_modified=$(scanner_log="$scanner_log" python3 -c \
            "import os,time; p=os.environ['scanner_log']; print(int(time.time()-os.path.getmtime(p)))" \
            2>/dev/null || echo "9999")
        if [ "$last_modified" -le "$threshold" ] 2>/dev/null; then
            echo "  [ok]  scanner last tick ${last_modified}s ago (within ${threshold}s window)"
        else
            echo "  [!!]  scanner last tick ${last_modified}s ago — expected within ${threshold}s"
            all_ok=false
        fi
    elif $scanner_running; then
        echo "  [--]  scanner log not found yet (may not have ticked)"
    fi

    # 7. Registered projects accessible
    if [ -f "$PROJECTS_YAML" ] && command -v python3 >/dev/null 2>&1; then
        local slugs
        slugs=$(python3 -c "
import yaml, sys
with open('$PROJECTS_YAML') as f:
    data = yaml.safe_load(f) or {}
for p in (data.get('projects') or []):
    print(p.get('slug','') + '|' + p.get('repo','') + '|' + p.get('root',''))
" 2>/dev/null || true)
        if [ -z "$slugs" ]; then
            echo "  [--]  no projects registered"
        else
            while IFS='|' read -r _slug _repo _root; do
                [ -z "$_slug" ] && continue
                if [ -n "$_root" ] && [ ! -d "$_root" ]; then
                    echo "  [!!]  project '$_slug': root '$_root' not accessible"
                    all_ok=false
                elif [ -n "$_repo" ] && ! gh repo view "$_repo" >/dev/null 2>&1; then
                    echo "  [!!]  project '$_slug': repo '$_repo' not accessible via gh"
                    all_ok=false
                else
                    echo "  [ok]  project '$_slug' (${_repo:-?})"
                fi
            done <<< "$slugs"
        fi
    else
        echo "  [--]  config/projects.yaml not found — no projects registered"
    fi

    # 8. Author-gate digest — counter populated by reconciler each tick
    local agated_dir="$log_dir/author-gated"
    if [ -d "$agated_dir" ]; then
        local total_gated=0 _f _n
        for _f in "$agated_dir"/*.count; do
            [ -f "$_f" ] || continue
            _n=$(tr -d '[:space:]' < "$_f" 2>/dev/null || echo 0)
            [ -n "$_n" ] || _n=0
            total_gated=$(( total_gated + _n ))
        done
        echo "  [--]  author_gated_pending=$total_gated"
    fi

    echo "─────────────────────────────────────────────────"
    if $all_ok; then
        echo "  All checks passed."
        return 0
    else
        echo "  One or more checks failed. See above."
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Smoke test — kick scanner once after project add, wait for slug in output
# ─────────────────────────────────────────────────────────────────────────────

smoke_test_scanner() {
    local slug="$1"
    local log_dir
    log_dir=$(bootstrap_resolve_log_dir)
    local scanner_log="$log_dir/loop-scanner.log"
    local scan_script="$LOOP_ROOT/scanner/scanner.sh"
    local timeout_secs=30

    echo
    echo "[smoke] Kicking scanner once to verify it picks up '$slug'..."

    # Run one scan in background, capturing output
    local scan_out="$log_dir/smoke-test-$slug.log"
    mkdir -p "$log_dir"

    if [ ! -x "$scan_script" ]; then
        echo "[smoke] Scanner not executable — skipping smoke test"
        return 0
    fi

    "$scan_script" --once >"$scan_out" 2>&1 &
    local scan_pid=$!

    local elapsed=0
    local found=false
    while [ $elapsed -lt $timeout_secs ]; do
        if grep -q "$slug" "$scan_out" 2>/dev/null; then
            found=true
            break
        fi
        if ! kill -0 $scan_pid 2>/dev/null; then
            # scanner finished — check one final time
            grep -q "$slug" "$scan_out" 2>/dev/null && found=true
            break
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done

    # Clean up background process if still running
    kill $scan_pid 2>/dev/null || true
    wait $scan_pid 2>/dev/null || true

    if $found; then
        local now
        now=$(date '+%H:%M:%S')
        echo "[smoke] Scanner picked up '$slug' at $now"
        rm -f "$scan_out"
    else
        # Persist the captured output to the scanner log so the path we show
        # the user actually contains the diagnostic information.
        if [ -s "$scan_out" ]; then
            cat "$scan_out" >> "$scanner_log"
        fi
        rm -f "$scan_out"
        echo "[smoke] WARNING: scanner did not pick up '$slug' in ${timeout_secs}s"
        echo "        See $scanner_log"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

STATUS_MODE=false

for arg in "$@"; do
    case "$arg" in
        --bootstrap) BOOTSTRAP_MODE=true ;;
        --auto) AUTO_MODE=true ;;
        --backend=*) BACKEND_MODE="${arg#--backend=}" ;;
        --version|-V)
            ver=$(tr -d '[:space:]' < "$LOOP_ROOT/VERSION" 2>/dev/null || echo "unknown")
            echo "Loop v${ver}"
            exit 0
            ;;
        -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
        status) STATUS_MODE=true ;;
        *) PROJECT_PATH="$arg" ;;
    esac
done

if $STATUS_MODE; then
    status_check
    exit $?
fi

if $BOOTSTRAP_MODE; then
    bootstrap_pipeline
    exit $?
fi

if [ -z "$PROJECT_PATH" ]; then
    echo "Usage: $0 <project-path> [--auto]" >&2
    echo "       $0 --bootstrap" >&2
    echo "       $0 status" >&2
    exit 2
fi
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"

echo "═══════════════════════════════════════════════"
echo " Loop — Add Project to Pipeline"
echo "═══════════════════════════════════════════════"
echo

# ─────────────────────────────────────────────────────────────────────────────
# 1. Detect project info
# ─────────────────────────────────────────────────────────────────────────────

REPO=$(git -C "$PROJECT_PATH" remote get-url origin 2>/dev/null \
    | sed -E 's|.*github.com[:/]([^/]+/[^.]+)(\.git)?$|\1|' || echo "")
DEFAULT_BRANCH=$(git -C "$PROJECT_PATH" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|refs/remotes/origin/||' || echo "main")
DEFAULT_SLUG=$(basename "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
DEFAULT_PREFIX=$(echo "$DEFAULT_SLUG" | tr '[:lower:]' '[:upper:]' | cut -c1-3)
DEFAULT_NAME=$(basename "$PROJECT_PATH")

# --auto is now the default when git root is detectable; fall back to interactive
# if auto-detect fails (e.g., git remote not found).
if ! $AUTO_MODE; then
    if git -C "$PROJECT_PATH" remote get-url origin >/dev/null 2>&1; then
        AUTO_MODE=true
    fi
fi

if $AUTO_MODE; then
    SLUG="$DEFAULT_SLUG"
    COMMIT_PREFIX="$DEFAULT_PREFIX"
    NAME="$DEFAULT_NAME"
    DEV_VALIDATION=""
    QA_VALIDATION=""
else
    echo "Project: $PROJECT_PATH"
    echo "Detected repo: $REPO"
    echo "Detected branch: $DEFAULT_BRANCH"
    echo
    read -rp "Repo (owner/name) [$REPO]: " input; REPO="${input:-$REPO}"
    read -rp "Slug (short id) [$DEFAULT_SLUG]: " input; SLUG="${input:-$DEFAULT_SLUG}"
    read -rp "Display name [$DEFAULT_NAME]: " input; NAME="${input:-$DEFAULT_NAME}"
    read -rp "Commit prefix [$DEFAULT_PREFIX]: " input; COMMIT_PREFIX="${input:-$DEFAULT_PREFIX}"
    read -rp "Default branch [$DEFAULT_BRANCH]: " input; DEFAULT_BRANCH="${input:-$DEFAULT_BRANCH}"
    read -rp "Dev validation command (blank to skip): " DEV_VALIDATION
    read -rp "QA validation command (blank to skip): " QA_VALIDATION
fi

[ -z "$REPO" ] && { echo "ERROR: Could not detect repo. Provide it manually." >&2; exit 2; }

echo
echo "Configuration:"
echo "  Name:     $NAME"
echo "  Slug:     $SLUG"
echo "  Repo:     $REPO"
echo "  Branch:   $DEFAULT_BRANCH"
echo "  Prefix:   $COMMIT_PREFIX"
echo "  Root:     $PROJECT_PATH"
[ -n "${DEV_VALIDATION:-}" ] && echo "  Dev cmd:  $DEV_VALIDATION"
[ -n "${QA_VALIDATION:-}" ] && echo "  QA cmd:   $QA_VALIDATION"
echo

if ! $AUTO_MODE; then
    read -rp "Proceed? [Y/n] " confirm
    [[ "${confirm:-Y}" =~ ^[Nn] ]] && { echo "Aborted."; exit 0; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1b. Jira-GitLab backend: validate Jira credentials and print config template
# ─────────────────────────────────────────────────────────────────────────────

if [ "$BACKEND_MODE" = "jira-gitlab" ]; then
    echo "─── Jira backend validation ──────────────────────"
    _missing=()
    [ -z "${JIRA_URL:-}"   ] && _missing+=("JIRA_URL")
    [ -z "${JIRA_USER:-}"  ] && _missing+=("JIRA_USER")
    [ -z "${JIRA_TOKEN:-}" ] && _missing+=("JIRA_TOKEN")

    if [ ${#_missing[@]} -gt 0 ]; then
        echo "ERROR: The following env vars are required for jira-gitlab backend:" >&2
        for _v in "${_missing[@]}"; do echo "  $_v" >&2; done
        cat >&2 <<'HINT'

Add them to loop.env before running install.sh:
  JIRA_URL=https://yourorg.atlassian.net
  JIRA_USER=you@example.com
  JIRA_TOKEN=<atlassian-api-token>
HINT
        exit 2
    fi

    echo "[jira] JIRA_URL=${JIRA_URL}"
    if curl -s -u "${JIRA_USER}:${JIRA_TOKEN}" \
            -H "Accept: application/json" \
            "${JIRA_URL}/rest/api/3/myself" \
            | jq -r '"[jira] Authenticated as " + .displayName' 2>/dev/null; then
        :
    else
        echo "[jira] WARNING: could not authenticate — check JIRA_USER and JIRA_TOKEN" >&2
    fi

    read -rp "Jira project key (e.g. PROJ): " _JIRA_KEY
    _JIRA_KEY="${_JIRA_KEY:-PROJ}"

    cat <<YAML

Add the following to your project entry in config/projects.yaml:

  backend: jira-gitlab
  backend_config:
    ticket_project: ${_JIRA_KEY}
    # Map each Loop canonical label to the Jira transition name.
    # List available transitions:
    #   curl -u \$JIRA_USER:\$JIRA_TOKEN \\
    #     \$JIRA_URL/rest/api/3/issue/${_JIRA_KEY}-1/transitions | jq '.transitions[]|.name'
    state_map:
      dev: "In Progress"
      in-progress: "In Progress"
      review-pending: "In Review"
      in-review: "In Review"
      ready-for-qa: "QA"
      qa-pass: "QA"
      qa-fail: "In Progress"
      done: "Done"
      # Escape-hatch: transitions to JIRA_BLOCKED_STATUS or falls back to a comment
      needs-clarification: "Blocked"
      changes-requested: "Blocked"
      blocked: "Blocked"

YAML
    echo "──────────────────────────────────────────────────"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Add to projects.yaml (idempotent)
# ─────────────────────────────────────────────────────────────────────────────

ALREADY_EXISTS=$(python3 -c "
import yaml, sys
with open('$PROJECTS_YAML') as f:
    data = yaml.safe_load(f) or {}
slugs = [p.get('slug') for p in data.get('projects', []) or []]
print('yes' if '$SLUG' in slugs else 'no')
" 2>/dev/null)

if [ "$ALREADY_EXISTS" = "yes" ]; then
    echo "[projects.yaml] Slug '$SLUG' already exists — skipping"
else
    python3 - "$PROJECTS_YAML" "$SLUG" "$NAME" "$REPO" "$PROJECT_PATH" "$DEFAULT_BRANCH" "$COMMIT_PREFIX" "${DEV_VALIDATION:-}" "${QA_VALIDATION:-}" <<'PY'
import yaml, sys

cfg_path = sys.argv[1]
slug, name, repo, root, branch, prefix = sys.argv[2:8]
dev_cmd = sys.argv[8] if len(sys.argv) > 8 else ""
qa_cmd = sys.argv[9] if len(sys.argv) > 9 else ""

with open(cfg_path) as f:
    data = yaml.safe_load(f) or {}

if 'projects' not in data or data['projects'] is None:
    data['projects'] = []

entry = {
    'name': name,
    'slug': slug,
    'repo': repo,
    'root': root,
    'default_branch': branch,
    'dev': {'commit_prefix': prefix},
    'merge': {'strategy': 'squash', 'auto_rebase': True},
}
if dev_cmd:
    entry['dev']['validation_cmd'] = dev_cmd
if qa_cmd:
    entry['qa'] = {'validation_cmd': qa_cmd}

data['projects'].append(entry)

with open(cfg_path, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
PY
    echo "[projects.yaml] Added '$SLUG' to $PROJECTS_YAML"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2b. Validate projects.yaml
# ─────────────────────────────────────────────────────────────────────────────

if [ -x "$LOOP_ROOT/scripts/validate-config.sh" ]; then
    "$LOOP_ROOT/scripts/validate-config.sh" "$PROJECTS_YAML" \
        || { echo "ERROR: projects.yaml validation failed — fix the errors above before continuing." >&2; exit 2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Create canonical labels (idempotent)
# ─────────────────────────────────────────────────────────────────────────────

labels_spec=(
    "po-review|1D76DB|PO agent expands rough idea into full spec"
    "dev|0075CA|[deprecated: use plan] Automated dev cycle"
    "plan|0075CA|Issue ready for automated dev cycle"
    "in-progress|FFA500|[deprecated: use build] Currently being worked on"
    "build|FFA500|Currently being built by dev agent"
    "review-pending|9370DB|[deprecated: use needs-review] PR open, waiting for review"
    "needs-review|9370DB|PR open, waiting for automated review"
    "in-review|6A5ACD|Reviewer is looking at it"
    "ready-for-qa|FFD700|[deprecated: use needs-qa] Approved, needs QA"
    "needs-qa|FFD700|Approved by reviewer, needs QA validation"
    "qa-pass|32CD32|[deprecated: use approved] QA passed, ready to merge"
    "approved|32CD32|QA passed, approved for merge"
    "qa-fail|DC143C|[deprecated: use qa-failed] QA failed, back to dev"
    "qa-failed|DC143C|QA validation failed, back to dev for rework"
    "changes-requested|FFA07A|[deprecated: use needs-rework] Reviewer requested changes"
    "needs-rework|FFA07A|Reviewer requested changes, needs rework"
    "blocked|8B0000|Failed 3x, needs human"
    "operator-approved|2EA043|Override the author allow-list for this single ticket (see docs/security.md)"
    "needs-clarification|FF69B4|Dev hit ambiguity"
    "done|006400|Merged and closed"
    "semver:major|b60205|Bump major version on next release"
    "semver:minor|0075ca|Bump minor version on next release"
    "release-pr|0075ca|Automated release PR"
)

if [ "$BACKEND_MODE" = "gitlab" ] || [ "$BACKEND_MODE" = "jira-gitlab" ]; then
    if ! command -v glab >/dev/null 2>&1; then
        echo "[labels] WARNING: glab CLI not found — skipping label creation" >&2
        echo "         Install from https://gitlab.com/gitlab-org/cli or https://github.com/cli/go-gh" >&2
    else
        echo -n "[labels] Creating on $REPO (gitlab): "
        for spec in "${labels_spec[@]}"; do
            name="${spec%%|*}"; rest="${spec#*|}"
            color="${rest%%|*}"; desc="${rest#*|}"
            if glab label create --repo "$REPO" --name "$name" \
                    --color "#$color" --description "$desc" 2>/dev/null; then
                echo -n "+"
            else
                echo -n "."
            fi
        done
        echo " done"
    fi
else
    echo -n "[labels] Creating on $REPO: "
    for spec in "${labels_spec[@]}"; do
        name="${spec%%|*}"; rest="${spec#*|}"
        color="${rest%%|*}"; desc="${rest#*|}"
        if gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" 2>/dev/null; then
            echo -n "+"
        else
            echo -n "."
        fi
    done
    echo " done"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Enable repo settings (idempotent)
# ─────────────────────────────────────────────────────────────────────────────

if [ "$BACKEND_MODE" = "gitlab" ] || [ "$BACKEND_MODE" = "jira-gitlab" ]; then
    echo "[repo] GitLab: configure auto-merge and branch deletion in project Settings > Merge Requests"
else
    gh api -X PATCH "/repos/$REPO" \
        -f allow_auto_merge=true \
        -f delete_branch_on_merge=true >/dev/null 2>&1 \
        && echo "[repo] auto-merge + delete-branch-on-merge enabled" \
        || echo "[repo] could not update settings (may need admin access)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Copy templates (idempotent, skip if already present)
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "$PROJECT_PATH/.github/ISSUE_TEMPLATE"

for f in "$LOOP_ROOT/templates/ISSUE_TEMPLATE/"*; do
    [ -e "$f" ] || continue
    target="$PROJECT_PATH/.github/ISSUE_TEMPLATE/$(basename "$f")"
    if [ ! -f "$target" ]; then
        cp "$f" "$target"
        echo "[template] .github/ISSUE_TEMPLATE/$(basename "$f")"
    fi
done

if [ -f "$LOOP_ROOT/templates/pull_request_template.md" ] && [ ! -f "$PROJECT_PATH/.github/pull_request_template.md" ]; then
    cp "$LOOP_ROOT/templates/pull_request_template.md" "$PROJECT_PATH/.github/pull_request_template.md"
    echo "[template] .github/pull_request_template.md"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Restart scanner (picks up new project on next tick)
# ─────────────────────────────────────────────────────────────────────────────

SCANNER_LOCK="/tmp/loop-scanner.lock"
if [ -f "$SCANNER_LOCK" ]; then
    kill "$(cat "$SCANNER_LOCK")" 2>/dev/null && echo "[scanner] restarted (will pick up $SLUG on next tick)" || true
else
    echo "[scanner] not running — will pick up $SLUG when it starts"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. Smoke test — kick scanner and verify it sees the new slug
# ─────────────────────────────────────────────────────────────────────────────

smoke_test_scanner "$SLUG"

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────

cat <<DONE

═══════════════════════════════════════════════
 ✓ Loop installed for: $NAME ($SLUG)
═══════════════════════════════════════════════

The scanner will pick up $SLUG within 5 minutes.

To start work:
  1. Create a GitHub issue with label 'dev' (or 'po-review' for rough ideas)
  2. The pipeline handles everything: dev → review → QA → merge

To monitor:
  tail -f ${LOOP_LOG_DIR:-$HOME/.loop/logs}/loop-scanner.log | grep $SLUG

Checklist:
  [ ] CLAUDE.md exists at $PROJECT_PATH/CLAUDE.md (project context for agents)
  [ ] Commit .github/ templates to the repo
  [ ] Verify scanner picks it up: grep $SLUG ${LOOP_LOG_DIR:-$HOME/.loop/logs}/loop-scanner.log

DONE
