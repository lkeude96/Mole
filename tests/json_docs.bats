#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

@test "Mole docs and schema describe the canonical status snapshot payload" {
    json_doc="$PROJECT_ROOT/docs/json-events.md"
    json_schema="$PROJECT_ROOT/docs/json-events.schema.json"

    run grep -En -- 'health_score_msg|gpu|disk_io|network_history|proxy|batteries|thermal|bluetooth_devices' "$json_doc" "$json_schema"
    [ "$status" -eq 0 ]
}

@test "status schema requires the Burrow-rendered snapshot fields" {
    json_schema="$PROJECT_ROOT/docs/json-events.schema.json"

    for field in \
        collected_at \
        health_score \
        health_score_msg \
        cpu \
        gpu \
        memory \
        disks \
        disk_io \
        network \
        network_history \
        proxy \
        batteries \
        thermal \
        bluetooth_devices \
        top_processes; do
        run jq -er --arg field "$field" \
            '.oneOf[] | select(.title=="Status status_snapshot") | .properties.data.required | index($field)' \
            "$json_schema"
        [ "$status" -eq 0 ]
    done
}

@test "status schema requires network history arrays in the snapshot contract" {
    json_schema="$PROJECT_ROOT/docs/json-events.schema.json"

    for field in rx_history tx_history; do
        run jq -er --arg field "$field" \
            '.oneOf[] | select(.title=="Status status_snapshot") | .properties.data.properties.network_history.required | index($field)' \
            "$json_schema"
        [ "$status" -eq 0 ]
    done
}

@test "Mole analyze docs describe post-scan target-scoped output rather than progressive hierarchy fill" {
    json_doc="$PROJECT_ROOT/docs/json-events.md"

    run grep -En -- 'emitted after the scan result|post-scan, target-scoped visualization' "$json_doc"
    [ "$status" -eq 0 ]
}

@test "Mole optimize and purge docs avoid determinate overall progress and ETA claims" {
    json_doc="$PROJECT_ROOT/docs/json-events.md"

    run grep -En -- 'Elapsed: 1m 23s|Remaining: ~2m|35% complete|progressively fills' "$json_doc"
    [ "$status" -eq 1 ]
}
