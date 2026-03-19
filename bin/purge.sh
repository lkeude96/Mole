#!/bin/bash
# Mole - Purge command.
# Cleans heavy project build artifacts.
# Interactive selection by project.

set -euo pipefail

# Fix locale issues (avoid Perl warnings on non-English systems)
export LC_ALL=C
export LANG=C

# Get script directory and source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"

# Set up cleanup trap for temporary files
trap cleanup_temp_files EXIT INT TERM
source "$SCRIPT_DIR/../lib/core/log.sh"
source "$SCRIPT_DIR/../lib/clean/project.sh"

# Configuration
CURRENT_SECTION=""
MOLE_JSON_COMMAND_MODE=""
MOLE_JSON_APPLY_MANIFEST=""

json_mode_setup_stdio() {
    # Keep stdout clean for NDJSON by routing all non-JSON output to stderr.
    exec 3>&1 1>&2
    export MOLE_JSON_OUT_FD=3
}

maybe_trigger_purge_json_test_signal() {
    local signal_name="${MOLE_PURGE_TEST_SIGNAL:-}"
    [[ -z "$signal_name" ]] && return 0

    kill -s "$signal_name" "$$" 2> /dev/null || true
}

purge_find_project_root() {
    local artifact_path="$1"
    local start_dir
    start_dir="$(dirname "$artifact_path")"
    local current="$start_dir"
    local depth=0

    while [[ -n "$current" && "$current" != "/" && $depth -lt 12 ]]; do
        local indicator
        for indicator in "${MONOREPO_INDICATORS[@]}"; do
            if [[ -e "$current/$indicator" ]]; then
                echo "$current"
                return 0
            fi
        done
        for indicator in "${PROJECT_INDICATORS[@]}"; do
            if [[ -e "$current/$indicator" ]]; then
                echo "$current"
                return 0
            fi
        done
        current="$(dirname "$current")"
        depth=$((depth + 1))
    done

    echo "$start_dir"
    return 0
}

purge_emit_summary() {
    local count="$1"
    local size_bytes="$2"
    mole_json_emit_event "purge" "summary" \
        "{\"artifact_count\":$count,\"total_size_bytes\":$size_bytes}"
}

purge_json_scan() {
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    ensure_user_dir "$stats_dir"

    local source="auto"
    if [[ -f "$PURGE_CONFIG_FILE" ]]; then
        if grep -Eq "^[[:space:]]*[^#[:space:]]" "$PURGE_CONFIG_FILE" 2> /dev/null; then
            source="config"
        fi
    fi

    local root
    for root in "${PURGE_SEARCH_PATHS[@]}"; do
        [[ -d "$root" ]] || continue
        mole_json_emit_event "purge" "purge_path" \
            "{\"root\":$(mole_json_quote "$root"),\"source\":$(mole_json_quote "$source")}"
    done

    local all_items
    all_items=$(mktemp_file "mole_purge_scan")
    local scan_out

    for root in "${PURGE_SEARCH_PATHS[@]}"; do
        [[ -d "$root" ]] || continue
        scan_out=$(mktemp_file "mole_purge_scan_root")
        scan_purge_targets "$root" "$scan_out" || true
        if [[ -f "$scan_out" ]]; then
            cat "$scan_out" >> "$all_items" 2> /dev/null || true
        fi
        rm -f "$scan_out" 2> /dev/null || true
    done

    local uniq_items
    uniq_items=$(mktemp_file "mole_purge_scan_uniq")
    sort -u "$all_items" > "$uniq_items" 2> /dev/null || true
    rm -f "$all_items" 2> /dev/null || true

    local total_count=0
    local total_size=0
    local item
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        [[ -d "$item" ]] || continue

        local size_kb
        size_kb=$(get_dir_size_kb "$item" 2> /dev/null || echo "0")
        [[ ! "$size_kb" =~ ^[0-9]+$ ]] && size_kb=0
        local size_bytes=$((size_kb * 1024))

        local project_root
        project_root=$(purge_find_project_root "$item")
        local project_name
        project_name=$(basename "$project_root")
        local artifact_type
        artifact_type=$(basename "$item")

        local recent=false
        if is_recently_modified "$item"; then
            recent=true
        fi

        mole_json_emit_event "purge" "artifact_found" \
            "{\"path\":$(mole_json_quote "$item"),\"project_root\":$(mole_json_quote "$project_root"),\"project_name\":$(mole_json_quote "$project_name"),\"artifact_type\":$(mole_json_quote "$artifact_type"),\"size_bytes\":$size_bytes,\"recently_modified\":$recent}"

        total_count=$((total_count + 1))
        total_size=$((total_size + size_bytes))
    done < "$uniq_items"
    rm -f "$uniq_items" 2> /dev/null || true

    purge_emit_summary "$total_count" "$total_size"
    return 0
}

purge_json_apply() {
    local manifest="$1"
    if ! command -v jq > /dev/null 2>&1; then
        mole_json_emit_error "purge" "error" "unknown" "jq is required to parse apply manifests" "" "" "" ""
        return 2
    fi

    local schema_version
    schema_version=$(jq -r '.schema_version // empty' "$manifest" 2> /dev/null || echo "")
    local op
    op=$(jq -r '.operation // empty' "$manifest" 2> /dev/null || echo "")
    if [[ "$schema_version" != "1" || "$op" != "purge" ]]; then
        mole_json_emit_error "purge" "error" "unknown" "Invalid manifest (schema_version/operation)" "" "" "" ""
        return 2
    fi

    local -a paths=()
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        paths+=("$p")
    done < <(jq -r '.payload.paths[]? // empty' "$manifest" 2> /dev/null || true)

    local removed_count=0
    local removed_size=0
    local path
    for path in "${paths[@]}"; do
        [[ -z "$path" ]] && continue

        if [[ ! -e "$path" ]]; then
            mole_json_emit_event "purge" "artifact_skipped" \
                "{\"path\":$(mole_json_quote "$path"),\"reason\":$(mole_json_quote "missing")}"
            continue
        fi

        if is_protected_purge_artifact "$path"; then
            mole_json_emit_event "purge" "artifact_skipped" \
                "{\"path\":$(mole_json_quote "$path"),\"reason\":$(mole_json_quote "protected")}"
            continue
        fi

        if ! validate_path_for_deletion "$path"; then
            mole_json_emit_event "purge" "artifact_skipped" \
                "{\"path\":$(mole_json_quote "$path"),\"reason\":$(mole_json_quote "protected")}"
            continue
        fi

        local size_kb
        size_kb=$(get_dir_size_kb "$path" 2> /dev/null || echo "0")
        [[ ! "$size_kb" =~ ^[0-9]+$ ]] && size_kb=0
        local size_bytes=$((size_kb * 1024))

        if safe_remove "$path" true; then
            mole_json_emit_event "purge" "artifact_removed" \
                "{\"path\":$(mole_json_quote "$path"),\"size_bytes\":$size_bytes}"
            removed_count=$((removed_count + 1))
            removed_size=$((removed_size + size_bytes))
        else
            mole_json_emit_event "purge" "artifact_failed" \
                "{\"path\":$(mole_json_quote "$path"),\"reason\":$(mole_json_quote "unknown")}"
        fi
    done

    purge_emit_summary "$removed_count" "$removed_size"
    return 0
}

# Section management
start_section() {
    local section_name="$1"
    CURRENT_SECTION="$section_name"
    printf '\n'
    echo -e "${BLUE}━━━ ${section_name} ━━━${NC}"
}

end_section() {
    CURRENT_SECTION=""
}

# Note activity for export list
note_activity() {
    if [[ -n "$CURRENT_SECTION" ]]; then
        printf '%s\n' "$CURRENT_SECTION" >> "$EXPORT_LIST_FILE"
    fi
}

# Main purge function
start_purge() {
    # Set current command for operation logging
    export MOLE_CURRENT_COMMAND="purge"
    log_operation_session_start "purge"

    # Clear screen for better UX
    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
    printf '\n'

    # Initialize stats file in user cache directory
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    ensure_user_dir "$stats_dir"
    ensure_user_file "$stats_dir/purge_stats"
    ensure_user_file "$stats_dir/purge_count"
    ensure_user_file "$stats_dir/purge_scanning"
    echo "0" > "$stats_dir/purge_stats"
    echo "0" > "$stats_dir/purge_count"
    echo "" > "$stats_dir/purge_scanning"
}

# Perform the purge
perform_purge() {
    local stats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/mole"
    local monitor_pid=""

    # Cleanup function
    cleanup_monitor() {
        # Remove scanning file to stop monitor
        rm -f "$stats_dir/purge_scanning" 2> /dev/null || true

        if [[ -n "$monitor_pid" ]]; then
            kill "$monitor_pid" 2> /dev/null || true
            wait "$monitor_pid" 2> /dev/null || true
        fi
        if [[ -t 1 ]]; then
            printf '\r\033[K\n\033[K\033[A'
        fi
    }

    # Set up trap for cleanup
    trap cleanup_monitor INT TERM

    # Show scanning with spinner on same line as title
    if [[ -t 1 ]]; then
        # Print title first
        printf '%s' "${PURPLE_BOLD}Purge Project Artifacts${NC} "

        # Start background monitor with ASCII spinner
        (
            local spinner_chars="|/-\\"
            local spinner_idx=0
            local last_path=""

            # Set up trap to exit cleanly
            trap 'exit 0' INT TERM

            # Function to truncate path in the middle
            truncate_path() {
                local path="$1"
                local term_cols
                term_cols=$(tput cols 2> /dev/null || echo 80)
                # Reserve some space for the spinner and text (approx 20 chars)
                local max_len=$((term_cols - 20))
                # Ensure a reasonable minimum width
                if ((max_len < 40)); then
                    max_len=40
                fi

                if [[ ${#path} -le $max_len ]]; then
                    echo "$path"
                    return
                fi

                # Calculate how much to show on each side
                local side_len=$(((max_len - 3) / 2))
                local start="${path:0:$side_len}"
                local end="${path: -$side_len}"
                echo "${start}...${end}"
            }

            while [[ -f "$stats_dir/purge_scanning" ]]; do
                local current_path=$(cat "$stats_dir/purge_scanning" 2> /dev/null || echo "")
                local display_path=""

                if [[ -n "$current_path" ]]; then
                    display_path="${current_path/#$HOME/~}"
                    display_path=$(truncate_path "$display_path")
                    last_path="$display_path"
                elif [[ -n "$last_path" ]]; then
                    display_path="$last_path"
                fi

                # Get current spinner character
                local spin_char="${spinner_chars:$spinner_idx:1}"
                spinner_idx=$(((spinner_idx + 1) % ${#spinner_chars}))

                # Show title on first line, spinner and scanning info on second line
                if [[ -n "$display_path" ]]; then
                    # Line 1: Move to start, clear, print title
                    printf '\r\033[K%s\n' "${PURPLE_BOLD}Purge Project Artifacts${NC}"
                    # Line 2: Move to start, clear, print scanning info
                    printf '\r\033[K%s %sScanning %s' \
                        "${BLUE}${spin_char}${NC}" \
                        "${GRAY}" "$display_path"
                    # Move up THEN to start (important order!)
                    printf '\033[A\r'
                else
                    printf '\r\033[K%s\n' "${PURPLE_BOLD}Purge Project Artifacts${NC}"
                    printf '\r\033[K%s %sScanning...' \
                        "${BLUE}${spin_char}${NC}" \
                        "${GRAY}"
                    printf '\033[A\r'
                fi

                sleep 0.05
            done
            exit 0
        ) &
        monitor_pid=$!
    else
        echo -e "${PURPLE_BOLD}Purge Project Artifacts${NC}"
    fi

    clean_project_artifacts
    local exit_code=$?

    # Clean up
    trap - INT TERM
    cleanup_monitor

    if [[ -t 1 ]]; then
        echo -e "${PURPLE_BOLD}Purge Project Artifacts${NC}"
    fi

    # Exit codes:
    # 0 = success, show summary
    # 1 = user cancelled
    # 2 = nothing to clean
    if [[ $exit_code -ne 0 ]]; then
        return 0
    fi

    # Final summary (matching clean.sh format)
    echo ""

    local summary_heading="Purge complete"
    local -a summary_details=()
    local total_size_cleaned=0
    local total_items_cleaned=0

    if [[ -f "$stats_dir/purge_stats" ]]; then
        total_size_cleaned=$(cat "$stats_dir/purge_stats" 2> /dev/null || echo "0")
        rm -f "$stats_dir/purge_stats"
    fi

    if [[ -f "$stats_dir/purge_count" ]]; then
        total_items_cleaned=$(cat "$stats_dir/purge_count" 2> /dev/null || echo "0")
        rm -f "$stats_dir/purge_count"
    fi

    if [[ $total_size_cleaned -gt 0 ]]; then
        local freed_gb
        freed_gb=$(echo "$total_size_cleaned" | awk '{printf "%.2f", $1/1024/1024}')

        summary_details+=("Space freed: ${GREEN}${freed_gb}GB${NC}")
        summary_details+=("Free space now: $(get_free_space)")

        if [[ $total_items_cleaned -gt 0 ]]; then
            summary_details+=("Items cleaned: $total_items_cleaned")
        fi
    else
        summary_details+=("No old project artifacts to clean.")
        summary_details+=("Free space now: $(get_free_space)")
    fi

    # Log session end
    log_operation_session_end "purge" "${total_items_cleaned:-0}" "${total_size_cleaned:-0}"

    print_summary_block "$summary_heading" "${summary_details[@]}"
    printf '\n'
}

# Show help message
show_help() {
    echo -e "${PURPLE_BOLD}Mole Purge${NC}, Clean old project build artifacts"
    echo ""
    echo -e "${YELLOW}Usage:${NC} mo purge [options]"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo "  --paths         Edit custom scan directories"
    echo "  --debug         Enable debug logging"
    echo "  --help          Show this help message"
    echo ""
    echo -e "${YELLOW}Default Paths:${NC}"
    for path in "${DEFAULT_PURGE_SEARCH_PATHS[@]}"; do
        echo "  * $path"
    done
}

# Main entry point
main() {
    # Set up signal handling
    trap 'show_cursor; exit 130' INT TERM

    # Parse arguments
    local -a orig_argv=("$@")
    while [[ $# -gt 0 ]]; do
        case "$1" in
            "--paths")
                source "$SCRIPT_DIR/../lib/manage/purge_paths.sh"
                manage_purge_paths
                exit 0
                ;;
            "--help")
                show_help
                exit 0
                ;;
            "--debug")
                export MO_DEBUG=1
                shift
                ;;
            "--json-scan")
                MOLE_JSON_COMMAND_MODE="scan"
                shift
                ;;
            "--apply")
                MOLE_JSON_COMMAND_MODE="apply"
                MOLE_JSON_APPLY_MANIFEST="${2:-}"
                if [[ -z "$MOLE_JSON_APPLY_MANIFEST" ]]; then
                    echo "--apply requires a manifest path" >&2
                    exit 2
                fi
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use 'mo purge --help' for usage information"
                exit 1
                ;;
        esac
    done

    if [[ -n "${MOLE_JSON_COMMAND_MODE:-}" ]]; then
        if ! mole_json_enabled; then
            echo "JSON contract mode requires MOLE_OUTPUT=json" >&2
            exit 2
        fi

        json_mode_setup_stdio

        local start_epoch
        start_epoch=$(date -u +%s 2> /dev/null || echo "0")

        local canceled_emitted=0
        emit_purge_json_canceled() {
            local signal_exit="$1"

            if [[ "${canceled_emitted:-0}" -eq 1 ]]; then
                exit "$signal_exit"
            fi
            canceled_emitted=1

            local cancel_epoch
            cancel_epoch=$(date -u +%s 2> /dev/null || echo "$start_epoch")
            local cancel_duration_ms=$(((cancel_epoch - start_epoch) * 1000))

            mole_json_emit_error "purge" "error" "canceled" "Operation canceled" "" "" "" ""
            mole_json_emit_operation_complete "purge" "false" "true" "$signal_exit" "$cancel_duration_ms" "{}" "{}"
            exit "$signal_exit"
        }

        trap 'emit_purge_json_canceled 130' INT
        trap 'emit_purge_json_canceled 143' TERM

        local exit_code=0
        if [[ "$MOLE_JSON_COMMAND_MODE" == "scan" ]]; then
            mole_json_emit_operation_start "purge" "scan" "true" "$0" "${orig_argv[@]}"
            maybe_trigger_purge_json_test_signal
            set +e
            purge_json_scan
            exit_code=$?
            set -e
        else
            mole_json_emit_operation_start "purge" "apply" "false" "$0" "${orig_argv[@]}"
            maybe_trigger_purge_json_test_signal
            local manifest_path="$MOLE_JSON_APPLY_MANIFEST"
            local tmp_manifest=""
            if [[ "$manifest_path" == "-" ]]; then
                tmp_manifest=$(mktemp_file "mole_purge_apply")
                cat > "$tmp_manifest"
                manifest_path="$tmp_manifest"
            fi
            set +e
            purge_json_apply "$manifest_path"
            exit_code=$?
            set -e
            [[ -n "$tmp_manifest" ]] && rm -f "$tmp_manifest" 2> /dev/null || true
        fi
        local end_epoch
        end_epoch=$(date -u +%s 2> /dev/null || echo "$start_epoch")
        local duration_ms=$(((end_epoch - start_epoch) * 1000))

        local success="true"
        [[ "$exit_code" -ne 0 ]] && success="false"
        mole_json_emit_operation_complete "purge" "$success" "false" "$exit_code" "$duration_ms" "{}" "{}"
        exit "$exit_code"
    fi

    start_purge
    hide_cursor
    perform_purge
    show_cursor
}

main "$@"
