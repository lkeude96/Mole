#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/helpers/json_contract.sh"

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-json-installer-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME/Downloads"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "installer --json-scan emits installer_found + summary" {
    require_jq

    touch "$HOME/Downloads/Test Installer.dmg"

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" installer --json-scan 2>/dev/null"
    [ "$status" -eq 0 ]

    assert_ndjson_envelope "$output"
    assert_first_event "$output" "operation_start"
    assert_event_present "$output" "installer_found"
    assert_event_present "$output" "summary"
    assert_last_event "$output" "operation_complete"
}

@test "installer --apply reads manifest from stdin and removes selected installer" {
    require_jq

    target="$HOME/Downloads/Test Installer.dmg"
    touch "$target"

    manifest="$HOME/installer-apply.json"
    cat > "$manifest" <<EOF
{
  "schema_version": 1,
  "operation": "installer",
  "payload": {
    "paths": ["$target"]
  }
}
EOF

    run bash -c "cat \"$manifest\" | env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" installer --apply - 2>/dev/null"
    [ "$status" -eq 0 ]
    [ ! -e "$target" ]

    assert_ndjson_envelope "$output"
    assert_event_present "$output" "installer_removed"
    assert_last_event "$output" "operation_complete"
}

@test "installer --apply emits protected and missing skip reasons" {
    require_jq

    mkdir -p "$HOME/Library/Mobile Documents"
    protected="$HOME/Library/Mobile Documents/protected.dmg"
    missing="$HOME/Downloads/missing.dmg"
    touch "$protected"

    manifest="$HOME/installer-skips.json"
    cat > "$manifest" <<EOF
{
  "schema_version": 1,
  "operation": "installer",
  "payload": {
    "paths": ["$protected", "$missing"]
  }
}
EOF

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" installer --apply \"$manifest\" 2>/dev/null"
    [ "$status" -eq 0 ]

    assert_ndjson_envelope "$output"
    [[ "$output" == *"\"event\":\"installer_skipped\""* ]]
    [[ "$output" == *"\"reason\":\"protected\""* ]]
    [[ "$output" == *"\"reason\":\"missing\""* ]]
}

@test "installer --apply emits error and failing completion for invalid manifest" {
    require_jq

    manifest="$HOME/installer-invalid.json"
    cat > "$manifest" <<'EOF'
{
  "schema_version": 1,
  "operation": "clean",
  "payload": {}
}
EOF

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" installer --apply \"$manifest\" 2>/dev/null"
    [ "$status" -eq 2 ]

    assert_ndjson_envelope "$output"
    assert_event_present "$output" "error"
    assert_last_event "$output" "operation_complete"
}

@test "installer --apply emits canceled lifecycle events on SIGINT" {
    require_jq

    manifest="$HOME/installer-empty.json"
    cat > "$manifest" <<'EOF'
{
  "schema_version": 1,
  "operation": "installer",
  "payload": {
    "paths": []
  }
}
EOF

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json MOLE_INSTALLER_TEST_SIGNAL=INT \"$PROJECT_ROOT/mole\" installer --apply \"$manifest\" 2>/dev/null"
    [ "$status" -eq 130 ]

    assert_ndjson_envelope "$output"

    canceled_error="$(printf '%s\n' "$output" | jq -c 'select(.event=="error" and .data.code=="canceled")' | tail -n 1)"
    [ -n "$canceled_error" ]

    op_complete="$(printf '%s\n' "$output" | jq -c 'select(.event=="operation_complete")' | tail -n 1)"
    [ -n "$op_complete" ]
    [[ "$(printf '%s\n' "$op_complete" | jq -r '.data.canceled')" == "true" ]]
    [[ "$(printf '%s\n' "$op_complete" | jq -r '.data.exit_code')" == "130" ]]
}
