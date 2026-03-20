#!/bin/bash
# Mole - Installer command
# Find and remove installer files - .dmg, .pkg, .mpkg, .iso, .xip, .zip

set -euo pipefail

# shellcheck disable=SC2154
# External variables set by menu_paginated.sh and environment
declare MOLE_SELECTION_RESULT
declare MOLE_INSTALLER_SCAN_MAX_DEPTH

export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
source "$SCRIPT_DIR/../lib/ui/menu_paginated.sh"

MOLE_JSON_COMMAND_MODE=""
MOLE_JSON_APPLY_MANIFEST=""

cleanup() {
    if [[ "${IN_ALT_SCREEN:-0}" == "1" ]]; then
        leave_alt_screen
        IN_ALT_SCREEN=0
    fi
    show_cursor
    cleanup_temp_files
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT TERM

json_mode_setup_stdio() {
    # Keep stdout clean for NDJSON by routing all non-JSON output to stderr.
    exec 3>&1 1>&2
    export MOLE_JSON_OUT_FD=3
}

maybe_trigger_installer_json_test_signal() {
    local signal_name="${MOLE_INSTALLER_TEST_SIGNAL:-}"
    [[ -z "$signal_name" ]] && return 0

    kill -s "$signal_name" "$$" 2> /dev/null || true
}

json_mode_emit_summary() {
    local count="$1"
    local size_bytes="$2"
    mole_json_emit_event "installer" "summary" \
        "{\"installer_count\":$count,\"total_size_bytes\":$size_bytes}"
}

installer_mtime_rfc3339() {
    local mtime="${1:-0}"
    if [[ ! "$mtime" =~ ^[0-9]+$ || "$mtime" -le 0 ]]; then
        printf '1970-01-01T00:00:00Z'
        return 0
    fi

    "$_DATE_CMD" -u -r "$mtime" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null || printf '1970-01-01T00:00:00Z'
}

json_scan_installers() {
    local total_count=0
    local total_size=0
    local current_epoch=0
    current_epoch=$(get_epoch_seconds)
    [[ ! "$current_epoch" =~ ^[0-9]+$ ]] && current_epoch=0

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local size=0
        size=$(get_file_size "$file" 2> /dev/null || echo "0")
        [[ ! "$size" =~ ^[0-9]+$ ]] && size=0
        local mtime=0
        mtime=$(get_file_mtime "$file" 2> /dev/null || echo "0")
        [[ ! "$mtime" =~ ^[0-9]+$ ]] && mtime=0
        local modified_at
        modified_at=$(installer_mtime_rfc3339 "$mtime")
        local age_days=0
        if [[ "$mtime" -gt 0 && "$current_epoch" -ge "$mtime" ]]; then
            age_days=$(((current_epoch - mtime) / 86400))
        fi
        local source
        source=$(get_source_display "$file")

        local display_name
        display_name=$(basename "$file")
        if [[ "$source" == "Homebrew" ]]; then
            if [[ "$display_name" =~ ^[0-9a-f]{64}--(.*) ]]; then
                display_name="${BASH_REMATCH[1]}"
            fi
        fi

        mole_json_emit_event "installer" "installer_found" \
            "{\"path\":$(mole_json_quote "$file"),\"display_name\":$(mole_json_quote "$display_name"),\"source\":$(mole_json_quote "$source"),\"size_bytes\":$size,\"modified_at\":$(mole_json_quote "$modified_at"),\"age_days\":$age_days}"

        total_size=$((total_size + size))
        total_count=$((total_count + 1))
    done < <(scan_all_installers | sort -u)

    json_mode_emit_summary "$total_count" "$total_size"
    return 0
}

json_apply_installers() {
    local manifest="$1"
    if ! command -v jq > /dev/null 2>&1; then
        mole_json_emit_error "installer" "error" "unknown" "jq is required to parse apply manifests" "" "" "" ""
        return 2
    fi

    local schema_version
    schema_version=$(jq -r '.schema_version // empty' "$manifest" 2> /dev/null || echo "")
    local op
    op=$(jq -r '.operation // empty' "$manifest" 2> /dev/null || echo "")
    if [[ "$schema_version" != "1" || "$op" != "installer" ]]; then
        mole_json_emit_error "installer" "error" "unknown" "Invalid manifest (schema_version/operation)" "" "" "" ""
        return 2
    fi

    local -a paths=()
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        paths+=("$p")
    done < <(jq -r '.payload.paths[]? // empty' "$manifest" 2> /dev/null || true)
    local removed=0
    local removed_size=0

    local path
    for path in "${paths[@]}"; do
        [[ -z "$path" ]] && continue
        if [[ ! -e "$path" ]]; then
            mole_json_emit_event "installer" "installer_skipped" \
                "{\"path\":$(mole_json_quote "$path"),\"reason\":$(mole_json_quote "missing")}"
            continue
        fi

        if ! validate_path_for_deletion "$path"; then
            mole_json_emit_event "installer" "installer_skipped" \
                "{\"path\":$(mole_json_quote "$path"),\"reason\":$(mole_json_quote "protected")}"
            continue
        fi

        local size=0
        size=$(get_file_size "$path" 2> /dev/null || echo "0")
        [[ ! "$size" =~ ^[0-9]+$ ]] && size=0

        if safe_remove "$path" true; then
            mole_json_emit_event "installer" "installer_removed" \
                "{\"path\":$(mole_json_quote "$path"),\"size_bytes\":$size}"
            removed=$((removed + 1))
            removed_size=$((removed_size + size))
        else
            mole_json_emit_event "installer" "installer_failed" \
                "{\"path\":$(mole_json_quote "$path"),\"reason\":$(mole_json_quote "unknown")}"
        fi
    done

    json_mode_emit_summary "$removed" "$removed_size"
    return 0
}

# Scan configuration
readonly INSTALLER_SCAN_MAX_DEPTH_DEFAULT=2
readonly INSTALLER_SCAN_PATHS=(
    "$HOME/Downloads"
    "$HOME/Desktop"
    "$HOME/Documents"
    "$HOME/Public"
    "$HOME/Library/Downloads"
    "/Users/Shared"
    "/Users/Shared/Downloads"
    "$HOME/Library/Caches/Homebrew"
    "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
    "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    "$HOME/Library/Application Support/Telegram Desktop"
    "$HOME/Downloads/Telegram Desktop"
)
readonly MAX_ZIP_ENTRIES=50
ZIP_LIST_CMD=()
IN_ALT_SCREEN=0

if command -v zipinfo > /dev/null 2>&1; then
    ZIP_LIST_CMD=(zipinfo -1)
elif command -v unzip > /dev/null 2>&1; then
    ZIP_LIST_CMD=(unzip -Z -1)
fi

TERMINAL_WIDTH=0

# Check for installer payloads inside ZIP - check first N entries for installer patterns
is_installer_zip() {
    local zip="$1"
    local cap="$MAX_ZIP_ENTRIES"

    [[ ${#ZIP_LIST_CMD[@]} -gt 0 ]] || return 1

    if ! "${ZIP_LIST_CMD[@]}" "$zip" 2> /dev/null |
        head -n "$cap" |
        awk '
            /\.(app|pkg|dmg|xip)(\/|$)/ { found=1; exit 0 }
            END { exit found ? 0 : 1 }
        '; then
        return 1
    fi

    return 0
}

handle_candidate_file() {
    local file="$1"

    [[ -L "$file" ]] && return 0 # Skip symlinks explicitly
    case "$file" in
        *.dmg | *.pkg | *.mpkg | *.iso | *.xip)
            echo "$file"
            ;;
        *.zip)
            [[ -r "$file" ]] || return 0
            if is_installer_zip "$file" 2> /dev/null; then
                echo "$file"
            fi
            ;;
    esac
}

scan_installers_in_path() {
    local path="$1"
    local max_depth="${MOLE_INSTALLER_SCAN_MAX_DEPTH:-$INSTALLER_SCAN_MAX_DEPTH_DEFAULT}"

    [[ -d "$path" ]] || return 0

    local file

    if command -v fd > /dev/null 2>&1; then
        while IFS= read -r file; do
            handle_candidate_file "$file"
        done < <(
            fd --no-ignore --hidden --type f --max-depth "$max_depth" \
                -e dmg -e pkg -e mpkg -e iso -e xip -e zip \
                . "$path" 2> /dev/null || true
        )
    else
        while IFS= read -r file; do
            handle_candidate_file "$file"
        done < <(
            find "$path" -maxdepth "$max_depth" -type f \
                \( -name '*.dmg' -o -name '*.pkg' -o -name '*.mpkg' \
                -o -name '*.iso' -o -name '*.xip' -o -name '*.zip' \) \
                2> /dev/null || true
        )
    fi
}

scan_all_installers() {
    for path in "${INSTALLER_SCAN_PATHS[@]}"; do
        scan_installers_in_path "$path"
    done
}

# Initialize stats
declare -i total_deleted=0
declare -i total_size_freed_kb=0

# Global arrays for installer data
declare -a INSTALLER_PATHS=()
declare -a INSTALLER_SIZES=()
declare -a INSTALLER_SOURCES=()
declare -a DISPLAY_NAMES=()

# Get source directory display name - for example "Downloads" or "Desktop"
get_source_display() {
    local file_path="$1"
    local dir_path="${file_path%/*}"

    # Match against known paths and return friendly names
    case "$dir_path" in
        "$HOME/Downloads"*) echo "Downloads" ;;
        "$HOME/Desktop"*) echo "Desktop" ;;
        "$HOME/Documents"*) echo "Documents" ;;
        "$HOME/Public"*) echo "Public" ;;
        "$HOME/Library/Downloads"*) echo "Library" ;;
        "/Users/Shared"*) echo "Shared" ;;
        "$HOME/Library/Caches/Homebrew"*) echo "Homebrew" ;;
        "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads"*) echo "iCloud" ;;
        "$HOME/Library/Containers/com.apple.mail"*) echo "Mail" ;;
        *"Telegram Desktop"*) echo "Telegram" ;;
        *) echo "${dir_path##*/}" ;;
    esac
}

get_terminal_width() {
    if [[ $TERMINAL_WIDTH -le 0 ]]; then
        TERMINAL_WIDTH=$(tput cols 2> /dev/null || echo 80)
    fi
    echo "$TERMINAL_WIDTH"
}

# Format installer display with alignment - similar to purge command
format_installer_display() {
    local filename="$1"
    local size_str="$2"
    local source="$3"

    # Terminal width for alignment
    local terminal_width
    terminal_width=$(get_terminal_width)
    local fixed_width=24 # Reserve for size and source
    local available_width=$((terminal_width - fixed_width))

    # Bounds check: 20-40 chars for filename
    [[ $available_width -lt 20 ]] && available_width=20
    [[ $available_width -gt 40 ]] && available_width=40

    # Truncate filename if needed
    local truncated_name
    truncated_name=$(truncate_by_display_width "$filename" "$available_width")
    local current_width
    current_width=$(get_display_width "$truncated_name")
    local char_count=${#truncated_name}
    local padding=$((available_width - current_width))
    local printf_width=$((char_count + padding))

    # Format: "filename  size | source"
    printf "%-*s %8s | %-10s" "$printf_width" "$truncated_name" "$size_str" "$source"
}

# Collect all installers with their metadata
collect_installers() {
    # Clear previous results
    INSTALLER_PATHS=()
    INSTALLER_SIZES=()
    INSTALLER_SOURCES=()
    DISPLAY_NAMES=()

    # Start scanning with spinner
    if [[ -t 1 ]]; then
        start_inline_spinner "Scanning for installers..."
    fi

    # Start debug session
    debug_operation_start "Collect Installers" "Scanning for redundant installer files"

    # Scan all paths, deduplicate, and sort results
    local -a all_files=()

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        all_files+=("$file")
        debug_file_action "Found installer" "$file"
    done < <(scan_all_installers | sort -u)

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ ${#all_files[@]} -eq 0 ]]; then
        if [[ "${IN_ALT_SCREEN:-0}" != "1" ]]; then
            echo -e "${GREEN}${ICON_SUCCESS}${NC} Great! No installer files to clean"
        fi
        return 1
    fi

    # Calculate sizes with spinner
    if [[ -t 1 ]]; then
        start_inline_spinner "Calculating sizes..."
    fi

    # Process each installer
    for file in "${all_files[@]}"; do
        # Calculate file size
        local file_size=0
        if [[ -f "$file" ]]; then
            file_size=$(get_file_size "$file")
        fi

        # Get source directory
        local source
        source=$(get_source_display "$file")

        # Format human readable size
        local size_human
        size_human=$(bytes_to_human "$file_size")

        # Get display filename - strip Homebrew hash prefix if present
        local display_name
        display_name=$(basename "$file")
        if [[ "$source" == "Homebrew" ]]; then
            # Homebrew names often look like: sha256--name--version
            # Strip the leading hash if it matches [0-9a-f]{64}--
            if [[ "$display_name" =~ ^[0-9a-f]{64}--(.*) ]]; then
                display_name="${BASH_REMATCH[1]}"
            fi
        fi

        # Format display with alignment
        local display
        display=$(format_installer_display "$display_name" "$size_human" "$source")

        # Store installer data in parallel arrays
        INSTALLER_PATHS+=("$file")
        INSTALLER_SIZES+=("$file_size")
        INSTALLER_SOURCES+=("$source")
        DISPLAY_NAMES+=("$display")
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi
    return 0
}

# Installer selector with Select All / Invert support
select_installers() {
    local -a items=("$@")
    local total_items=${#items[@]}
    local clear_line=$'\r\033[2K'

    if [[ $total_items -eq 0 ]]; then
        return 1
    fi

    # Calculate items per page based on terminal height
    _get_items_per_page() {
        local term_height=24
        if [[ -t 0 ]] || [[ -t 2 ]]; then
            term_height=$(stty size < /dev/tty 2> /dev/null | awk '{print $1}')
        fi
        if [[ -z "$term_height" || $term_height -le 0 ]]; then
            if command -v tput > /dev/null 2>&1; then
                term_height=$(tput lines 2> /dev/null || echo "24")
            else
                term_height=24
            fi
        fi
        local reserved=6
        local available=$((term_height - reserved))
        if [[ $available -lt 3 ]]; then
            echo 3
        elif [[ $available -gt 50 ]]; then
            echo 50
        else
            echo "$available"
        fi
    }

    local items_per_page=$(_get_items_per_page)
    local cursor_pos=0
    local top_index=0

    # Initialize selection (all unselected by default)
    local -a selected=()
    for ((i = 0; i < total_items; i++)); do
        selected[i]=false
    done

    local original_stty=""
    if [[ -t 0 ]] && command -v stty > /dev/null 2>&1; then
        original_stty=$(stty -g 2> /dev/null || echo "")
    fi

    restore_terminal() {
        trap - EXIT INT TERM
        if [[ "${IN_ALT_SCREEN:-0}" == "1" ]]; then
            leave_alt_screen
            IN_ALT_SCREEN=0
        fi
        show_cursor
        if [[ -n "${original_stty:-}" ]]; then
            stty "${original_stty}" 2> /dev/null || stty sane 2> /dev/null || true
        fi
    }

    handle_interrupt() {
        restore_terminal
        exit 130
    }

    draw_menu() {
        items_per_page=$(_get_items_per_page)

        local max_top_index=0
        if [[ $total_items -gt $items_per_page ]]; then
            max_top_index=$((total_items - items_per_page))
        fi
        if [[ $top_index -gt $max_top_index ]]; then
            top_index=$max_top_index
        fi
        if [[ $top_index -lt 0 ]]; then
            top_index=0
        fi

        local visible_count=$((total_items - top_index))
        [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
        if [[ $cursor_pos -gt $((visible_count - 1)) ]]; then
            cursor_pos=$((visible_count - 1))
        fi
        if [[ $cursor_pos -lt 0 ]]; then
            cursor_pos=0
        fi

        printf "\033[H"

        # Calculate selected size and count
        local selected_size=0
        local selected_count=0
        for ((i = 0; i < total_items; i++)); do
            if [[ ${selected[i]} == true ]]; then
                selected_size=$((selected_size + ${INSTALLER_SIZES[i]:-0}))
                ((selected_count++))
            fi
        done
        local selected_human
        selected_human=$(bytes_to_human "$selected_size")

        # Show position indicator if scrolling is needed
        local scroll_indicator=""
        if [[ $total_items -gt $items_per_page ]]; then
            local current_pos=$((top_index + cursor_pos + 1))
            scroll_indicator=" ${GRAY}[${current_pos}/${total_items}]${NC}"
        fi

        printf "${PURPLE_BOLD}Select Installers to Remove${NC}%s ${GRAY}, ${selected_human}, ${selected_count} selected${NC}\n" "$scroll_indicator"
        printf "%s\n" "$clear_line"

        # Calculate visible range
        local end_index=$((top_index + visible_count))

        # Draw only visible items
        for ((i = top_index; i < end_index; i++)); do
            local checkbox="$ICON_EMPTY"
            [[ ${selected[i]} == true ]] && checkbox="$ICON_SOLID"
            local rel_pos=$((i - top_index))
            if [[ $rel_pos -eq $cursor_pos ]]; then
                printf "%s${CYAN}${ICON_ARROW} %s %s${NC}\n" "$clear_line" "$checkbox" "${items[i]}"
            else
                printf "%s  %s %s\n" "$clear_line" "$checkbox" "${items[i]}"
            fi
        done

        # Fill empty slots
        local items_shown=$visible_count
        for ((i = items_shown; i < items_per_page; i++)); do
            printf "%s\n" "$clear_line"
        done

        printf "%s\n" "$clear_line"
        printf "%s${GRAY}${ICON_NAV_UP}${ICON_NAV_DOWN}  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit${NC}\n" "$clear_line"
    }

    trap restore_terminal EXIT
    trap handle_interrupt INT TERM
    stty -echo -icanon intr ^C 2> /dev/null || true
    hide_cursor
    if [[ -t 1 ]]; then
        printf "\033[2J\033[H" >&2
    fi

    # Main loop
    while true; do
        draw_menu

        IFS= read -r -s -n1 key || key=""
        case "$key" in
            $'\x1b')
                IFS= read -r -s -n1 -t 1 key2 || key2=""
                if [[ "$key2" == "[" ]]; then
                    IFS= read -r -s -n1 -t 1 key3 || key3=""
                    case "$key3" in
                        A) # Up arrow
                            if [[ $cursor_pos -gt 0 ]]; then
                                ((cursor_pos--))
                            elif [[ $top_index -gt 0 ]]; then
                                ((top_index--))
                            fi
                            ;;
                        B) # Down arrow
                            local absolute_index=$((top_index + cursor_pos))
                            local last_index=$((total_items - 1))
                            if [[ $absolute_index -lt $last_index ]]; then
                                local visible_count=$((total_items - top_index))
                                [[ $visible_count -gt $items_per_page ]] && visible_count=$items_per_page
                                if [[ $cursor_pos -lt $((visible_count - 1)) ]]; then
                                    ((cursor_pos++))
                                elif [[ $((top_index + visible_count)) -lt $total_items ]]; then
                                    ((top_index++))
                                fi
                            fi
                            ;;
                    esac
                else
                    # ESC alone
                    restore_terminal
                    return 1
                fi
                ;;
            " ") # Space - toggle current item
                local idx=$((top_index + cursor_pos))
                if [[ ${selected[idx]} == true ]]; then
                    selected[idx]=false
                else
                    selected[idx]=true
                fi
                ;;
            "a" | "A") # Select all
                for ((i = 0; i < total_items; i++)); do
                    selected[i]=true
                done
                ;;
            "i" | "I") # Invert selection
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        selected[i]=false
                    else
                        selected[i]=true
                    fi
                done
                ;;
            "q" | "Q" | $'\x03') # Quit or Ctrl-C
                restore_terminal
                return 1
                ;;
            "" | $'\n' | $'\r') # Enter - confirm
                MOLE_SELECTION_RESULT=""
                for ((i = 0; i < total_items; i++)); do
                    if [[ ${selected[i]} == true ]]; then
                        [[ -n "$MOLE_SELECTION_RESULT" ]] && MOLE_SELECTION_RESULT+=","
                        MOLE_SELECTION_RESULT+="$i"
                    fi
                done
                restore_terminal
                return 0
                ;;
        esac
    done
}

# Show menu for user selection
show_installer_menu() {
    if [[ ${#DISPLAY_NAMES[@]} -eq 0 ]]; then
        return 1
    fi

    echo ""

    MOLE_SELECTION_RESULT=""
    if ! select_installers "${DISPLAY_NAMES[@]}"; then
        return 1
    fi

    return 0
}

# Delete selected installers
delete_selected_installers() {
    # Parse selection indices
    local -a selected_indices=()
    [[ -n "$MOLE_SELECTION_RESULT" ]] && IFS=',' read -ra selected_indices <<< "$MOLE_SELECTION_RESULT"

    if [[ ${#selected_indices[@]} -eq 0 ]]; then
        return 1
    fi

    # Calculate total size for confirmation
    local confirm_size=0
    for idx in "${selected_indices[@]}"; do
        if [[ "$idx" =~ ^[0-9]+$ ]] && [[ $idx -lt ${#INSTALLER_SIZES[@]} ]]; then
            confirm_size=$((confirm_size + ${INSTALLER_SIZES[$idx]:-0}))
        fi
    done
    local confirm_human
    confirm_human=$(bytes_to_human "$confirm_size")

    # Show files to be deleted
    echo -e "${PURPLE_BOLD}Files to be removed:${NC}"
    for idx in "${selected_indices[@]}"; do
        if [[ "$idx" =~ ^[0-9]+$ ]] && [[ $idx -lt ${#INSTALLER_PATHS[@]} ]]; then
            local file_path="${INSTALLER_PATHS[$idx]}"
            local file_size="${INSTALLER_SIZES[$idx]}"
            local size_human
            size_human=$(bytes_to_human "$file_size")
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $(basename "$file_path") ${GRAY}, ${size_human}${NC}"
        fi
    done

    # Confirm deletion
    echo ""
    echo -ne "${PURPLE}${ICON_ARROW}${NC} Delete ${#selected_indices[@]} installers, ${confirm_human}  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "

    IFS= read -r -s -n1 confirm || confirm=""
    case "$confirm" in
        $'\e' | q | Q)
            return 1
            ;;
        "" | $'\n' | $'\r')
            printf "\r\033[K" # Clear prompt line
            echo ""           # Single line break
            ;;
        *)
            return 1
            ;;
    esac

    # Delete each selected installer with spinner
    total_deleted=0
    total_size_freed_kb=0

    if [[ -t 1 ]]; then
        start_inline_spinner "Removing installers..."
    fi

    for idx in "${selected_indices[@]}"; do
        if [[ ! "$idx" =~ ^[0-9]+$ ]] || [[ $idx -ge ${#INSTALLER_PATHS[@]} ]]; then
            continue
        fi

        local file_path="${INSTALLER_PATHS[$idx]}"
        local file_size="${INSTALLER_SIZES[$idx]}"

        # Validate path before deletion
        if ! validate_path_for_deletion "$file_path"; then
            continue
        fi

        # Delete the file
        if safe_remove "$file_path" true; then
            total_size_freed_kb=$((total_size_freed_kb + ((file_size + 1023) / 1024)))
            total_deleted=$((total_deleted + 1))
        fi
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    return 0
}

# Perform the installers cleanup
perform_installers() {
    # Enter alt screen for scanning and selection
    if [[ -t 1 ]]; then
        enter_alt_screen
        IN_ALT_SCREEN=1
        printf "\033[2J\033[H" >&2
    fi

    # Collect installers
    if ! collect_installers; then
        if [[ -t 1 ]]; then
            leave_alt_screen
            IN_ALT_SCREEN=0
        fi
        printf '\n'
        echo -e "${GREEN}${ICON_SUCCESS}${NC} Great! No installer files to clean"
        printf '\n'
        return 2 # Nothing to clean
    fi

    # Show menu
    if ! show_installer_menu; then
        if [[ -t 1 ]]; then
            leave_alt_screen
            IN_ALT_SCREEN=0
        fi
        return 1 # User cancelled
    fi

    # Leave alt screen before deletion (so confirmation and results are on main screen)
    if [[ -t 1 ]]; then
        leave_alt_screen
        IN_ALT_SCREEN=0
    fi

    # Delete selected
    if ! delete_selected_installers; then
        return 1
    fi

    return 0
}

show_summary() {
    local summary_heading="Installers cleaned"
    local -a summary_details=()

    if [[ $total_deleted -gt 0 ]]; then
        local freed_mb
        freed_mb=$(echo "$total_size_freed_kb" | awk '{printf "%.2f", $1/1024}')

        summary_details+=("Removed ${GREEN}$total_deleted${NC} installers, freed ${GREEN}${freed_mb}MB${NC}")
        summary_details+=("Your Mac is cleaner now!")
    else
        summary_details+=("No installers were removed")
    fi

    print_summary_block "$summary_heading" "${summary_details[@]}"
    printf '\n'
}

main() {
    local -a orig_argv=("$@")
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
        emit_installer_json_canceled() {
            local signal_exit="$1"

            if [[ "${canceled_emitted:-0}" -eq 1 ]]; then
                exit "$signal_exit"
            fi
            canceled_emitted=1

            local cancel_epoch
            cancel_epoch=$(date -u +%s 2> /dev/null || echo "$start_epoch")
            local cancel_duration_ms=$(((cancel_epoch - start_epoch) * 1000))

            mole_json_emit_error "installer" "error" "canceled" "Operation canceled" "" "" "" ""
            mole_json_emit_operation_complete "installer" "false" "true" "$signal_exit" "$cancel_duration_ms" "{}" "{}"
            exit "$signal_exit"
        }

        trap 'emit_installer_json_canceled 130' INT
        trap 'emit_installer_json_canceled 143' TERM

        local exit_code=0
        if [[ "$MOLE_JSON_COMMAND_MODE" == "scan" ]]; then
            mole_json_emit_operation_start "installer" "scan" "true" "$0" "${orig_argv[@]}"
            maybe_trigger_installer_json_test_signal
            set +e
            json_scan_installers
            exit_code=$?
            set -e
        else
            mole_json_emit_operation_start "installer" "apply" "false" "$0" "${orig_argv[@]}"
            maybe_trigger_installer_json_test_signal
            local manifest_path="$MOLE_JSON_APPLY_MANIFEST"
            local tmp_manifest=""
            if [[ "$manifest_path" == "-" ]]; then
                tmp_manifest=$(mktemp_file "mole_installer_apply")
                cat > "$tmp_manifest"
                manifest_path="$tmp_manifest"
            fi
            set +e
            json_apply_installers "$manifest_path"
            exit_code=$?
            set -e
            [[ -n "$tmp_manifest" ]] && rm -f "$tmp_manifest" 2> /dev/null || true
        fi
        local end_epoch
        end_epoch=$(date -u +%s 2> /dev/null || echo "$start_epoch")
        local duration_ms=$(((end_epoch - start_epoch) * 1000))

        local success="true"
        [[ "$exit_code" -ne 0 ]] && success="false"
        mole_json_emit_operation_complete "installer" "$success" "false" "$exit_code" "$duration_ms" "{}" "{}"
        exit "$exit_code"
    fi

    hide_cursor
    perform_installers
    local exit_code=$?
    show_cursor

    case $exit_code in
        0)
            show_summary
            ;;
        1)
            printf '\n'
            ;;
        2)
            # Already handled by collect_installers
            ;;
    esac

    return 0
}

# Only run main if not in test mode
if [[ "${MOLE_TEST_MODE:-0}" != "1" ]]; then
    main "$@"
fi
