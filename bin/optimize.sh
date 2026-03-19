#!/bin/bash
# Mole - Optimize command.
# Runs system maintenance checks and fixes.
# Supports dry-run where applicable.

set -euo pipefail

# Fix locale issues.
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/core/common.sh"

# Clean temp files on exit.
trap cleanup_temp_files EXIT INT TERM
source "$SCRIPT_DIR/lib/core/sudo.sh"
source "$SCRIPT_DIR/lib/manage/update.sh"
source "$SCRIPT_DIR/lib/manage/autofix.sh"
source "$SCRIPT_DIR/lib/optimize/maintenance.sh"
source "$SCRIPT_DIR/lib/optimize/tasks.sh"
source "$SCRIPT_DIR/lib/check/health_json.sh"
source "$SCRIPT_DIR/lib/check/all.sh"
source "$SCRIPT_DIR/lib/manage/whitelist.sh"

print_header() {
    printf '\n'
    echo -e "${PURPLE_BOLD}Optimize and Check${NC}"
}

run_system_checks() {
    # Skip checks in dry-run mode.
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi

    unset AUTO_FIX_SUMMARY AUTO_FIX_DETAILS
    unset MOLE_SECURITY_FIXES_SHOWN
    unset MOLE_SECURITY_FIXES_SKIPPED
    echo ""

    check_all_updates
    echo ""

    check_system_health
    echo ""

    check_all_security
    if ask_for_security_fixes; then
        perform_security_fixes
    fi
    if [[ "${MOLE_SECURITY_FIXES_SKIPPED:-}" != "true" ]]; then
        echo ""
    fi

    check_all_config
    echo ""

    show_suggestions

    if ask_for_updates; then
        perform_updates
    fi
    if ask_for_auto_fix; then
        perform_auto_fix
    fi
}

show_optimization_summary() {
    local safe_count="${OPTIMIZE_SAFE_COUNT:-0}"
    local confirm_count="${OPTIMIZE_CONFIRM_COUNT:-0}"
    if ((safe_count == 0 && confirm_count == 0)) && [[ -z "${AUTO_FIX_SUMMARY:-}" ]]; then
        return
    fi

    local summary_title
    local -a summary_details=()
    local total_applied=$((safe_count + confirm_count))

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        summary_title="Dry Run Complete, No Changes Made"
        summary_details+=("Would apply ${YELLOW}${total_applied:-0}${NC} optimizations")
        summary_details+=("Run without ${YELLOW}--dry-run${NC} to apply these changes")
    else
        summary_title="Optimization and Check Complete"

        # Build statistics summary
        local -a stats=()
        local cache_kb="${OPTIMIZE_CACHE_CLEANED_KB:-0}"
        local db_count="${OPTIMIZE_DATABASES_COUNT:-0}"
        local config_count="${OPTIMIZE_CONFIGS_REPAIRED:-0}"

        if [[ "$cache_kb" =~ ^[0-9]+$ ]] && [[ "$cache_kb" -gt 0 ]]; then
            local cache_human=$(bytes_to_human "$((cache_kb * 1024))")
            stats+=("${cache_human} cache cleaned")
        fi

        if [[ "$db_count" =~ ^[0-9]+$ ]] && [[ "$db_count" -gt 0 ]]; then
            stats+=("${db_count} databases optimized")
        fi

        if [[ "$config_count" =~ ^[0-9]+$ ]] && [[ "$config_count" -gt 0 ]]; then
            stats+=("${config_count} configs repaired")
        fi

        # Build first summary line with most important stat only
        local key_stat=""
        if [[ "$cache_kb" =~ ^[0-9]+$ ]] && [[ "$cache_kb" -gt 0 ]]; then
            local cache_human=$(bytes_to_human "$((cache_kb * 1024))")
            key_stat="${cache_human} cache cleaned"
        elif [[ "$db_count" =~ ^[0-9]+$ ]] && [[ "$db_count" -gt 0 ]]; then
            key_stat="${db_count} databases optimized"
        elif [[ "$config_count" =~ ^[0-9]+$ ]] && [[ "$config_count" -gt 0 ]]; then
            key_stat="${config_count} configs repaired"
        fi

        if [[ -n "$key_stat" ]]; then
            summary_details+=("Applied ${GREEN}${total_applied:-0}${NC} optimizations, ${key_stat}")
        else
            summary_details+=("Applied ${GREEN}${total_applied:-0}${NC} optimizations, all services tuned")
        fi

        local summary_line3=""
        if [[ -n "${AUTO_FIX_SUMMARY:-}" ]]; then
            summary_line3="${AUTO_FIX_SUMMARY}"
            if [[ -n "${AUTO_FIX_DETAILS:-}" ]]; then
                local detail_join
                detail_join=$(echo "${AUTO_FIX_DETAILS}" | paste -sd ", " -)
                [[ -n "$detail_join" ]] && summary_line3+=": ${detail_join}"
            fi
            summary_details+=("$summary_line3")
        fi
        summary_details+=("System fully optimized")
    fi

    print_summary_block "$summary_title" "${summary_details[@]}"
}

show_system_health() {
    local health_json="$1"

    local mem_used=$(echo "$health_json" | jq -r '.memory_used_gb // 0' 2> /dev/null || echo "0")
    local mem_total=$(echo "$health_json" | jq -r '.memory_total_gb // 0' 2> /dev/null || echo "0")
    local disk_used=$(echo "$health_json" | jq -r '.disk_used_gb // 0' 2> /dev/null || echo "0")
    local disk_total=$(echo "$health_json" | jq -r '.disk_total_gb // 0' 2> /dev/null || echo "0")
    local disk_percent=$(echo "$health_json" | jq -r '.disk_used_percent // 0' 2> /dev/null || echo "0")
    local uptime=$(echo "$health_json" | jq -r '.uptime_days // 0' 2> /dev/null || echo "0")

    mem_used=${mem_used:-0}
    mem_total=${mem_total:-0}
    disk_used=${disk_used:-0}
    disk_total=${disk_total:-0}
    disk_percent=${disk_percent:-0}
    uptime=${uptime:-0}

    printf "${ICON_ADMIN} System  %.0f/%.0f GB RAM | %.0f/%.0f GB Disk | Uptime %.0fd\n" \
        "$mem_used" "$mem_total" "$disk_used" "$disk_total" "$uptime"
}

parse_optimizations() {
    local health_json="$1"
    echo "$health_json" | jq -c '.optimizations[]' 2> /dev/null
}

announce_action() {
    local name="$1"
    local desc="$2"
    local kind="$3"

    if [[ "${FIRST_ACTION:-true}" == "true" ]]; then
        export FIRST_ACTION=false
    else
        echo ""
    fi
    echo -e "${BLUE}${ICON_ARROW} ${name}${NC}"
}

touchid_configured() {
    local pam_file="/etc/pam.d/sudo"
    [[ -f "$pam_file" ]] && grep -q "pam_tid.so" "$pam_file" 2> /dev/null
}

touchid_supported() {
    if command -v bioutil > /dev/null 2>&1; then
        if bioutil -r 2> /dev/null | grep -qi "Touch ID"; then
            return 0
        fi
    fi

    # Fallback: Apple Silicon Macs usually have Touch ID.
    if [[ "$(uname -m)" == "arm64" ]]; then
        return 0
    fi
    return 1
}

cleanup_path() {
    local raw_path="$1"
    local label="$2"

    local expanded_path="${raw_path/#\~/$HOME}"
    if [[ ! -e "$expanded_path" ]]; then
        echo -e "${GREEN}${ICON_SUCCESS}${NC} $label"
        return
    fi
    if should_protect_path "$expanded_path"; then
        echo -e "${GRAY}${ICON_WARNING}${NC} Protected $label"
        return
    fi

    local size_kb
    size_kb=$(get_path_size_kb "$expanded_path")
    local size_display=""
    if [[ "$size_kb" =~ ^[0-9]+$ && "$size_kb" -gt 0 ]]; then
        size_display=$(bytes_to_human "$((size_kb * 1024))")
    fi

    local removed=false
    if safe_remove "$expanded_path" true; then
        removed=true
    elif request_sudo_access "Removing $label requires admin access"; then
        if safe_sudo_remove "$expanded_path"; then
            removed=true
        fi
    fi

    if [[ "$removed" == "true" ]]; then
        if [[ -n "$size_display" ]]; then
            echo -e "${GREEN}${ICON_SUCCESS}${NC} $label${NC}, ${GREEN}${size_display}${NC}"
        else
            echo -e "${GREEN}${ICON_SUCCESS}${NC} $label"
        fi
    else
        echo -e "${GRAY}${ICON_WARNING}${NC} Skipped $label${GRAY}, grant Full Disk Access to your terminal and retry${NC}"
    fi
}

ensure_directory() {
    local raw_path="$1"
    local expanded_path="${raw_path/#\~/$HOME}"
    ensure_user_dir "$expanded_path"
}

declare -a SECURITY_FIXES=()

collect_security_fix_actions() {
    SECURITY_FIXES=()
    if [[ "${FIREWALL_DISABLED:-}" == "true" ]]; then
        if ! is_whitelisted "firewall"; then
            SECURITY_FIXES+=("firewall|Enable macOS firewall")
        fi
    fi
    if [[ "${GATEKEEPER_DISABLED:-}" == "true" ]]; then
        if ! is_whitelisted "gatekeeper"; then
            SECURITY_FIXES+=("gatekeeper|Enable Gatekeeper, app download protection")
        fi
    fi
    if touchid_supported && ! touchid_configured; then
        if ! is_whitelisted "check_touchid"; then
            SECURITY_FIXES+=("touchid|Enable Touch ID for sudo")
        fi
    fi

    ((${#SECURITY_FIXES[@]} > 0))
}

ask_for_security_fixes() {
    if ! collect_security_fix_actions; then
        return 1
    fi

    echo ""
    echo -e "${BLUE}SECURITY FIXES${NC}"
    for entry in "${SECURITY_FIXES[@]}"; do
        IFS='|' read -r _ label <<< "$entry"
        echo -e "  ${ICON_LIST} $label"
    done
    echo ""
    export MOLE_SECURITY_FIXES_SHOWN=true
    echo -ne "${YELLOW}Apply now?${NC} ${GRAY}Enter confirm / Space cancel${NC}: "

    local key
    if ! key=$(read_key); then
        export MOLE_SECURITY_FIXES_SKIPPED=true
        echo -e "\n  ${GRAY}${ICON_WARNING}${NC} Security fixes skipped"
        echo ""
        return 1
    fi

    if [[ "$key" == "ENTER" ]]; then
        echo ""
        return 0
    else
        export MOLE_SECURITY_FIXES_SKIPPED=true
        echo -e "\n  ${GRAY}${ICON_WARNING}${NC} Security fixes skipped"
        echo ""
        return 1
    fi
}

apply_firewall_fix() {
    if sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on > /dev/null 2>&1; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Firewall enabled"
        FIREWALL_DISABLED=false
        return 0
    fi
    echo -e "  ${GRAY}${ICON_WARNING}${NC} Failed to enable firewall, check permissions"
    return 1
}

apply_gatekeeper_fix() {
    if sudo spctl --master-enable 2> /dev/null; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Gatekeeper enabled"
        GATEKEEPER_DISABLED=false
        return 0
    fi
    echo -e "  ${GRAY}${ICON_WARNING}${NC} Failed to enable Gatekeeper"
    return 1
}

apply_touchid_fix() {
    if "$SCRIPT_DIR/bin/touchid.sh" enable; then
        return 0
    fi
    return 1
}

perform_security_fixes() {
    if ! ensure_sudo_session "Security changes require admin access"; then
        echo -e "${GRAY}${ICON_WARNING}${NC} Skipped security fixes, sudo denied"
        return 1
    fi

    local applied=0
    for entry in "${SECURITY_FIXES[@]}"; do
        IFS='|' read -r action _ <<< "$entry"
        case "$action" in
            firewall)
                apply_firewall_fix && ((applied++))
                ;;
            gatekeeper)
                apply_gatekeeper_fix && ((applied++))
                ;;
            touchid)
                apply_touchid_fix && ((applied++))
                ;;
        esac
    done

    if ((applied > 0)); then
        log_success "Security settings updated"
    fi
    SECURITY_FIXES=()
}

cleanup_all() {
    stop_inline_spinner 2> /dev/null || true
    stop_sudo_session
    cleanup_temp_files
    # Log session end
    log_operation_session_end "optimize" "${OPTIMIZE_SAFE_COUNT:-0}" "0"
}

handle_interrupt() {
    cleanup_all
    exit 130
}

maybe_trigger_optimize_json_test_signal() {
    local signal_name="${MOLE_OPTIMIZE_TEST_SIGNAL:-}"
    [[ -z "$signal_name" ]] && return 0

    kill -s "$signal_name" "$$" 2> /dev/null || true
}

main() {
    # Set current command for operation logging
    export MOLE_CURRENT_COMMAND="optimize"

    local -a orig_argv=("$@")
    local json_mode=""
    local json_apply_manifest=""

    local health_json
    while [[ $# -gt 0 ]]; do
        case "$1" in
            "--debug")
                export MO_DEBUG=1
                shift
                ;;
            "--dry-run")
                export MOLE_DRY_RUN=1
                shift
                ;;
            "--whitelist")
                manage_whitelist "optimize"
                exit 0
                ;;
            "--json-scan")
                json_mode="scan"
                shift
                ;;
            "--apply")
                json_mode="apply"
                json_apply_manifest="${2:-}"
                if [[ -z "$json_apply_manifest" ]]; then
                    log_error "--apply requires a manifest path"
                    exit 2
                fi
                shift 2
                ;;
            *)
                # Preserve unknown args for standard (non-JSON) flow below.
                shift
                ;;
        esac
    done

    if [[ -n "$json_mode" ]]; then
        if ! mole_json_enabled; then
            log_error "JSON contract mode requires MOLE_OUTPUT=json"
            exit 2
        fi

        # Keep stdout clean for NDJSON by routing all non-JSON output to stderr.
        exec 3>&1 1>&2
        export MOLE_JSON_OUT_FD=3

        local start_epoch
        start_epoch=$(date -u +%s 2> /dev/null || echo "0")

        local canceled_emitted=0
        emit_optimize_json_canceled() {
            local signal_exit="$1"

            if [[ "${canceled_emitted:-0}" -eq 1 ]]; then
                exit "$signal_exit"
            fi
            canceled_emitted=1

            local cancel_epoch
            cancel_epoch=$(date -u +%s 2> /dev/null || echo "$start_epoch")
            local cancel_duration_ms=$(((cancel_epoch - start_epoch) * 1000))

            mole_json_emit_error "optimize" "error" "canceled" "Operation canceled" "" "" "" ""
            mole_json_emit_operation_complete "optimize" "false" "true" "$signal_exit" "$cancel_duration_ms" "{}" "{}"
            exit "$signal_exit"
        }

        trap 'emit_optimize_json_canceled 130' INT
        trap 'emit_optimize_json_canceled 143' TERM

        if [[ "$json_mode" == "scan" ]]; then
            mole_json_emit_operation_start "optimize" "scan" "true" "$0" "${orig_argv[@]}"
        else
            mole_json_emit_operation_start "optimize" "apply" "false" "$0" "${orig_argv[@]}"
        fi

        maybe_trigger_optimize_json_test_signal

        if ! command -v jq > /dev/null 2>&1; then
            mole_json_emit_error "optimize" "error" "unknown" "Missing dependency: jq" "" "" "" ""
            mole_json_emit_operation_complete "optimize" "false" "false" "1" "0" "{}" "{}"
            exit 1
        fi

        if ! command -v bc > /dev/null 2>&1; then
            mole_json_emit_error "optimize" "error" "unknown" "Missing dependency: bc" "" "" "" ""
            mole_json_emit_operation_complete "optimize" "false" "false" "1" "0" "{}" "{}"
            exit 1
        fi

        if ! health_json=$(generate_health_json 2> /dev/null); then
            mole_json_emit_error "optimize" "error" "unknown" "Failed to collect system health data" "" "" "" ""
            mole_json_emit_operation_complete "optimize" "false" "false" "1" "0" "{}" "{}"
            exit 1
        fi

        if [[ "$json_mode" == "scan" ]]; then
            local count=0
            while IFS= read -r opt_json; do
                [[ -z "$opt_json" ]] && continue
                local category name desc action safe
                category=$(echo "$opt_json" | jq -r '.category // "system"' 2> /dev/null || echo "system")
                name=$(echo "$opt_json" | jq -r '.name // ""' 2> /dev/null || echo "")
                desc=$(echo "$opt_json" | jq -r '.description // ""' 2> /dev/null || echo "")
                action=$(echo "$opt_json" | jq -r '.action // ""' 2> /dev/null || echo "")
                safe=$(echo "$opt_json" | jq -r '.safe // false' 2> /dev/null || echo "false")

                mole_json_emit_event "optimize" "optimization_available" \
                    "{\"category\":$(mole_json_quote "$category"),\"action\":$(mole_json_quote "$action"),\"name\":$(mole_json_quote "$name"),\"description\":$(mole_json_quote "$desc"),\"safe\":$safe}"
                count=$((count + 1))
            done < <(echo "$health_json" | jq -c '.optimizations[]' 2> /dev/null || true)

            mole_json_emit_event "optimize" "summary" "{\"count\":$count}"
            mole_json_emit_operation_complete "optimize" "true" "false" "0" "0" "{}" "{}"
            exit 0
        fi

        # apply
        local manifest_path="$json_apply_manifest"
        local tmp_manifest=""
        if [[ "$manifest_path" == "-" ]]; then
            tmp_manifest=$(mktemp_file "mole_optimize_apply")
            cat > "$tmp_manifest"
            manifest_path="$tmp_manifest"
        fi

        local schema_version
        schema_version=$(jq -r '.schema_version // empty' "$manifest_path" 2> /dev/null || echo "")
        local op
        op=$(jq -r '.operation // empty' "$manifest_path" 2> /dev/null || echo "")
        if [[ "$schema_version" != "1" || "$op" != "optimize" ]]; then
            mole_json_emit_error "optimize" "error" "unknown" "Invalid manifest (schema_version/operation)" "" "" "" ""
            [[ -n "$tmp_manifest" ]] && rm -f "$tmp_manifest" 2> /dev/null || true
            mole_json_emit_operation_complete "optimize" "false" "false" "2" "0" "{}" "{}"
            exit 2
        fi

        local -a actions=()
        local action_line
        while IFS= read -r action_line; do
            [[ -z "$action_line" ]] && continue
            actions+=("$action_line")
        done < <(jq -r '.payload.actions[]? // empty' "$manifest_path" 2> /dev/null || true)
        [[ -n "$tmp_manifest" ]] && rm -f "$tmp_manifest" 2> /dev/null || true

        local can_sudo=false
        if sudo -n true 2> /dev/null; then
            can_sudo=true
        fi

        local any_failed=false
        local action
        for action in "${actions[@]}"; do
            [[ -z "$action" ]] && continue

            # Lookup metadata for name/description/path.
            local opt
            opt=$(echo "$health_json" | jq -c --arg a "$action" '.optimizations[] | select(.action == $a) | . ' 2> /dev/null | head -n 1 || true)
            local name desc path
            name=$(echo "${opt:-{}}" | jq -r '.name // $a' --arg a "$action" 2> /dev/null || echo "$action")
            desc=$(echo "${opt:-{}}" | jq -r '.description // ""' 2> /dev/null || echo "")
            path=$(echo "${opt:-{}}" | jq -r '.path // ""' 2> /dev/null || echo "")

            mole_json_emit_event "optimize" "optimization_start" \
                "{\"action\":$(mole_json_quote "$action"),\"name\":$(mole_json_quote "$name")}"

            if [[ "$can_sudo" != "true" && "${MOLE_DRY_RUN:-0}" != "1" ]]; then
                mole_json_emit_event "optimize" "optimization_complete" \
                    "{\"action\":$(mole_json_quote "$action"),\"success\":false,\"message\":$(mole_json_quote "Admin privileges required (sudo -n unavailable)")}"
                any_failed=true
                continue
            fi

            if execute_optimization "$action" "$path"; then
                mole_json_emit_event "optimize" "optimization_complete" \
                    "{\"action\":$(mole_json_quote "$action"),\"success\":true,\"message\":$(mole_json_quote "$desc")}"
            else
                mole_json_emit_event "optimize" "optimization_complete" \
                    "{\"action\":$(mole_json_quote "$action"),\"success\":false,\"message\":$(mole_json_quote "Failed")}"
                any_failed=true
            fi
        done

        local end_epoch
        end_epoch=$(date -u +%s 2> /dev/null || echo "$start_epoch")
        local duration_ms=$(((end_epoch - start_epoch) * 1000))
        local success="true"
        [[ "$any_failed" == "true" ]] && success="false"
        mole_json_emit_operation_complete "optimize" "$success" "false" "$([[ "$any_failed" == "true" ]] && echo 1 || echo 0)" "$duration_ms" "{}" "{}"
        [[ "$any_failed" == "true" ]] && exit 1
        exit 0
    fi

    log_operation_session_start "optimize"

    trap cleanup_all EXIT
    trap handle_interrupt INT TERM

    if [[ -t 1 ]]; then
        clear_screen
    fi
    print_header

    # Dry-run indicator.
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, No files will be modified\n"
    fi

    if ! command -v jq > /dev/null 2>&1; then
        echo -e "${YELLOW}${ICON_ERROR}${NC} Missing dependency: jq"
        echo -e "${GRAY}Install with: ${GREEN}brew install jq${NC}"
        exit 1
    fi

    if ! command -v bc > /dev/null 2>&1; then
        echo -e "${YELLOW}${ICON_ERROR}${NC} Missing dependency: bc"
        echo -e "${GRAY}Install with: ${GREEN}brew install bc${NC}"
        exit 1
    fi

    if [[ -t 1 ]]; then
        start_inline_spinner "Collecting system info..."
    fi

    if ! health_json=$(generate_health_json 2> /dev/null); then
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        echo ""
        log_error "Failed to collect system health data"
        exit 1
    fi

    if ! echo "$health_json" | jq empty 2> /dev/null; then
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        echo ""
        log_error "Invalid system health data format"
        echo -e "${YELLOW}Tip:${NC} Check if jq, awk, sysctl, and df commands are available"
        exit 1
    fi

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    show_system_health "$health_json"

    load_whitelist "optimize"
    if [[ ${#CURRENT_WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        local count=${#CURRENT_WHITELIST_PATTERNS[@]}
        if [[ $count -le 3 ]]; then
            local patterns_list=$(
                IFS=', '
                echo "${CURRENT_WHITELIST_PATTERNS[*]}"
            )
            echo -e "${ICON_ADMIN} Active Whitelist: ${patterns_list}"
        fi
    fi

    local -a safe_items=()
    local -a confirm_items=()
    local opts_file
    opts_file=$(mktemp_file)
    parse_optimizations "$health_json" > "$opts_file"

    while IFS= read -r opt_json; do
        [[ -z "$opt_json" ]] && continue

        local name=$(echo "$opt_json" | jq -r '.name')
        local desc=$(echo "$opt_json" | jq -r '.description')
        local action=$(echo "$opt_json" | jq -r '.action')
        local path=$(echo "$opt_json" | jq -r '.path // ""')
        local safe=$(echo "$opt_json" | jq -r '.safe')

        local item="${name}|${desc}|${action}|${path}"

        if [[ "$safe" == "true" ]]; then
            safe_items+=("$item")
        else
            confirm_items+=("$item")
        fi
    done < "$opts_file"

    echo ""
    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        ensure_sudo_session "System optimization requires admin access" || true
    fi

    export FIRST_ACTION=true
    if [[ ${#safe_items[@]} -gt 0 ]]; then
        for item in "${safe_items[@]}"; do
            IFS='|' read -r name desc action path <<< "$item"
            announce_action "$name" "$desc" "safe"
            execute_optimization "$action" "$path"
        done
    fi

    if [[ ${#confirm_items[@]} -gt 0 ]]; then
        for item in "${confirm_items[@]}"; do
            IFS='|' read -r name desc action path <<< "$item"
            announce_action "$name" "$desc" "confirm"
            execute_optimization "$action" "$path"
        done
    fi

    local safe_count=${#safe_items[@]}
    local confirm_count=${#confirm_items[@]}

    run_system_checks

    export OPTIMIZE_SAFE_COUNT=$safe_count
    export OPTIMIZE_CONFIRM_COUNT=$confirm_count

    show_optimization_summary

    printf '\n'
}

main "$@"
