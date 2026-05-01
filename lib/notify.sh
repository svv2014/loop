#!/usr/bin/env bash
# lib/notify.sh — loop_notify() helper; evaluates LOOP_NOTIFY command fragment.
# Sourced by all handlers. No-ops silently when LOOP_NOTIFY is unset or empty.

loop_notify() {
    [ -n "${LOOP_NOTIFY:-}" ] && eval "$LOOP_NOTIFY" "$1" || true
}

# loop_notify_human_required <slug> <number> <label> [reason]
# Fire-and-forget operator notification when an issue lands on a human-decision
# label (needs-clarification / blocked). Opt-in: silent no-op when
# LOOP_NOTIFY_CHANNEL is unset. Dedup state file under
# $LOOP_LOG_DIR/notified/<slug>-<number>-<label> stores today's UTC date — same
# day skips re-fire, next day re-pings (covers parked tickets that linger).
# Errors in the underlying notifier are caught so a missing signal-cli/curl
# never aborts the calling handler.
loop_notify_human_required() {
    local slug="$1" number="$2" label="$3" reason="${4:-}"
    [ -n "${LOOP_NOTIFY_CHANNEL:-}" ] || return 0

    local today state_dir state_file
    today=$(date -u +%Y-%m-%d)
    state_dir="${LOOP_LOG_DIR:-${HOME}/.loop/logs}/notified"
    state_file="${state_dir}/${slug}-${number}-${label}"
    mkdir -p "$state_dir" 2>/dev/null || return 0

    if [ -f "$state_file" ] && [ "$(cat "$state_file" 2>/dev/null)" = "$today" ]; then
        return 0
    fi

    (
        local repo="${REPO:-}" title="" url="" last_comment=""
        if [ -n "$repo" ] && command -v backend_issue_view >/dev/null 2>&1; then
            title=$(backend_issue_view "$repo" "$number" --json title --jq .title 2>/dev/null || echo "")
            url=$(backend_issue_view "$repo" "$number" --json url --jq .url 2>/dev/null || echo "")
            last_comment=$(backend_issue_view "$repo" "$number" --json comments \
                --jq '[.comments[]?] | last | .body // ""' 2>/dev/null || echo "")
        fi
        [ -z "$url" ] && [ -n "$repo" ] && url="https://github.com/${repo}/issues/${number}"
        if [ "${#last_comment}" -gt 400 ]; then
            last_comment="${last_comment:0:400}…"
        fi

        local msg="🚧 [${slug}] #${number} ${label}: ${title:-(no title)}
${url}
Reason: ${reason:-${label}}"
        if [ -n "$last_comment" ]; then
            msg="${msg}
Last comment: ${last_comment}"
        fi
        loop_notify "$msg"
    ) >/dev/null 2>&1 || {
        if declare -F log >/dev/null 2>&1; then
            log "notify_human_required failed for ${slug}#${number} (${label})"
        fi
    }

    echo "$today" > "$state_file" 2>/dev/null || true
    return 0
}

# loop_notify_human_required_clear <slug> <number> <label>
# Removes the dedup file so a future re-transition to the same label re-notifies.
# Call wherever the human-decision label is stripped from an issue.
loop_notify_human_required_clear() {
    local slug="$1" number="$2" label="$3"
    rm -f "${LOOP_LOG_DIR:-${HOME}/.loop/logs}/notified/${slug}-${number}-${label}" 2>/dev/null || true
    return 0
}
