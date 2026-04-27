# projects.yaml Reference

Full schema for `config/projects.yaml`. The file has exactly one top-level key:
`projects`, a list of project entries.

```yaml
projects:
  - name: string          # required, human-readable
    slug: string          # required, short lowercase identifier, unique per file
    repo: string          # required, "owner/name" form
    root: string          # required, absolute path to local checkout
    default_branch: string # required, "main" or "master"

    dev:
      commit_prefix: string  # required under dev. ALL-CAPS, used in commit titles [PREFIX-N].
      validation_cmd: string # optional. Multi-line shell. `{project_root}` substituted at runtime.

    qa:
      validation_cmd: string # optional. Runs in QA handler on the PR branch.
      browser_url: string    # optional. Injected into QA agent prompt.

    merge:
      strategy: string       # "squash" (default) | "merge" | "rebase"
      auto_rebase: bool      # default false. If true, merge-handler retries with --rebase on conflict.
```

## Field details

### `name`
Shown in logs and commit messages. Free-form.

### `slug`
Used in:
- Retry state files: `/tmp/loop-dev-retries-<slug>-<issue>`
- Log prefixes
- Event payloads

Keep it short (2–4 chars).

### `repo`
Must be in `owner/name` form — that's what `gh --repo` expects. No trailing slash, no `https://`.

### `root`
Absolute path on the local machine. The dev handler `cd`s here before running the agent. The agent reads `{root}/CLAUDE.md` first.

### `default_branch`
The base branch for new feature branches. Must match what GitHub reports.

### `dev.commit_prefix`
Example: `NTC`, `PA`, `PPL`. Produces `[NTC-42] fix: ...`.

### `dev.validation_cmd` (optional)
Shell fragment run by the dev agent after implementation but before opening the PR. Supports `{project_root}` placeholder. Example:

```yaml
validation_cmd: |
  cd {project_root}/server && ./gradlew build -x test
```

If omitted, the dev agent skips a formal validation step (it may still run its own).

### `qa.validation_cmd` (optional)
Shell fragment the QA handler runs against the PR branch. Non-zero exit → label `qa-fail`. Zero exit → label `qa-pass`.

### `qa.browser_url` (optional)
String injected into the QA agent prompt for UI smoke tests.

### `merge.strategy`
Maps 1:1 to `gh pr merge` flags:
- `squash` → `--squash`
- `merge` → `--merge`
- `rebase` → `--rebase`

### `merge.auto_rebase`
If `true` and a merge attempt fails, the merge handler retries with `--rebase`. If `false`, it bails.

## Example — minimal

```yaml
projects:
  - name: PPL Study
    slug: ppl
    repo: svv2014/ppl-study
    root: /path/to/your/project
    default_branch: main
    dev:
      commit_prefix: PPL
    merge:
      strategy: squash
      auto_rebase: true
```

## Example — full

See `config/projects.example.yaml`.
