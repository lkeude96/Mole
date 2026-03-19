#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/helpers/json_contract.sh"

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-json-purge-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME/.config/mole"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "purge --json-scan emits purge_path + artifact_found + summary" {
    require_jq

    mkdir -p "$HOME/Workspace/app/node_modules/pkg"
    touch "$HOME/Workspace/app/package.json"
    touch "$HOME/Workspace/app/node_modules/pkg/index.js"
    touch -t 202401010101 "$HOME/Workspace/app/node_modules" "$HOME/Workspace/app/package.json" "$HOME/Workspace/app/node_modules/pkg/index.js"
    printf '%s\n' "$HOME/Workspace" > "$HOME/.config/mole/purge_paths"

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" purge --json-scan 2>/dev/null"
    [ "$status" -eq 0 ]

    assert_ndjson_envelope "$output"
    assert_first_event "$output" "operation_start"
    assert_event_present "$output" "purge_path"
    assert_event_present "$output" "artifact_found"
    assert_event_present "$output" "summary"
    assert_last_event "$output" "operation_complete"

    artifact_found="$(printf '%s\n' "$output" | jq -c 'select(.event=="artifact_found" and .data.artifact_type=="node_modules")' | head -n 1)"
    [ -n "$artifact_found" ]
}

@test "purge --apply reads manifest from stdin and removes selected artifact" {
    require_jq

    mkdir -p "$HOME/Workspace/app/node_modules/pkg"
    touch "$HOME/Workspace/app/package.json"
    touch "$HOME/Workspace/app/node_modules/pkg/index.js"

    target="$HOME/Workspace/app/node_modules"
    manifest="$HOME/purge-apply.json"
    cat > "$manifest" <<EOF
{
  "schema_version": 1,
  "operation": "purge",
  "payload": {
    "paths": ["$target"]
  }
}
EOF

    run bash -c "cat \"$manifest\" | env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" purge --apply - 2>/dev/null"
    [ "$status" -eq 0 ]
    [ ! -e "$target" ]

    assert_ndjson_envelope "$output"
    assert_event_present "$output" "artifact_removed"
    assert_last_event "$output" "operation_complete"
}

@test "purge --apply emits protected and missing skip reasons" {
    require_jq

    mkdir -p "$HOME/Workspace/rails-app/vendor"
    mkdir -p "$HOME/Workspace/rails-app/config"
    touch "$HOME/Workspace/rails-app/Gemfile"
    touch "$HOME/Workspace/rails-app/config/application.rb"

    protected="$HOME/Workspace/rails-app/vendor"
    missing="$HOME/Workspace/missing/node_modules"
    manifest="$HOME/purge-skips.json"
    cat > "$manifest" <<EOF
{
  "schema_version": 1,
  "operation": "purge",
  "payload": {
    "paths": ["$protected", "$missing"]
  }
}
EOF

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" purge --apply \"$manifest\" 2>/dev/null"
    [ "$status" -eq 0 ]

    assert_ndjson_envelope "$output"
    [[ "$output" == *"\"event\":\"artifact_skipped\""* ]]
    [[ "$output" == *"\"reason\":\"protected\""* ]]
    [[ "$output" == *"\"reason\":\"missing\""* ]]
}

@test "purge --apply emits canceled lifecycle events on SIGINT" {
    require_jq

    manifest="$HOME/purge-empty.json"
    cat > "$manifest" <<'EOF'
{
  "schema_version": 1,
  "operation": "purge",
  "payload": {
    "paths": []
  }
}
EOF

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json MOLE_PURGE_TEST_SIGNAL=INT \"$PROJECT_ROOT/mole\" purge --apply \"$manifest\" 2>/dev/null"
    [ "$status" -eq 130 ]

    assert_ndjson_envelope "$output"

    canceled_error="$(printf '%s\n' "$output" | jq -c 'select(.event=="error" and .data.code=="canceled")' | tail -n 1)"
    [ -n "$canceled_error" ]

    op_complete="$(printf '%s\n' "$output" | jq -c 'select(.event=="operation_complete")' | tail -n 1)"
    [ -n "$op_complete" ]
    [[ "$(printf '%s\n' "$op_complete" | jq -r '.data.canceled')" == "true" ]]
    [[ "$(printf '%s\n' "$op_complete" | jq -r '.data.exit_code')" == "130" ]]
}
