# Mole ⇄ Burrow JSON Events (NDJSON) — Contract v1

This document defines the **public, stable** JSON event stream contract emitted by Mole and consumed by Burrow.

It is the canonical source of truth for:
- JSON mode enablement (`MOLE_OUTPUT=json`)
- NDJSON envelope fields and invariants
- Event taxonomy and per-event payload schemas
- Ordering and compatibility rules

## 1. Enablement and I/O Rules

### 1.1 Enable JSON mode

Set:

```bash
MOLE_OUTPUT=json
```

### 1.1.1 Non-interactive contract modes (shell commands)

For shell-based operations, the JSON contract is exposed via additive flags:
- `--json-scan` — non-destructive scan/preview emitting NDJSON events
- `--apply <manifest.json>` — apply user selections from a JSON selection manifest

These flags are ignored by older Mole versions and MUST NOT change behavior when JSON mode is disabled.
In Mole, these flags are only supported when JSON mode is enabled; if they are provided without `MOLE_OUTPUT=json`,
Mole will exit with an error to prevent ambiguous behavior.

### 1.2 Output streams

When JSON mode is enabled:
- **stdout** MUST contain **NDJSON only**:
  - exactly **one JSON object per line**
  - no multi-line JSON
  - no ANSI escape sequences, cursor control, spinners, or human UI
- **stderr** MAY contain human-readable diagnostics and logs.

### 1.3 Forward compatibility

Consumers MUST:
- ignore unknown top-level fields
- ignore unknown fields inside `data`
- ignore unknown event types (treat as “unsupported”)

Producers MUST:
- never repurpose existing fields with different meaning
- only add new fields (additive changes)

## 2. Envelope (required on every line)

Each NDJSON line is a JSON object with this envelope:

```json
{
  "schema_version": 1,
  "operation": "clean",
  "event": "operation_start",
  "timestamp": "2026-02-03T18:22:11Z",
  "seq": 1,
  "run_id": "2f1c2c58-54a8-4c3b-8a3c-2a2a26b0b2a8",
  "data": {}
}
```

### 2.1 Fields

- `schema_version` (int): current schema major version. Starts at `1`.
- `operation` (string enum): `clean|uninstall|analyze|status|optimize|purge|installer`
- `event` (string): event discriminator (see Section 3).
- `timestamp` (RFC3339 string): event emission time (UTC).
- `seq` (int): monotonically increasing per process, starts at `1`.
- `run_id` (uuid string): unique ID per process run.
- `data` (object): event-specific payload (may be `{}`).

## 3. Event Taxonomy (v1)

### 3.1 Global (all operations)

#### `operation_start`

```json
{
  "event": "operation_start",
  "data": {
    "mode": "scan",
    "argv": ["mo", "clean", "--json-scan"],
    "dry_run": true
  }
}
```

- `mode` (string enum): `scan|apply`
- `argv` (array[string]): argv as seen by Mole
- `dry_run` (bool)

#### `operation_complete`

```json
{
  "event": "operation_complete",
  "data": {
    "success": true,
    "canceled": false,
    "exit_code": 0,
    "duration_ms": 1234,
    "counts": {"items": 120, "skipped": 3, "failed": 1},
    "totals": {"size_bytes": 4567890}
  }
}
```

Required:
- `success` (bool)

Optional:
- `canceled` (bool)
- `exit_code` (int)
- `duration_ms` (int)
- `counts` (object)
- `totals` (object)

#### `warning` / `error`

```json
{
  "event": "error",
  "data": {
    "code": "permission_denied",
    "message": "Access denied to path.",
    "path": "/path/to/file"
  }
}
```

Required:
- `code` (string enum):
  `permission_denied|in_use|not_found|auth_failed|sip_protected|readonly_filesystem|timeout|canceled|unknown`
- `message` (string)

Optional:
- `path` (string)
- `bundle_id` (string)
- `action` (string)
- `detail` (string)

### 3.2 Clean (`mo clean`)

Scan mode (`--json-scan`):
- `section_start`: `{ "name": "User essentials" }`
- `item_found`: `{ "path": "/...", "category": "...", "size_bytes": 123, "age_days": 30?, "source": "user|system|external"?, "protected": bool? }`
- `section_complete`: `{ "name": "...", "item_count": n, "total_size_bytes": m }`
- `summary`: `{ "item_count": n, "total_size_bytes": m, "whitelist_skipped_count": k?, "permission_denied_count": p? }`

Apply mode (`--apply <manifest>`):
- `item_cleaned`: `{ "path": "/...", "size_bytes": 123 }`
- `item_skipped`: `{ "path": "/...", "reason": "protected|whitelist|missing|permission_denied|in_use|unknown" }`
- `item_failed`: `{ "path": "/...", "reason": "...", "message": "..."? }`

### 3.3 Uninstall (`mo uninstall`)

Scan mode (`--json-scan`):
- `app_found`: `{ "name": "Slack", "bundle_id": "...", "path": "...", "size_bytes": 123, "last_used_epoch": 1700000000?, "last_used_label": "Today|..."? }`
- `summary`: `{ "app_count": n }`

Apply mode (`--apply <manifest>`):
- `app_removed`: `{ "bundle_id": "...", "path": "...", "size_bytes": 123? }`
- `leftover_removed|leftover_skipped|leftover_failed` (optional; same shape as clean item events)

### 3.4 Optimize (`mo optimize`)

Scan mode (`--json-scan`):
- `optimization_available`: `{ "category": "system", "action": "...", "name": "...", "description": "...", "safe": true }`
- `summary`: `{ "count": n }`

Apply mode (`--apply <manifest>`):
- `optimization_start`: `{ "action": "...", "name": "..." }`
- `optimization_complete`: `{ "action": "...", "success": true, "message": "..."? }`

### 3.5 Purge (`mo purge`)

Scan mode (`--json-scan`):
- `purge_path`: `{ "root": "/Users/.../Code", "source": "config|auto" }`
- `artifact_found`: `{ "path": "/.../node_modules", "project_root": "/.../MyProj", "project_name": "MyProj", "artifact_type": "node_modules|target|...", "size_bytes": 123, "recently_modified": false }`
- `summary`: `{ "artifact_count": n, "total_size_bytes": m }`

Apply mode (`--apply <manifest>`):
- `artifact_removed|artifact_skipped|artifact_failed` (same shape as clean item events)

### 3.6 Installer (`mo installer`)

Scan mode (`--json-scan`):
- `installer_found`: `{ "path": "/.../file.dmg", "display_name": "file.dmg", "source": "Downloads|Desktop|Homebrew|...", "size_bytes": 123 }`
- `summary`: `{ "installer_count": n, "total_size_bytes": m }`

Apply mode (`--apply <manifest>`):
- `installer_removed|installer_skipped|installer_failed` (same shape as clean item events)

### 3.7 Analyze (`mo analyze`)

JSON mode is always “scan” (no apply in v1):
- `analyze_start`: `{ "target_path": "/abs/path" }`
- `analyze_progress` (optional, rate-limited):
  `{ "files_scanned": n, "dirs_scanned": n, "bytes_scanned": n, "current_path": "/..."? }`
- `analyze_entry`:
  `{ "parent_path": "/abs/path", "name": "Library", "path": "/abs/path/Library", "is_dir": true, "size_bytes": 123 }`
- `analyze_large_file`:
  `{ "parent_path": "/abs/path", "name": "movie.mov", "path": "...", "size_bytes": 123 }`
- `analyze_complete`:
  `{ "target_path": "...", "total_size_bytes": n, "entry_count": n, "large_file_count": n }`

### 3.8 Status (`mo status`)

Stream mode:
- `status_start`: `{ "interval_ms": 1000, "host": "...", "platform": "...", "hardware": {...} }`
- `status_snapshot`: `{ "collected_at": "...", "health_score": 92, "cpu": {...}, "memory": {...}, "disks": [...], "network": [...], "top_processes": [...] }`
- `status_complete` (optional) on graceful stop

## 4. Ordering and Termination Rules

- `seq` MUST strictly increase by 1 for every emitted line.
- `operation_start` MUST be emitted before any operation-specific events.
- `operation_complete` MUST be emitted once, as the final event, except for abrupt termination (SIGKILL).
