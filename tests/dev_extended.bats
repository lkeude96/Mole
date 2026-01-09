#!/usr/bin/env bats

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-dev-extended.XXXXXX")"
    export HOME

    mkdir -p "$HOME"
}

teardown_file() {
    rm -rf "$HOME"
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

@test "clean_dev_elixir cleans mix and hex caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_elixir
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Mix cache"* ]]
    [[ "$output" == *"Hex cache"* ]]
}

@test "clean_dev_haskell cleans cabal install and stack caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_haskell
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cabal install cache"* ]]
    [[ "$output" == *"Stack cache"* ]]
}

@test "clean_dev_ocaml cleans opam cache" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_ocaml
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"Opam cache"* ]]
}

@test "clean_dev_editors cleans VS Code and Zed caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "$2"; }
clean_dev_editors
EOF

    [ "$status" -eq 0 ]
    [[ "$output" == *"VS Code cached data"* ]]
    [[ "$output" == *"VS Code workspace storage"* ]]
    [[ "$output" == *"Zed cache"* ]]
}
