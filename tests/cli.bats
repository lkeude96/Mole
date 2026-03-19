#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-cli-home.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

create_fake_utils() {
    local dir="$1"
    mkdir -p "$dir"

    cat > "$dir/sudo" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == "-n" || "$1" == "-v" ]]; then
    exit 0
fi
exec "$@"
SCRIPT
    chmod +x "$dir/sudo"

    cat > "$dir/bioutil" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == "-r" ]]; then
    echo "Touch ID: 1"
    exit 0
fi
exit 0
SCRIPT
    chmod +x "$dir/bioutil"
}

setup() {
    rm -rf "$HOME/.config"
    mkdir -p "$HOME"

    # shellcheck source=tests/helpers/json_contract.sh
    source "$PROJECT_ROOT/tests/helpers/json_contract.sh"
}

require_bundled_go_binary() {
    local binary_path="$1"
    local binary_name="$2"

    if [[ -x "$binary_path" ]]; then
        return 0
    fi

    if [[ "${MOLE_REQUIRE_BUNDLED_GO:-0}" == "1" ]]; then
        echo "Required bundled Go binary missing: $binary_name" >&2
        return 1
    fi

    skip "$binary_name binary not built"
}

@test "mole --help prints command overview" {
    run env HOME="$HOME" "$PROJECT_ROOT/mole" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"mo clean"* ]]
    [[ "$output" == *"mo analyze"* ]]
}

@test "mole --version reports script version" {
    expected_version="$(grep '^VERSION=' "$PROJECT_ROOT/mole" | head -1 | sed 's/VERSION=\"\(.*\)\"/\1/')"
    run env HOME="$HOME" "$PROJECT_ROOT/mole" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"$expected_version"* ]]
}

@test "mole unknown command returns error" {
    run env HOME="$HOME" "$PROJECT_ROOT/mole" unknown-command
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown command: unknown-command"* ]]
}

@test "touchid status reports current configuration" {
    run env HOME="$HOME" "$PROJECT_ROOT/mole" touchid status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Touch ID"* ]]
}

@test "mo optimize command is recognized" {
    run bash -c "grep -q '\"optimize\")' '$PROJECT_ROOT/mole'"
    [ "$status" -eq 0 ]
}

@test "mo analyze binary is valid" {
    if [[ -f "$PROJECT_ROOT/bin/analyze-go" ]]; then
        [ -x "$PROJECT_ROOT/bin/analyze-go" ]
        run file "$PROJECT_ROOT/bin/analyze-go"
        [[ "$output" == *"Mach-O"* ]] || [[ "$output" == *"executable"* ]]
    else
        skip "analyze-go binary not built"
    fi
}

@test "mole analyze emits JSON lifecycle through bundled binary" {
    require_jq
    require_bundled_go_binary "$PROJECT_ROOT/bin/analyze-go" "analyze-go"

    target_dir="$HOME/analyze-target"
    mkdir -p "$target_dir/subdir"
    printf 'sample\n' > "$target_dir/file.txt"

    run env HOME="$HOME" MOLE_OUTPUT=json "$PROJECT_ROOT/mole" analyze "$target_dir"
    [ "$status" -eq 0 ]

    assert_ndjson_envelope "$output"
    assert_first_event "$output" "operation_start"
    assert_event_present "$output" "analyze_start"
    assert_event_present "$output" "analyze_complete"
    assert_last_event "$output" "operation_complete"
    [[ "$(printf '%s\n' "$output" | jq -r 'select(.event == "analyze_start") | .data.target_path' | tail -n 1)" == "$target_dir" ]]
}

@test "mole status emits snapshot and canceled lifecycle through bundled binary" {
    require_jq
    require_bundled_go_binary "$PROJECT_ROOT/bin/status-go" "status-go"

    run env HOME="$HOME" MOLE_OUTPUT=json MOLE_STATUS_TEST_SIGNAL=INT MOLE_STATUS_TEST_SIGNAL_DELAY_MS=1200 "$PROJECT_ROOT/mole" status
    [ "$status" -eq 130 ]

    assert_ndjson_envelope "$output"
    assert_first_event "$output" "operation_start"
    assert_event_present "$output" "status_start"
    assert_event_present "$output" "status_snapshot"
    assert_event_present "$output" "status_complete"
    assert_last_event "$output" "operation_complete"
    [[ "$(printf '%s\n' "$output" | jq -r 'select(.event == "operation_complete") | .data.canceled' | tail -n 1)" == "true" ]]
    [[ "$(printf '%s\n' "$output" | jq -r 'select(.event == "operation_complete") | .data.exit_code' | tail -n 1)" == "130" ]]
}

@test "mo clean --debug creates debug log file" {
    mkdir -p "$HOME/.config/mole"
    run env HOME="$HOME" TERM="xterm-256color" MOLE_TEST_MODE=1 MO_DEBUG=1 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]
    MOLE_OUTPUT="$output"

    DEBUG_LOG="$HOME/.config/mole/mole_debug_session.log"
    [ -f "$DEBUG_LOG" ]

    run grep "Mole Debug Session" "$DEBUG_LOG"
    [ "$status" -eq 0 ]

    [[ "$MOLE_OUTPUT" =~ "Debug session log saved to" ]]
}

@test "mo clean without debug does not show debug log path" {
    mkdir -p "$HOME/.config/mole"
    run env HOME="$HOME" TERM="xterm-256color" MOLE_TEST_MODE=1 MO_DEBUG=0 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]

    [[ "$output" != *"Debug session log saved to"* ]]
}

@test "mo clean --debug logs system info" {
    mkdir -p "$HOME/.config/mole"
    run env HOME="$HOME" TERM="xterm-256color" MOLE_TEST_MODE=1 MO_DEBUG=1 "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ]

    DEBUG_LOG="$HOME/.config/mole/mole_debug_session.log"

    run grep "User:" "$DEBUG_LOG"
    [ "$status" -eq 0 ]

    run grep "Architecture:" "$DEBUG_LOG"
    [ "$status" -eq 0 ]
}

@test "touchid status reflects pam file contents" {
    pam_file="$HOME/pam_test"
    cat > "$pam_file" <<'EOF'
auth       sufficient     pam_opendirectory.so
EOF

    run env MOLE_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"not configured"* ]]

    cat > "$pam_file" <<'EOF'
auth       sufficient     pam_tid.so
EOF

    run env MOLE_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"enabled"* ]]
}

@test "enable_touchid inserts pam_tid line in pam file" {
    pam_file="$HOME/pam_enable"
    cat > "$pam_file" <<'EOF'
auth       sufficient     pam_opendirectory.so
EOF

    fake_bin="$HOME/fake-bin"
    create_fake_utils "$fake_bin"

    run env PATH="$fake_bin:$PATH" MOLE_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" enable
    [ "$status" -eq 0 ]
    grep -q "pam_tid.so" "$pam_file"
    [[ -f "${pam_file}.mole-backup" ]]
}

@test "disable_touchid removes pam_tid line" {
    pam_file="$HOME/pam_disable"
    cat > "$pam_file" <<'EOF'
auth       sufficient     pam_tid.so
auth       sufficient     pam_opendirectory.so
EOF

    fake_bin="$HOME/fake-bin-disable"
    create_fake_utils "$fake_bin"

    run env PATH="$fake_bin:$PATH" MOLE_PAM_SUDO_FILE="$pam_file" "$PROJECT_ROOT/bin/touchid.sh" disable
    [ "$status" -eq 0 ]
    run grep "pam_tid.so" "$pam_file"
    [ "$status" -ne 0 ]
}
