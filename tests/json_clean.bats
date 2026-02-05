#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/helpers/json_contract.sh"

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-json-clean-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
    mkdir -p "$HOME/.config/mole"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean --json-scan emits NDJSON envelope and lifecycle events" {
    require_jq

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json MOLE_TEST_MODE=1 \"$PROJECT_ROOT/mole\" clean --json-scan 2>/dev/null"
    [ "$status" -eq 0 ]

    assert_ndjson_envelope "$output"
    [[ "$output" == *"\"event\":\"operation_start\""* ]]
    [[ "$output" == *"\"event\":\"operation_complete\""* ]]
}

@test "clean --apply removes selected paths and emits item_cleaned" {
    require_jq

    target_file="$HOME/test-clean-target"
    echo "hello" > "$target_file"

    manifest="$HOME/clean-apply.json"
    cat > "$manifest" <<EOF
{
  "schema_version": 1,
  "operation": "clean",
  "payload": {
    "paths": ["$target_file"]
  }
}
EOF

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" clean --apply \"$manifest\" 2>/dev/null"
    [ "$status" -eq 0 ]
    [ ! -e "$target_file" ]

    assert_ndjson_envelope "$output"
    [[ "$output" == *"\"event\":\"item_cleaned\""* ]]

    summary_line="$(echo "$output" | grep -m 1 '\"event\":\"summary\"' || true)"
    [ -n "$summary_line" ]
    [[ "$(echo "$summary_line" | jq -r ".data.skipped_count")" == "0" ]]
    [[ "$(echo "$summary_line" | jq -r ".data.failed_count")" == "0" ]]

    [[ "$output" == *"\"event\":\"operation_complete\""* ]]
}

@test "clean --apply emits item_skipped reason permission_denied for permission failures" {
    require_jq

    locked_dir="$HOME/locked"
    mkdir -p "$locked_dir"
    target_file="$locked_dir/locked-target"
    echo "hello" > "$target_file"
    chmod 555 "$locked_dir"

    manifest="$HOME/clean-apply-fail.json"
    cat > "$manifest" <<EOF
{
  "schema_version": 1,
  "operation": "clean",
  "payload": {
    "paths": ["$target_file"]
  }
}
EOF

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" clean --apply \"$manifest\" 2>/dev/null"
    [ "$status" -eq 0 ]
    [ -e "$target_file" ]

    assert_ndjson_envelope "$output"
    [[ "$output" == *"\"event\":\"item_skipped\""* ]]
    [[ "$output" == *"\"reason\":\"permission_denied\""* ]]

    op_complete="$(echo "$output" | tail -n 1)"
    [[ "$(echo "$op_complete" | jq -r ".event")" == "operation_complete" ]]
    [[ "$(echo "$op_complete" | jq -r ".data.counts.skipped")" == "1" ]]
}

@test "clean --apply includes skipped breakdown counts" {
    require_jq

    mkdir -p "$HOME/.config/mole"

    # Whitelist skip: existing file covered by whitelist.
    whitelisted="$HOME/whitelist-target"
    echo "x" > "$whitelisted"
    echo "$whitelisted" > "$HOME/.config/mole/whitelist"

    # Protected skip: iCloud Drive patterns are protected by should_protect_path.
    protected="$HOME/Library/Mobile Documents/protected-target"

    # Missing skip: absolute path that doesn't exist.
    missing="$HOME/missing-target"

    manifest="$HOME/clean-apply-skips.json"
    cat > "$manifest" <<EOF
{
  "schema_version": 1,
  "operation": "clean",
  "payload": {
    "paths": ["$whitelisted", "$protected", "$missing"]
  }
}
EOF

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" clean --apply \"$manifest\" 2>/dev/null"
    [ "$status" -eq 0 ]

    assert_ndjson_envelope "$output"

    op_complete="$(echo "$output" | tail -n 1)"
    [[ "$(echo "$op_complete" | jq -r ".event")" == "operation_complete" ]]
    [[ "$(echo "$op_complete" | jq -r ".data.counts.skipped")" == "3" ]]
    [[ "$(echo "$op_complete" | jq -r ".data.counts.whitelist_skipped")" == "1" ]]
    [[ "$(echo "$op_complete" | jq -r ".data.counts.protected_skipped")" == "1" ]]
    [[ "$(echo "$op_complete" | jq -r ".data.counts.missing_skipped")" == "1" ]]
}

@test "clean --apply emits item_skipped reason in_use when directory is busy" {
    require_jq

    parent_dir="$HOME/inuse-parent"
    busy_dir="$parent_dir/busy"
    mkdir -p "$busy_dir"

    manifest="$HOME/clean-apply-inuse.json"
    cat > "$manifest" <<EOF
{
  "schema_version": 1,
  "operation": "clean",
  "payload": {
    "paths": ["$busy_dir"]
  }
}
EOF

    # Skip if we cannot reproduce a "busy" deletion failure on this platform.
    busy_err="$(bash -c "cd \"$busy_dir\" && rm -rf \"$busy_dir\" 2>&1 || true")"
    if [[ "$busy_err" != *"busy"* && "$busy_err" != *"Busy"* ]]; then
        skip "Unable to simulate a busy directory removal failure"
    fi

    run bash -c "cd \"$busy_dir\" && env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" clean --apply \"$manifest\" 2>/dev/null"
    [ "$status" -eq 0 ]
    [ -e "$busy_dir" ]

    assert_ndjson_envelope "$output"
    [[ "$output" == *"\"event\":\"item_skipped\""* ]]
    [[ "$output" == *"\"reason\":\"in_use\""* ]]
}
