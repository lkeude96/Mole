#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    WORKSPACE_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"
    export WORKSPACE_ROOT
}

@test "Burrow workflow verification uses canonical Mole JSON commands" {
    workflow_doc="$WORKSPACE_ROOT/burrow-workflow.md"

    run bash -c "rg -n -- '--dry-run|scan_start|scan_progress|scan_complete' \"$workflow_doc\""
    [ "$status" -ne 0 ]

    run bash -c "rg -n -- 'clean --json-scan|uninstall --json-scan|optimize --json-scan|purge --json-scan|installer --json-scan' \"$workflow_doc\""
    [ "$status" -eq 0 ]
}

@test "Burrow spec points at the canonical Mole JSON contract" {
    spec_doc="$WORKSPACE_ROOT/burrow-spec.md"

    run bash -c "rg -n -- '--dry-run|^\\| .*scan_start|^\\| .*scan_progress|^\\| .*scan_complete' \"$spec_doc\""
    [ "$status" -ne 0 ]

    run bash -c "rg -n -- '--json-scan|--apply|Mole/docs/json-events.md' \"$spec_doc\""
    [ "$status" -eq 0 ]
}

@test "Mole docs and schema describe the canonical status snapshot payload" {
    json_doc="$PROJECT_ROOT/docs/json-events.md"
    json_schema="$PROJECT_ROOT/docs/json-events.schema.json"

    run bash -c "rg -n -- 'health_score_msg|gpu|disk_io|network_history|proxy|batteries|thermal|bluetooth_devices' \"$json_doc\" \"$json_schema\""
    [ "$status" -eq 0 ]
}
