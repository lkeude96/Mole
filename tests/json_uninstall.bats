#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/helpers/json_contract.sh"

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-json-uninstall-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME/Applications/TestApp.app/Contents"
    cat > "$HOME/Applications/TestApp.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.testapp</string>
</dict>
</plist>
EOF
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "bin/uninstall.sh --json-scan emits app_found + leftover_found + summary" {
    require_jq
    mkdir -p "$HOME/Library/Application Support/com.example.testapp"
    printf 'leftover\n' > "$HOME/Library/Application Support/com.example.testapp/state.json"

    run env HOME="$HOME" MOLE_OUTPUT=json MOLE_UNINSTALL_APP_DIRS="$HOME/Applications" \
        bash "$PROJECT_ROOT/bin/uninstall.sh" --json-scan
    [ "$status" -eq 0 ]

    assert_ndjson_envelope "$output"
    assert_first_event "$output" "operation_start"

    app_found="$(echo "$output" | jq -c 'select(.event=="app_found" and .data.bundle_id=="com.example.testapp")' | head -n 1)"
    [ -n "$app_found" ]

    leftover_found="$(echo "$output" | jq -c 'select(.event=="leftover_found" and .data.bundle_id=="com.example.testapp" and .data.kind=="application_support")' | head -n 1)"
    [ -n "$leftover_found" ]

    summary="$(echo "$output" | jq -c 'select(.event=="summary")' | tail -n 1)"
    [ -n "$summary" ]
    [[ "$(echo "$summary" | jq -r ".data.app_count")" == "1" ]]
    [[ "$(echo "$summary" | jq -r ".data.leftover_count")" == "1" ]]
    [[ "$(echo "$summary" | jq -r ".data.leftover_size_bytes")" =~ ^[0-9]+$ ]]
    assert_last_event "$output" "operation_complete"
}

@test "bin/uninstall.sh --apply emits app_removed + leftover_removed + summary" {
    require_jq

    target_app="$HOME/Applications/TestApp.app"
    leftover_dir="$HOME/Library/Application Support/com.example.testapp"
    manifest="$HOME/uninstall-apply.json"

    mkdir -p "$leftover_dir"
    printf 'leftover\n' > "$leftover_dir/state.json"
    cat > "$manifest" <<EOF
{
  "schema_version": 1,
  "operation": "uninstall",
  "payload": {
    "apps": [
      { "bundle_id": "com.example.testapp", "path": "$target_app" }
    ]
    }
}
EOF

    run env HOME="$HOME" MOLE_OUTPUT=json \
        bash "$PROJECT_ROOT/bin/uninstall.sh" --apply "$manifest"
    [ "$status" -eq 0 ]
    [ ! -e "$target_app" ]

    assert_ndjson_envelope "$output"
    assert_first_event "$output" "operation_start"

    app_removed="$(echo "$output" | jq -c 'select(.event=="app_removed" and .data.bundle_id=="com.example.testapp")' | head -n 1)"
    [ -n "$app_removed" ]

    leftover_removed="$(echo "$output" | jq -c 'select(.event=="leftover_removed" and .data.bundle_id=="com.example.testapp" and .data.kind=="application_support")' | head -n 1)"
    [ -n "$leftover_removed" ]

    summary="$(echo "$output" | jq -c 'select(.event=="summary")' | tail -n 1)"
    [ -n "$summary" ]
    [[ "$(echo "$summary" | jq -r ".data.app_count")" == "1" ]]
    assert_last_event "$output" "operation_complete"
}

@test "bin/uninstall.sh --apply emits canceled lifecycle events on SIGINT" {
    require_jq

    run env HOME="$HOME" MOLE_OUTPUT=json MOLE_TEST_MODE=1 MOLE_UNINSTALL_TEST_SIGNAL=INT \
        bash "$PROJECT_ROOT/bin/uninstall.sh" --apply "$HOME/empty-manifest.json"
    [ "$status" -eq 130 ]

    assert_ndjson_envelope "$output"

    canceled_error="$(echo "$output" | jq -c 'select(.event=="error" and .data.code=="canceled")' | tail -n 1)"
    [ -n "$canceled_error" ]

    op_complete="$(echo "$output" | jq -c 'select(.event=="operation_complete")' | tail -n 1)"
    [ -n "$op_complete" ]
    [[ "$(echo "$op_complete" | jq -r ".data.canceled")" == "true" ]]
    [[ "$(echo "$op_complete" | jq -r ".data.exit_code")" == "130" ]]
}
