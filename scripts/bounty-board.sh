#!/usr/bin/env bash
# bounty-board.sh — print leaderboard from data/bounties.jsonl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOOP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BOUNTIES_FILE="${BOUNTIES_FILE:-${LOOP_ROOT}/data/bounties.jsonl}"

if [ ! -f "$BOUNTIES_FILE" ]; then
    echo "No bounties data found at $BOUNTIES_FILE"
    exit 0
fi

BOUNTIES_FILE="$BOUNTIES_FILE" python3 <<'PY'
import json, os
from collections import defaultdict

bounties_file = os.environ['BOUNTIES_FILE']

# key: (role, agent, model) → {bounties, points}
agg = defaultdict(lambda: {'bounties': 0, 'points': 0})
total_merges = 0

with open(bounties_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        total_merges += 1
        for role, info in rec.get('roles', {}).items():
            key = (role, info.get('agent', 'unknown'), info.get('model', 'unknown'))
            agg[key]['bounties'] += 1
            agg[key]['points']   += info.get('points', 0)

if not agg:
    print("No bounty records found.")
    exit()

rows = sorted(
    [{'role': k[0], 'agent_model': f"{k[1]}/{k[2]}",
      'bounties': v['bounties'], 'points': v['points']}
     for k, v in agg.items()],
    key=lambda r: (-r['points'], -r['bounties'], r['role'])
)

W = 51
print()
print("🏆 BOUNTY BOARD")
print("═" * W)
print(f"  {'Role':<12}{'Agent/Model':<22}{'Bounties':>8}  {'Points':>6}")
print("─" * W)
for r in rows:
    pts = f"+{r['points']}" if r['points'] >= 0 else str(r['points'])
    print(f"  {r['role']:<12}{r['agent_model']:<22}{r['bounties']:>8}  {pts:>6}")
print("═" * W)
print(f"  Total bounties collected: {total_merges}")
print()
PY
