#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

@test "validation workflow supports manual dispatch" {
    run bash -c "grep -q 'workflow_dispatch:' '$PROJECT_ROOT/.github/workflows/test.yml'"
    [ "$status" -eq 0 ]
}

@test "validation workflow preserves scripts test logs" {
    run bash -c "grep -q 'scripts-test.log' '$PROJECT_ROOT/.github/workflows/test.yml'"
    [ "$status" -eq 0 ]

    run bash -c "grep -q 'upload-artifact' '$PROJECT_ROOT/.github/workflows/test.yml'"
    [ "$status" -eq 0 ]
}

@test "contributing guide points final verification to macOS shell or CI" {
    run bash -c "grep -q 'GitHub Actions on macOS is the authoritative verification runner' '$PROJECT_ROOT/CONTRIBUTING.md'"
    [ "$status" -eq 0 ]

    run bash -c "grep -Fq 'cd \"/Users/kinsley/Developer/_open_source/burrow-workspace/Mole\" && bash \"scripts/test.sh\"' '$PROJECT_ROOT/CONTRIBUTING.md'"
    [ "$status" -eq 0 ]
}
