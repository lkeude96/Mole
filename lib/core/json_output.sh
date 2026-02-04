#!/bin/bash
# Mole - JSON Output (NDJSON)
# Canonical emitter for the Burrow ⇄ Mole JSON contract.

if [[ -n "${MOLE_JSON_OUTPUT_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_JSON_OUTPUT_LOADED=1

readonly MOLE_JSON_SCHEMA_VERSION=1
MOLE_JSON_OUT_FD_DEFAULT=1

mole_json_enabled() {
    [[ "${MOLE_OUTPUT:-}" == "json" ]]
}

_mole_json_generate_uuid() {
    if command -v uuidgen > /dev/null 2>&1; then
        uuidgen | LC_ALL=C tr '[:upper:]' '[:lower:]'
        return 0
    fi

    # Best-effort fallback; format is not guaranteed to be RFC4122, but keeps correlation.
    local now
    now=$(date -u +%s 2> /dev/null || echo "0")
    printf "00000000-0000-0000-0000-%012d" "$now"
}

mole_json_init() {
    mole_json_enabled || return 0

    if [[ -z "${MOLE_JSON_RUN_ID:-}" ]]; then
        export MOLE_JSON_RUN_ID="$(_mole_json_generate_uuid)"
    fi
    if [[ -z "${MOLE_JSON_SEQ:-}" ]]; then
        export MOLE_JSON_SEQ=0
    fi
    if [[ -z "${MOLE_JSON_START_EPOCH_MS:-}" ]]; then
        local now_s
        now_s=$(date -u +%s 2> /dev/null || echo "0")
        export MOLE_JSON_START_EPOCH_MS=$((now_s * 1000))
    fi
}

mole_json_timestamp() {
    # RFC3339 UTC, seconds precision.
    date -u +%Y-%m-%dT%H:%M:%SZ
}

mole_json_escape_string() {
    # Escapes a string for JSON string context (without surrounding quotes).
    # Handles: backslash, quote, tab, CR, LF, plus any remaining ASCII control chars via \u00XX.
    local s="${1-}"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\b'/\\b}
    s=${s//$'\f'/\\f}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}

    # Escape any remaining ASCII control bytes (0x01-0x1f). Bash strings cannot contain NUL.
    if [[ "$s" == *[$'\001'-$'\037']* ]]; then
        local out=""
        local hex
        for hex in $(printf '%s' "$s" | LC_ALL=C od -An -tx1 -v); do
            local dec=$((16#$hex))
            if ((dec < 32)); then
                out+="\\u00$hex"
            else
                printf -v out '%s%b' "$out" "\\x$hex"
            fi
        done
        s="$out"
    fi
    printf "%s" "$s"
}

mole_json_quote() {
    printf "\"%s\"" "$(mole_json_escape_string "${1-}")"
}

mole_json_array() {
    # Build a JSON array of strings from argv.
    local first=true
    printf "["
    local arg
    for arg in "$@"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            printf ","
        fi
        mole_json_quote "$arg"
    done
    printf "]"
}

mole_json_emit_event() {
    # Usage: mole_json_emit_event <operation> <event> <data_json_object_string>
    # Emits exactly one NDJSON line to stdout.
    local operation="${1:?operation required}"
    local event="${2:?event required}"
    local data="${3-}"
    [[ -z "$data" ]] && data="{}"

    mole_json_enabled || return 0
    mole_json_init

    # Defensive: ensure data is a JSON object.
    case "$data" in
        \{*\}) : ;;
        *) data="{}" ;;
    esac

    local seq=$((MOLE_JSON_SEQ + 1))
    export MOLE_JSON_SEQ="$seq"

    local ts
    ts=$(mole_json_timestamp)

    local out_fd="${MOLE_JSON_OUT_FD:-$MOLE_JSON_OUT_FD_DEFAULT}"
    # shellcheck disable=SC2059
    printf '{"schema_version":%d,"operation":%s,"event":%s,"timestamp":%s,"seq":%d,"run_id":%s,"data":%s}\n' \
        "$MOLE_JSON_SCHEMA_VERSION" \
        "$(mole_json_quote "$operation")" \
        "$(mole_json_quote "$event")" \
        "$(mole_json_quote "$ts")" \
        "$seq" \
        "$(mole_json_quote "${MOLE_JSON_RUN_ID:-}")" \
        "$data" >&"$out_fd"
}

mole_json_emit_operation_start() {
    local operation="${1:?operation required}"
    local mode="${2:?mode required}" # scan|apply
    local dry_run="${3:-false}"
    shift 3 || true
    local argv_json
    argv_json=$(mole_json_array "$@")
    mole_json_emit_event "$operation" "operation_start" \
        "{\"mode\":$(mole_json_quote "$mode"),\"argv\":$argv_json,\"dry_run\":$dry_run}"
}

mole_json_emit_operation_complete() {
    local operation="${1:?operation required}"
    local success="${2:-false}"
    local canceled="${3:-false}"
    local exit_code="${4:-0}"
    local duration_ms="${5:-0}"
    local counts_json="${6-}"
    local totals_json="${7-}"
    [[ -z "$counts_json" ]] && counts_json="{}"
    [[ -z "$totals_json" ]] && totals_json="{}"
    mole_json_emit_event "$operation" "operation_complete" \
        "{\"success\":$success,\"canceled\":$canceled,\"exit_code\":$exit_code,\"duration_ms\":$duration_ms,\"counts\":$counts_json,\"totals\":$totals_json}"
}

mole_json_emit_error() {
    local operation="${1:?operation required}"
    local level="${2:?error or warning required}" # error|warning
    local code="${3:?code required}"
    local message="${4:?message required}"
    local path="${5:-}"
    local bundle_id="${6:-}"
    local action="${7:-}"
    local detail="${8:-}"

    local data="{\"code\":$(mole_json_quote "$code"),\"message\":$(mole_json_quote "$message")"
    [[ -n "$path" ]] && data+=",\"path\":$(mole_json_quote "$path")"
    [[ -n "$bundle_id" ]] && data+=",\"bundle_id\":$(mole_json_quote "$bundle_id")"
    [[ -n "$action" ]] && data+=",\"action\":$(mole_json_quote "$action")"
    [[ -n "$detail" ]] && data+=",\"detail\":$(mole_json_quote "$detail")"
    data+="}"

    mole_json_emit_event "$operation" "$level" "$data"
}
