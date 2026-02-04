# Mole JSON Selection Manifest — Contract v1

This document defines the **unidirectional apply input** Burrow passes to Mole when the user confirms changes.

It is a small JSON file consumed via:
- `--apply <path/to/manifest.json>`
- `--apply -` (read manifest from stdin; stdin is treated as a file stream only, not interactive control)

## 1. Top-level schema

```json
{
  "schema_version": 1,
  "operation": "clean",
  "run_id": "2f1c2c58-54a8-4c3b-8a3c-2a2a26b0b2a8",
  "payload": {
    "paths": ["/abs/path/to/item"]
  }
}
```

Required:
- `schema_version` = `1`
- `operation` = `clean|uninstall|optimize|purge|installer`
- `payload` (object), operation-specific

Optional:
- `run_id` (uuid): recommended for correlating apply requests

Unsupported in v1:
- `operation: analyze|status` (no apply)

## 2. Payload shapes

### 2.1 `clean`

```json
{ "paths": ["/abs/path", "..."] }
```

### 2.2 `uninstall`

```json
{
  "apps": [
    { "bundle_id": "com.example.App", "path": "/Applications/App.app" }
  ]
}
```

### 2.3 `optimize`

```json
{ "actions": ["dns_cache", "sqlite_vacuum"] }
```

### 2.4 `purge`

```json
{ "paths": ["/abs/path/to/node_modules", "/abs/path/to/target"] }
```

### 2.5 `installer`

```json
{ "paths": ["/abs/path/to/file.dmg", "/abs/path/to/file.zip"] }
```

