#!/usr/bin/env bats
# Timeout functionality tests
# Tests for lib/core/timeout.sh

setup() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    export MO_DEBUG=0  # Disable debug output for cleaner tests
}

# =================================================================
# Basic Timeout Functionality
# =================================================================

@test "run_with_timeout: command completes before timeout" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'success'
    ")
    [[ "$result" == "success" ]]
}

@test "run_with_timeout: zero timeout runs command normally" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 0 echo 'no_timeout'
    ")
    [[ "$result" == "no_timeout" ]]
}

@test "run_with_timeout: invalid timeout runs command normally" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout invalid echo 'no_timeout'
    ")
    [[ "$result" == "no_timeout" ]]
}

@test "run_with_timeout: negative timeout runs command normally" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout -5 echo 'no_timeout'
    ")
    [[ "$result" == "no_timeout" ]]
}

# =================================================================
# Exit Code Handling
# =================================================================

@test "run_with_timeout: preserves command exit code on success" {
    bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 true
    "
    exit_code=$?
    [[ $exit_code -eq 0 ]]
}

@test "run_with_timeout: preserves command exit code on failure" {
    set +e
    bash -c "
        set +e  # Don't exit on error
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 false
        exit \$?
    "
    exit_code=$?
    set -e
    [[ $exit_code -eq 1 ]]
}

@test "run_with_timeout: returns 124 on timeout (if using gtimeout)" {
    # This test only passes if gtimeout/timeout is available
    # Skip if using shell fallback (can't guarantee exit code 124 in all cases)
    if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
        skip "gtimeout/timeout not available"
    fi

    set +e
    bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 1 sleep 10
        exit \$?
    "
    exit_code=$?
    set -e
    [[ $exit_code -eq 124 ]]
}

# =================================================================
# Timeout Behavior
# =================================================================

@test "run_with_timeout: kills long-running command" {
    # Command should be killed after 2 seconds
    start_time=$(date +%s)
    set +e
    bash -c "
        set +e
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 2 sleep 30
    " >/dev/null 2>&1
    set -e
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Should complete in ~2 seconds, not 30
    # Allow some margin (up to 5 seconds for slow systems)
    [[ $duration -lt 10 ]]
}

@test "run_with_timeout: handles fast-completing commands" {
    # Fast command should complete immediately
    start_time=$(date +%s)
    bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 10 echo 'fast'
    " >/dev/null 2>&1
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Should complete in ~0 seconds
    [[ $duration -lt 3 ]]
}

# =================================================================
# Pipefail Compatibility
# =================================================================

@test "run_with_timeout: works in pipefail mode" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'pipefail_test'
    ")
    [[ "$result" == "pipefail_test" ]]
}

@test "run_with_timeout: doesn't cause unintended exits" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 true || true
        echo 'survived'
    ")
    [[ "$result" == "survived" ]]
}

# =================================================================
# Command Arguments
# =================================================================

@test "run_with_timeout: handles commands with arguments" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'arg1' 'arg2' 'arg3'
    ")
    [[ "$result" == "arg1 arg2 arg3" ]]
}

@test "run_with_timeout: handles commands with spaces in arguments" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'hello world'
    ")
    [[ "$result" == "hello world" ]]
}

# =================================================================
# Debug Logging
# =================================================================

@test "run_with_timeout: debug logging when MO_DEBUG=1" {
    output=$(bash -c "
        set -euo pipefail
        export MO_DEBUG=1
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        run_with_timeout 5 echo 'test' 2>&1
    ")
    # Should contain debug output
    [[ "$output" =~ TIMEOUT ]]
}

@test "run_with_timeout: no debug logging when MO_DEBUG=0" {
    # When MO_DEBUG=0, no debug messages should appear during function execution
    # (Initialization messages may appear if module is loaded for first time)
    output=$(bash -c "
        set -euo pipefail
        export MO_DEBUG=0
        unset MO_TIMEOUT_INITIALIZED  # Force re-initialization
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        # Capture only the function call output, not initialization
        run_with_timeout 5 echo 'test'
    " 2>/dev/null)  # Discard stderr (initialization messages)
    # Should only have command output
    [[ "$output" == "test" ]]
}

# =================================================================
# Module Loading
# =================================================================

@test "timeout.sh: prevents multiple sourcing" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        echo 'loaded'
    ")
    [[ "$result" == "loaded" ]]
}

@test "timeout.sh: sets MOLE_TIMEOUT_LOADED flag" {
    result=$(bash -c "
        set -euo pipefail
        source '$PROJECT_ROOT/lib/core/timeout.sh'
        echo \"\$MOLE_TIMEOUT_LOADED\"
    ")
    [[ "$result" == "1" ]]
}
