#!/usr/bin/env bash
# lock.sh — per-project serialization for Loop handlers.
#
# Ensures only one handler at a time touches a given project's state
# (shared git tree before worktree isolation, GitHub rate bucket, label race
# windows, retry counters). Handlers waiting for the lock poll every few
# seconds; stale locks (PID not alive) are stolen automatically so a crashed
# worker can't jam the queue.
#
# Cross-project is NOT serialized — two different slugs can hold two locks
# simultaneously. This matches the intended concurrency model:
# "same machine + same repo → one at a time per repo".
#
# Usage:
#   source "$LOOP_ROOT/lib/lock.sh"
#   loop_acquire_lock "$SLUG" || { log "lock timeout"; exit 1; }
#   # ... do work ...
#   # lock auto-releases on EXIT via trap

LOOP_LOCK_DIR="${LOOP_LOCK_DIR:-/tmp/loop-locks}"
# Lock TTL: steal locks held longer than this (in seconds). Kills holder PID.
# Mirrors LOOP_HANDLER_TIMEOUT so a timed-out handler's lock is never permanent.
LOOP_LOCK_TTL="${LOOP_LOCK_TTL:-7200}"
mkdir -p "$LOOP_LOCK_DIR"

# loop_acquire_lock <slug> [max_wait_seconds]
loop_acquire_lock() {
    local slug="$1"
    local max_wait="${2:-3600}"  # 1hr default ceiling
    local lock_file="$LOOP_LOCK_DIR/${slug}.lock"
    local waited=0

    while true; do
        # Atomic create-with-exclusive — the canonical shell lock pattern
        if ( set -o noclobber; echo "$$" > "$lock_file" ) 2>/dev/null; then
            # shellcheck disable=SC2064
            trap "loop_release_lock '$slug'" EXIT INT TERM
            return 0
        fi

        # Lock exists — is the holder still alive?
        local holder_pid
        holder_pid=$(cat "$lock_file" 2>/dev/null || echo "")
        if [ -z "$holder_pid" ] || ! kill -0 "$holder_pid" 2>/dev/null; then
            # Holder is dead or PID absent — log and steal the lock
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [lock] WARN: stale lock ${lock_file} (PID '${holder_pid}' not alive) — reclaiming" >&2
            rm -f "$lock_file"
            continue
        fi

        # Holder alive but past TTL — kill it and steal the lock
        if [ -n "$holder_pid" ] && [ -f "$lock_file" ]; then
            local lock_age
            lock_age=$(python3 -c "import os,sys,time; print(int(time.time()-os.stat(sys.argv[1]).st_mtime))" "$lock_file" 2>/dev/null || echo 0)
            if [ "$lock_age" -gt "$LOOP_LOCK_TTL" ]; then
                kill "$holder_pid" 2>/dev/null || true
                if [ "$(cat "$lock_file" 2>/dev/null || echo)" = "$holder_pid" ]; then
                    rm -f "$lock_file"
                fi
                continue
            fi
        fi

        # Legitimate holder within TTL — wait
        if [ "$waited" -ge "$max_wait" ]; then
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

# loop_release_lock <slug>
loop_release_lock() {
    local slug="$1"
    local lock_file="$LOOP_LOCK_DIR/${slug}.lock"
    # Only release if we own it (avoid yanking someone else's lock on weird exit ordering)
    if [ -f "$lock_file" ] && [ "$(cat "$lock_file" 2>/dev/null || echo)" = "$$" ]; then
        rm -f "$lock_file"
    fi
}
