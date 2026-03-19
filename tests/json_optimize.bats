#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/helpers/json_contract.sh"

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-json-optimize-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

require_optimize_deps() {
    if ! command -v bc > /dev/null 2>&1; then
        skip "bc is required for optimize JSON contract tests"
    fi
}

@test "optimize --json-scan emits optimization_available + summary lifecycle events" {
    require_jq
    require_optimize_deps

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" optimize --json-scan 2>/dev/null"
    [ "$status" -eq 0 ]

    assert_ndjson_envelope "$output"
    assert_first_event "$output" "operation_start"
    assert_event_present "$output" "optimization_available"
    assert_event_present "$output" "summary"
    assert_last_event "$output" "operation_complete"
}

@test "optimize --apply reads manifest from stdin and emits optimization events" {
    require_jq
    require_optimize_deps

    manifest="$HOME/optimize-apply.json"
    cat > "$manifest" <<'EOF'
{
  "schema_version": 1,
  "operation": "optimize",
  "payload": {
    "actions": ["cache_refresh"]
  }
}
EOF

    run bash -c "cat \"$manifest\" | env HOME=\"$HOME\" MOLE_OUTPUT=json MOLE_DRY_RUN=1 \"$PROJECT_ROOT/mole\" optimize --apply - 2>/dev/null"
    [ "$status" -eq 0 ]

    assert_ndjson_envelope "$output"
    assert_event_present "$output" "optimization_start"
    assert_event_present "$output" "optimization_complete"
    assert_last_event "$output" "operation_complete"

    op_complete="$(printf '%s\n' "$output" | jq -c 'select(.event=="operation_complete")' | tail -n 1)"
    [ -n "$op_complete" ]
    [[ "$(printf '%s\n' "$op_complete" | jq -r '.data.success')" == "true" ]]
}

@test "optimize --apply emits error and failing completion for invalid manifest" {
    require_jq
    require_optimize_deps

    manifest="$HOME/optimize-invalid.json"
    cat > "$manifest" <<'EOF'
{
  "schema_version": 1,
  "operation": "clean",
  "payload": {}
}
EOF

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" optimize --apply \"$manifest\" 2>/dev/null"
    [ "$status" -eq 2 ]

    assert_ndjson_envelope "$output"
    assert_event_present "$output" "error"
    assert_last_event "$output" "operation_complete"

    op_complete="$(printf '%s\n' "$output" | jq -c 'select(.event=="operation_complete")' | tail -n 1)"
    [ -n "$op_complete" ]
    [[ "$(printf '%s\n' "$op_complete" | jq -r '.data.success')" == "false" ]]
    [[ "$(printf '%s\n' "$op_complete" | jq -r '.data.exit_code')" == "2" ]]
}

@test "optimize --apply emits canceled lifecycle events on SIGINT" {
    require_jq
    require_optimize_deps

    manifest="$HOME/optimize-empty.json"
    cat > "$manifest" <<'EOF'
{
  "schema_version": 1,
  "operation": "optimize",
  "payload": {
    "actions": []
  }
}
EOF

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json MOLE_DRY_RUN=1 MOLE_OPTIMIZE_TEST_SIGNAL=INT \"$PROJECT_ROOT/mole\" optimize --apply \"$manifest\" 2>/dev/null"
    [ "$status" -eq 130 ]

    assert_ndjson_envelope "$output"

    canceled_error="$(printf '%s\n' "$output" | jq -c 'select(.event=="error" and .data.code=="canceled")' | tail -n 1)"
    [ -n "$canceled_error" ]

    op_complete="$(printf '%s\n' "$output" | jq -c 'select(.event=="operation_complete")' | tail -n 1)"
    [ -n "$op_complete" ]
    [[ "$(printf '%s\n' "$op_complete" | jq -r '.data.canceled')" == "true" ]]
    [[ "$(printf '%s\n' "$op_complete" | jq -r '.data.exit_code')" == "130" ]]
}
