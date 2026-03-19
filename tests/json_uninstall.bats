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

@test "uninstall --json-scan can be scoped to custom scan dirs and emits app_found + summary" {
    require_jq

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json MOLE_UNINSTALL_APP_DIRS=\"$HOME/Applications\" \"$PROJECT_ROOT/mole\" uninstall --json-scan 2>/dev/null"
    [ "$status" -eq 0 ]

    assert_ndjson_envelope "$output"

    app_found="$(echo "$output" | jq -c 'select(.event=="app_found" and .data.bundle_id=="com.example.testapp")' | head -n 1)"
    [ -n "$app_found" ]

    summary="$(echo "$output" | jq -c 'select(.event=="summary")' | tail -n 1)"
    [ -n "$summary" ]
    [[ "$(echo "$summary" | jq -r ".data.app_count")" == "1" ]]
}

@test "uninstall --apply removes selected app and emits app_removed + summary" {
    require_jq

    target_app="$HOME/Applications/TestApp.app"
    [ -d "$target_app" ]

    manifest="$HOME/uninstall-apply.json"
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

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json \"$PROJECT_ROOT/mole\" uninstall --apply \"$manifest\" 2>/dev/null"
    [ "$status" -eq 0 ]
    [ ! -e "$target_app" ]

    assert_ndjson_envelope "$output"
    [[ "$output" == *"\"event\":\"app_removed\""* ]]
    [[ "$output" == *"\"event\":\"summary\""* ]]
    [[ "$output" == *"\"event\":\"operation_complete\""* ]]
}

@test "uninstall --apply emits canceled lifecycle events on SIGINT" {
    require_jq

    run bash -c "env HOME=\"$HOME\" MOLE_OUTPUT=json MOLE_TEST_MODE=1 MOLE_UNINSTALL_TEST_SIGNAL=INT \"$PROJECT_ROOT/mole\" uninstall --apply \"$HOME/empty-manifest.json\" 2>/dev/null"
    [ "$status" -eq 130 ]

    assert_ndjson_envelope "$output"

    canceled_error="$(echo "$output" | jq -c 'select(.event=="error" and .data.code=="canceled")' | tail -n 1)"
    [ -n "$canceled_error" ]

    op_complete="$(echo "$output" | jq -c 'select(.event=="operation_complete")' | tail -n 1)"
    [ -n "$op_complete" ]
    [[ "$(echo "$op_complete" | jq -r ".data.canceled")" == "true" ]]
    [[ "$(echo "$op_complete" | jq -r ".data.exit_code")" == "130" ]]
}
