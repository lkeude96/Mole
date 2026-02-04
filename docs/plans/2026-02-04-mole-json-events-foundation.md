# Mole JSON Events (NDJSON) — Foundation + Commit Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Land the JSON event stream contract and shared emitters as a “foundation” commit, then walk each command one-by-one with manual verification and per-command commits.

**Architecture:** Shell commands emit NDJSON via `lib/core/json_output.sh`. Go commands (`cmd/analyze`, `cmd/status`) emit NDJSON via `cmd/*/json_output.go`. When `MOLE_OUTPUT=json`, stdout is NDJSON-only and every run emits `operation_start` + `operation_complete`.

**Tech Stack:** Bash, jq, bats, Go.

## Foundation invariants (must hold before any commits)

1. **Enablement:** JSON mode only when `MOLE_OUTPUT=json`.
2. **Stdout purity:** In JSON mode, stdout is NDJSON-only (1 JSON object per line; no ANSI/spinners/logs).
3. **Envelope:** Every line includes `{schema_version, operation, event, timestamp, seq, run_id, data}`.
4. **Sequencing:** `seq` starts at 1 and increments by 1 per emitted line.
5. **Lifecycle:** Every JSON-mode invocation emits:
   - `operation_start` first
   - `operation_complete` last (even on invalid manifest / early error)
6. **Operation enum:** `clean|uninstall|analyze|status|optimize|purge|installer` matches docs.
7. **Forward compat:** Consumers ignore unknown fields/events; producers only add fields (no repurposing).

## Task 1: Confirm foundation files are present and wired

**Files:**
- Create/Verify: `lib/core/json_output.sh`
- Verify: `docs/json-events.md`
- Verify: `docs/json-events.schema.json`
- Verify: `bin/*.sh` source/call into JSON emitter functions
- Verify: `cmd/analyze/json_output.go`, `cmd/analyze/json_mode.go`
- Verify: `cmd/status/json_output.go`, `cmd/status/json_mode.go`

**Step 1: Quick grep for lifecycle events**

Run:
```bash
cd "Mole"
rg -n "operation_start|operation_complete" "bin" "cmd" "lib/core/json_output.sh"
```
Expected: each JSON-capable command has both start and complete paths.

**Step 2: Verify docs match implementation**

Checklist:
- `docs/json-events.md` operation enum includes all JSON operations.
- Event names in docs match what emitters produce.

## Task 2: Foundation verification run (no commits yet)

**Files:**
- Verify: `tests/cli.bats`
- Verify: `scripts/test.sh`

**Step 1: Run the full test runner**

Run:
```bash
cd "Mole"
bash "scripts/test.sh"
```
Expected: exit code 0. If Go tests fail due to missing cached modules, re-run after restoring module cache or run only bats tests locally.

**Step 2: Spot-check NDJSON for one shell command**

Run:
```bash
cd "Mole"
MOLE_OUTPUT=json MOLE_TEST_MODE=1 "./mo" clean --json-scan | head -n 5
```
Expected: valid JSON objects (one per line) with required envelope fields.

## Task 3: Split out the “foundation” commit (no per-command behavior changes yet)

**Goal:** Stage only shared infrastructure + contract + baseline tests that validate the contract across operations.

**Stage candidates:**
- `lib/core/json_output.sh`
- `docs/json-events.md`
- `docs/json-events.schema.json`
- `tests/cli.bats` (only the envelope/contract helpers + high-level contract tests)
- Any minimal wiring in `lib/core/common.sh` required to load JSON emitter

**Step 1: Interactive staging**

Run:
```bash
cd "Mole"
git add -p
```
Expected: foundation chunks staged; command-specific chunks left unstaged.

**Step 2: Re-run tests after staging split**

Run:
```bash
cd "Mole"
bash "scripts/test.sh"
```
Expected: still green.

**Step 3: Commit**

Commit message (suggested):
- `feat(json): add NDJSON contract + shared emitters`

## Task 4+: Walk commands one-by-one (manual verify + per-command commit)

For each command below:
1) run the manual command(s) in JSON mode (scan + apply where applicable),
2) verify expected event types appear,
3) stage only files for that command,
4) commit.

### Clean
- Scan: `MOLE_OUTPUT=json MOLE_TEST_MODE=1 "./mo" clean --json-scan`
- Apply: `MOLE_OUTPUT=json "./mo" clean --apply "/path/to/clean-manifest.json"`

### Uninstall
- Scan: `MOLE_OUTPUT=json "./mo" uninstall --json-scan`
- Apply: `MOLE_OUTPUT=json "./mo" uninstall --apply "/path/to/uninstall-manifest.json"`

### Optimize
- Scan: `MOLE_OUTPUT=json "./mo" optimize --json-scan`
- Apply: `MOLE_OUTPUT=json "./mo" optimize --apply "/path/to/optimize-manifest.json"`

### Purge
- Scan: `MOLE_OUTPUT=json "./mo" purge --json-scan`
- Apply: `MOLE_OUTPUT=json "./mo" purge --apply "/path/to/purge-manifest.json"`

### Installer
- Scan: `MOLE_OUTPUT=json "./mo" installer --json-scan`
- Apply: `MOLE_OUTPUT=json "./mo" installer --apply "/path/to/installer-manifest.json"`

### Analyze (Go)
- Dev run: `MOLE_OUTPUT=json go run "./cmd/analyze" "/some/path"`
- Release run: `MOLE_OUTPUT=json "./mo" analyze "/some/path"` (requires `bin/analyze-go`)

### Status (Go)
- Dev run: `MOLE_OUTPUT=json go run "./cmd/status"` (Ctrl-C to stop)
- Release run: `MOLE_OUTPUT=json "./mo" status` (requires `bin/status-go`)

