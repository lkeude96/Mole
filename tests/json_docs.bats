#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    WORKSPACE_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"
    export WORKSPACE_ROOT
}

require_workspace_doc() {
    local doc_path="$1"
    [[ -f "$doc_path" ]] || skip "workspace-level Burrow docs are not present in this checkout"
}

@test "Burrow workflow verification uses canonical Mole JSON commands" {
    workflow_doc="$WORKSPACE_ROOT/burrow-workflow.md"
    require_workspace_doc "$workflow_doc"

    run grep -En -- '--dry-run|scan_start|scan_progress|scan_complete' "$workflow_doc"
    [ "$status" -eq 1 ]

    run grep -En -- 'clean --json-scan|uninstall --json-scan|optimize --json-scan|purge --json-scan|installer --json-scan' "$workflow_doc"
    [ "$status" -eq 0 ]
}

@test "Burrow spec points at the canonical Mole JSON contract" {
    spec_doc="$WORKSPACE_ROOT/burrow-spec.md"
    require_workspace_doc "$spec_doc"

    run grep -En -- '--dry-run|^\| .*scan_start|^\| .*scan_progress|^\| .*scan_complete' "$spec_doc"
    [ "$status" -eq 1 ]

    run grep -En -- '--json-scan|--apply|Mole/docs/json-events.md' "$spec_doc"
    [ "$status" -eq 0 ]
}

@test "Mole docs and schema describe the canonical status snapshot payload" {
    json_doc="$PROJECT_ROOT/docs/json-events.md"
    json_schema="$PROJECT_ROOT/docs/json-events.schema.json"

    run grep -En -- 'health_score_msg|gpu|disk_io|network_history|proxy|batteries|thermal|bluetooth_devices' "$json_doc" "$json_schema"
    [ "$status" -eq 0 ]
}
