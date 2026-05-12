#!/usr/bin/env bash
# lib/comments.sh — trusted-comment filter for agent prompts.
#
# Defends against prompt-injection via untrusted PR/issue comments on public
# repos. Only comments whose author is in ALLOWED_AUTHORS (or has maintainer-
# level authorAssociation per GitHub API) are allowed to reach agent prompts.
# External comments are surfaced only as "observer" metadata (author + first
# line), never with their full body.
#
# Trusted authorAssociation values (per GitHub API docs):
#   OWNER, MEMBER, COLLABORATOR — maintainer-level, always trusted.
# Untrusted (external): CONTRIBUTOR, FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, NONE.
# Bot accounts (login ending in [bot]) are treated as external unless the
# operator explicitly lists them in ALLOWED_AUTHORS.
#
# ALLOWED_AUTHORS: newline- or comma-separated list from loop.env (same format
# as used by lib/author_gate.sh). When unset, the trust set falls back to
# maintainer-level authorAssociation only — never an empty set.
#
# Public functions:
#   comments_fetch_trusted  <repo> <number>   → TSV: login\tassociation\tbody
#   comments_fetch_observers <repo> <number>  → TSV: login\tassociation\tfirst_line

# comments_fetch_trusted <repo> <number>
# Prints TSV rows for comments whose author is trusted.
comments_fetch_trusted() {
    local repo="$1" number="$2"
    _comments_filter_json "$repo" "$number" trusted
}

# comments_fetch_observers <repo> <number>
# Prints TSV rows for external (untrusted) comments — first line of body only.
comments_fetch_observers() {
    local repo="$1" number="$2"
    _comments_filter_json "$repo" "$number" observers
}

# _comments_filter_json <repo> <number> <mode>
# Internal: fetches comments via gh API and applies trust filter.
_comments_filter_json() {
    local repo="$1" number="$2" mode="$3"

    local raw_json
    raw_json=$(gh api "repos/${repo}/issues/${number}/comments" \
        --paginate 2>/dev/null || echo "[]")

    ALLOWED="${ALLOWED_AUTHORS:-}" MODE="$mode" COMMENTS="$raw_json" \
    python3 <<'PY'
import json, os, sys

allowed_raw = os.environ.get('ALLOWED', '')
mode        = os.environ.get('MODE', 'trusted')
comments    = json.loads(os.environ.get('COMMENTS', '[]') or '[]')

TRUSTED_ASSOCIATIONS = {'OWNER', 'MEMBER', 'COLLABORATOR'}

# Parse ALLOWED_AUTHORS — same split style as lib/author_gate.sh
# Supports both comma-separated and newline-separated.
allowed_authors = set()
for part in allowed_raw.replace('\n', ',').split(','):
    s = part.strip()
    if s:
        allowed_authors.add(s)


def is_trusted(login, assoc):
    """Return True when this commenter's content may reach an agent prompt."""
    # Bot accounts are external unless explicitly allow-listed.
    if login.endswith('[bot]') and login not in allowed_authors:
        return False
    if allowed_authors and login in allowed_authors:
        return True
    # No ALLOWED_AUTHORS configured — fall back to association only.
    return assoc in TRUSTED_ASSOCIATIONS


lines = []
for c in comments:
    user  = c.get('user') or {}
    login = (user.get('login') or '').strip()
    assoc = (c.get('author_association') or '').strip()
    body  = (c.get('body') or '').strip()

    trusted = is_trusted(login, assoc)

    if mode == 'trusted':
        if trusted:
            safe_body = body.replace('\t', ' ').replace('\r', '')
            lines.append(f'{login}\t{assoc}\t{safe_body}')
    else:  # observers
        if not trusted:
            first_line = body.split('\n')[0][:200].replace('\t', ' ')
            lines.append(f'{login}\t{assoc}\t{first_line}')

for line in lines:
    print(line)
PY
}
