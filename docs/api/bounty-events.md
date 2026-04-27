# Bounty event API v1.0

Documents the versioned HTTP contract between loop's handlers and the
`loop-monitor` `/api/report` endpoint.

## Endpoint

```
POST /api/report
Content-Type: application/json
```

## Canonical payload example

```json
{
  "api": "1.0",
  "core_version": "0.1.0",
  "event": "dev_done",
  "role": "dev",
  "agent": "claude",
  "model": "sonnet",
  "project": "ppl",
  "issue_num": 42,
  "pr_num": 100,
  "detail": "optional human-readable note",
  "timestamp": "2026-04-27T04:00:00Z"
}
```

## Field semantics

| Field | Required | Type | Notes |
|---|---|---|---|
| `api` | yes | string `"<MAJOR>.<MINOR>"` | API version. Loop emits `1.0`. Monitor accepts `1.x`, rejects `2.x` with HTTP 426. |
| `core_version` | yes | string semver | Sender's loop core version, for telemetry. |
| `event` | yes | string | One of: `dev_start`, `dev_done`, `dev_failed`, `review_start`, `review_done`, `review_request_changes`, `qa_start`, `qa_pass`, `qa_fail`, `merge_start`, `merge_done`, `merge_conflict`, `merge_failed`, `po_start`, `po_done`, `po_failed`, `rework_start`, `rework_done`, `rework_failed` |
| `role` | optional | string | Free-form (e.g. `dev`, `reviewer`, `merger`, or future specialist names like `frontend`) |
| `agent` | optional | string | The agent CLI name (`claude`, `codex`, `gemini`, `aider`) |
| `model` | optional | string | Model id (`sonnet`, `opus`, `o4-mini`) |
| `project` | yes | string | Project slug from `projects.yaml` |
| `issue_num` | optional | integer | At least one of `issue_num` / `pr_num` required |
| `pr_num` | optional | integer | At least one of `issue_num` / `pr_num` required |
| `detail` | optional | string | Human-readable context (e.g. `attempt 2/3`, `merge conflict`) |
| `timestamp` | yes | string ISO 8601 UTC | e.g. `2026-04-27T04:00:00Z` |

## Versioning rules

- **Loop core** sends `api: "1.x"` always (`x` is bumped when adding optional fields; never breaking).
- **Loop-monitor** parses any `1.x` payload; unknown fields are ignored gracefully.
- **Loop-monitor** rejects `2.x` with HTTP 426 and body:
  ```json
  {"error":"version_unsupported","supported":["1.x"]}
  ```
- **Legacy clients** (no `api` field) are treated as `1.0` for v0.x compatibility; a deprecation warning is emitted in monitor logs.
