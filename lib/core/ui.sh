#!/bin/bash
# Mole - UI Components
# Terminal UI utilities: cursor control, keyboard input, spinners, menus

set -euo pipefail

if [[ -n "${MOLE_UI_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_UI_LOADED=1

_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${MOLE_BASE_LOADED:-}" ]] && source "$_MOLE_CORE_DIR/base.sh"

# Cursor control
clear_screen() { printf '\033[2J\033[H'; }
hide_cursor() { [[ -t 1 ]] && printf '\033[?25l' >&2 || true; }
show_cursor() { [[ -t 1 ]] && printf '\033[?25h' >&2 || true; }

# Calculate display width of a string (CJK characters count as 2)
# Args: $1 - string to measure
# Returns: display width
# Note: Works correctly even when LC_ALL=C is set
get_display_width() {
    local str="$1"

    # Check Python availability once and cache the result
    # Use Python for accurate width calculation if available (cached check)
    if [[ -z "${MOLE_PYTHON_AVAILABLE:-}" ]]; then
        if command -v python3 > /dev/null 2>&1; then
            export MOLE_PYTHON_AVAILABLE=1
        else
            export MOLE_PYTHON_AVAILABLE=0
        fi
    fi

    if [[ "${MOLE_PYTHON_AVAILABLE:-0}" == "1" ]]; then
        python3 -c "
import sys
import unicodedata

s = sys.argv[1]
width = 0
for char in s:
    # East Asian Width property
    ea_width = unicodedata.east_asian_width(char)
    if ea_width in ('F', 'W'):  # Fullwidth or Wide
        width += 2
    else:
        width += 1
print(width)
" "$str" 2> /dev/null && return
    fi

    # Fallback: Use wc with UTF-8 locale temporarily
    local saved_lc_all="${LC_ALL:-}"
    local saved_lang="${LANG:-}"

    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8

    local char_count byte_count width
    char_count=$(printf '%s' "$str" | wc -m 2> /dev/null | tr -d ' ')
    byte_count=$(printf '%s' "$str" | wc -c 2> /dev/null | tr -d ' ')

    # Restore locale
    if [[ -n "$saved_lc_all" ]]; then
        export LC_ALL="$saved_lc_all"
    else
        unset LC_ALL
    fi
    if [[ -n "$saved_lang" ]]; then
        export LANG="$saved_lang"
    else
        unset LANG
    fi

    # Estimate: if byte_count > char_count, we have multibyte chars
    # Rough approximation: each multibyte char (CJK) is ~3 bytes and width 2
    # ASCII chars are 1 byte and width 1
    if [[ $byte_count -gt $char_count ]]; then
        local multibyte_chars=$((byte_count - char_count))
        # Assume most multibyte chars are 2 bytes extra (3 bytes total for UTF-8 CJK)
        local cjk_chars=$((multibyte_chars / 2))
        local ascii_chars=$((char_count - cjk_chars))
        width=$((ascii_chars + cjk_chars * 2))
    else
        width=$char_count
    fi

    echo "$width"
}

# Truncate string by display width (handles CJK correctly)
# Args: $1 - string, $2 - max display width
# Returns: truncated string with "..." if needed
truncate_by_display_width() {
    local str="$1"
    local max_width="$2"
    local current_width
    current_width=$(get_display_width "$str")

    if [[ $current_width -le $max_width ]]; then
        echo "$str"
        return
    fi

    # Use Python for accurate truncation if available (use cached check)
    if [[ "${MOLE_PYTHON_AVAILABLE:-0}" == "1" ]]; then
        python3 -c "
import sys
import unicodedata

s = sys.argv[1]
max_w = int(sys.argv[2])
result = ''
width = 0

for char in s:
    ea_width = unicodedata.east_asian_width(char)
    char_width = 2 if ea_width in ('F', 'W') else 1

    if width + char_width + 3 > max_w:  # +3 for '...'
        break

    result += char
    width += char_width

print(result + '...')
" "$str" "$max_width" 2> /dev/null && return
    fi

    # Fallback: Use UTF-8 locale for proper string handling
    local saved_lc_all="${LC_ALL:-}"
    local saved_lang="${LANG:-}"
    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8

    local truncated=""
    local width=0
    local i=0
    local char char_width

    while [[ $i -lt ${#str} ]]; do
        char="${str:$i:1}"
        char_width=$(get_display_width "$char")

        if ((width + char_width + 3 > max_width)); then
            break
        fi

        truncated+="$char"
        ((width += char_width))
        ((i++))
    done

    # Restore locale
    if [[ -n "$saved_lc_all" ]]; then
        export LC_ALL="$saved_lc_all"
    else
        unset LC_ALL
    fi
    if [[ -n "$saved_lang" ]]; then
        export LANG="$saved_lang"
    else
        unset LANG
    fi

    echo "${truncated}..."
}

# Keyboard input - read single keypress
read_key() {
    local key rest read_status
    IFS= read -r -s -n 1 key
    read_status=$?
    [[ $read_status -ne 0 ]] && {
        echo "QUIT"
        return 0
    }

    if [[ "${MOLE_READ_KEY_FORCE_CHAR:-}" == "1" ]]; then
        [[ -z "$key" ]] && {
            echo "ENTER"
            return 0
        }
        case "$key" in
            $'\n' | $'\r') echo "ENTER" ;;
            $'\x7f' | $'\x08') echo "DELETE" ;;
            $'\x1b') echo "QUIT" ;;
            [[:print:]]) echo "CHAR:$key" ;;
            *) echo "OTHER" ;;
        esac
        return 0
    fi

    [[ -z "$key" ]] && {
        echo "ENTER"
        return 0
    }
    case "$key" in
        $'\n' | $'\r') echo "ENTER" ;;
        ' ') echo "SPACE" ;;
        '/') echo "FILTER" ;;
        'q' | 'Q') echo "QUIT" ;;
        'R') echo "RETRY" ;;
        'm' | 'M') echo "MORE" ;;
        'u' | 'U') echo "UPDATE" ;;
        't' | 'T') echo "TOUCHID" ;;
        'j' | 'J') echo "DOWN" ;;
        'k' | 'K') echo "UP" ;;
        'h' | 'H') echo "LEFT" ;;
        'l' | 'L') echo "RIGHT" ;;
        $'\x03') echo "QUIT" ;;
        $'\x7f' | $'\x08') echo "DELETE" ;;
        $'\x1b')
            if IFS= read -r -s -n 1 -t 1 rest 2> /dev/null; then
                if [[ "$rest" == "[" ]]; then
                    if IFS= read -r -s -n 1 -t 1 rest2 2> /dev/null; then
                        case "$rest2" in
                            "A") echo "UP" ;; "B") echo "DOWN" ;;
                            "C") echo "RIGHT" ;; "D") echo "LEFT" ;;
                            "3")
                                IFS= read -r -s -n 1 -t 1 rest3 2> /dev/null
                                [[ "$rest3" == "~" ]] && echo "DELETE" || echo "OTHER"
                                ;;
                            *) echo "OTHER" ;;
                        esac
                    else echo "QUIT"; fi
                elif [[ "$rest" == "O" ]]; then
                    if IFS= read -r -s -n 1 -t 1 rest2 2> /dev/null; then
                        case "$rest2" in
                            "A") echo "UP" ;; "B") echo "DOWN" ;;
                            "C") echo "RIGHT" ;; "D") echo "LEFT" ;;
                            *) echo "OTHER" ;;
                        esac
                    else echo "OTHER"; fi
                else echo "OTHER"; fi
            else echo "QUIT"; fi
            ;;
        [[:print:]]) echo "CHAR:$key" ;;
        *) echo "OTHER" ;;
    esac
}

drain_pending_input() {
    local drained=0
    while IFS= read -r -s -n 1 -t 0.01 _ 2> /dev/null; do
        ((drained++))
        [[ $drained -gt 100 ]] && break
    done
}

# Menu display
show_menu_option() {
    local number="$1"
    local text="$2"
    local selected="$3"

    if [[ "$selected" == "true" ]]; then
        echo -e "${CYAN}${ICON_ARROW} $number. $text${NC}"
    else
        echo "  $number. $text"
    fi
}

# Inline spinner
INLINE_SPINNER_PID=""
start_inline_spinner() {
    stop_inline_spinner 2> /dev/null || true
    local message="$1"

    if [[ -t 1 ]]; then
        (
            trap 'exit 0' TERM INT EXIT
            local chars
            chars="$(mo_spinner_chars)"
            [[ -z "$chars" ]] && chars="|/-\\"
            local i=0
            while true; do
                local c="${chars:$((i % ${#chars})):1}"
                # Output to stderr to avoid interfering with stdout
                printf "\r${MOLE_SPINNER_PREFIX:-}${BLUE}%s${NC} %s" "$c" "$message" >&2 || exit 0
                ((i++))
                sleep 0.1
            done
        ) &
        INLINE_SPINNER_PID=$!
        disown 2> /dev/null || true
    else
        echo -n "  ${BLUE}|${NC} $message" >&2
    fi
}

stop_inline_spinner() {
    if [[ -n "$INLINE_SPINNER_PID" ]]; then
        # Try graceful TERM first, then force KILL if needed
        if kill -0 "$INLINE_SPINNER_PID" 2> /dev/null; then
            kill -TERM "$INLINE_SPINNER_PID" 2> /dev/null || true
            sleep 0.05 2> /dev/null || true
            # Force kill if still running
            if kill -0 "$INLINE_SPINNER_PID" 2> /dev/null; then
                kill -KILL "$INLINE_SPINNER_PID" 2> /dev/null || true
            fi
        fi
        wait "$INLINE_SPINNER_PID" 2> /dev/null || true
        INLINE_SPINNER_PID=""
        # Clear the line - use \033[2K to clear entire line, not just to end
        [[ -t 1 ]] && printf "\r\033[2K" >&2
    fi
}

# Wrapper for running commands with spinner
with_spinner() {
    local msg="$1"
    shift || true
    local timeout="${MOLE_CMD_TIMEOUT:-180}"
    start_inline_spinner "$msg"
    local exit_code=0
    if [[ -n "${MOLE_TIMEOUT_BIN:-}" ]]; then
        "$MOLE_TIMEOUT_BIN" "$timeout" "$@" > /dev/null 2>&1 || exit_code=$?
    else "$@" > /dev/null 2>&1 || exit_code=$?; fi
    stop_inline_spinner "$msg"
    return $exit_code
}

# Get spinner characters
mo_spinner_chars() {
    local chars="${MO_SPINNER_CHARS:-|/-\\}"
    [[ -z "$chars" ]] && chars="|/-\\"
    printf "%s" "$chars"
}

# Format last used time for display
# Args: $1 = last used string (e.g., "3 days ago", "Today", "Never")
# Returns: Compact version (e.g., "3d ago", "Today", "Never")
format_last_used_summary() {
    local value="$1"

    case "$value" in
        "" | "Unknown")
            echo "Unknown"
            return 0
            ;;
        "Never" | "Recent" | "Today" | "Yesterday" | "This year" | "Old")
            echo "$value"
            return 0
            ;;
    esac

    if [[ $value =~ ^([0-9]+)[[:space:]]+days?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}d ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+weeks?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}w ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+months?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}m ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+month\(s\)\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}m ago"
        return 0
    fi
    if [[ $value =~ ^([0-9]+)[[:space:]]+years?\ ago$ ]]; then
        echo "${BASH_REMATCH[1]}y ago"
        return 0
    fi
    echo "$value"
}
