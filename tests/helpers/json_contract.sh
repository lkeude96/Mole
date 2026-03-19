#!/bin/bash

if [[ -n "${MOLE_JSON_CONTRACT_HELPERS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_JSON_CONTRACT_HELPERS_LOADED=1

require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        skip "jq is required for JSON contract tests"
    fi
}

assert_first_event() {
    local ndjson="$1"
    local expected="$2"
    local actual
    actual=$(printf '%s\n' "$ndjson" | jq -r 'select(.event != null) | .event' | head -n 1)
    [[ "$actual" == "$expected" ]]
}

assert_last_event() {
    local ndjson="$1"
    local expected="$2"
    local actual
    actual=$(printf '%s\n' "$ndjson" | jq -r 'select(.event != null) | .event' | tail -n 1)
    [[ "$actual" == "$expected" ]]
}

assert_event_present() {
    local ndjson="$1"
    local expected="$2"
    printf '%s\n' "$ndjson" | jq -e --arg event "$expected" 'select(.event == $event)' > /dev/null
}

assert_ndjson_envelope() {
    local ndjson="$1"
    local prev_seq=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        echo "$line" | jq -e '
          has("schema_version")
          and has("operation")
          and has("event")
          and has("timestamp")
          and has("seq")
          and has("run_id")
          and has("data")
        ' > /dev/null

        local seq
        seq=$(echo "$line" | jq -r ".seq")
        [[ "$seq" =~ ^[0-9]+$ ]]
        [ "$seq" -eq $((prev_seq + 1)) ]
        prev_seq="$seq"
    done <<< "$ndjson"
}
