#!/bin/bash

# Howdy Facial Recognition Installer for Fedora
# Configures facial unlock for GNOME (GDM) and shell access
# with fallback to regular password authentication
#
# Usage:
#   sudo ./install-howdy.sh                        # Interactive menu
#   sudo ./install-howdy.sh --install              # Full installation (skip menu)
#   sudo ./install-howdy.sh --diagnose             # Check installation health
#   sudo ./install-howdy.sh --fix                  # Auto-fix common issues
#   sudo ./install-howdy.sh --check-pam            # Inspect PAM configuration
#   sudo ./install-howdy.sh --detect-ir            # Detect IR camera only
#   sudo ./install-howdy.sh --tune-timeout         # Interactively set scan timeout (4–18s)
#   sudo ./install-howdy.sh --set-timeout 8        # Set scan timeout to N seconds, no prompt
#   sudo ./install-howdy.sh --test                 # Test face recognition
#   ./install-howdy.sh --preview                   # Play the scan messages (no camera)
#   sudo ./install-howdy.sh --sounds on            # Scan sounds on (or off)
#   sudo ./install-howdy.sh --setup-keyring        # Auto-unlock the login keyring after face login
#   sudo ./install-howdy.sh --remove-keyring       # Undo --setup-keyring
#   sudo ./install-howdy.sh --uninstall            # Remove howdy completely
#   sudo ./install-howdy.sh --non-interactive ...  # Skip all prompts (also -y)
#
# Environment overrides:
#   HOWDY_REF=master   sudo ./install-howdy.sh --install   # Track upstream HEAD
#   FORCE_DETECT=1     sudo ./install-howdy.sh --install   # Ignore device cache

set -euo pipefail

# ─── Colors & Logging ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}═══ $1 ═══${NC}\n"; }

# ─── Pinned upstream versions ────────────────────────────────────────
HOWDY_REPO="${HOWDY_REPO:-https://github.com/boltgolt/howdy.git}"
HOWDY_REF="${HOWDY_REF:-v2.6.1}"
HOWDY_INSTALL_DIR="/usr/lib64/security/howdy"
SCRIPT_VERSION="1.3.0"

# Accepted scan timeout range (seconds); 12 is the default
TIMEOUT_MIN=4
TIMEOUT_MAX=18
TIMEOUT_DEFAULT=12

# `stdout` flag relays the wrapper's stdout to the calling application
# (sudo/GDM/polkit) as PAM_TEXT_INFO messages, so the user sees the
# face-scan result inline. `quiet` suppresses pam_exec's own syslog noise.
PAM_LINE="auth        sufficient    pam_exec.so quiet stdout ${HOWDY_INSTALL_DIR}/howdy-auth"
HOWDY_PAM_RE="pam_exec.*howdy-auth"

# GDM 50+ switchable authentication: gdm-switchable-auth includes the
# authselect-generated switchable-auth stack
GDM_SWITCHABLE_PAM=/etc/pam.d/gdm-switchable-auth
SWITCHABLE_STACK_PAM=/etc/pam.d/switchable-auth

# Scan sounds (--sounds on|off), read by howdy-auth
FEEDBACK_CONF=/etc/howdy/feedback.conf
SOUND_DIR=/usr/share/sounds/freedesktop/stereo

# Keyring auto-unlock (--setup-keyring)
KEYRING_HELPER=/usr/libexec/howdy-keyring
KEYRING_UNIT=howdy-keyring-unlock.service
KEYRING_UNIT_FILE="/etc/systemd/user/${KEYRING_UNIT}"
KEYRING_CRED_NAME=howdy-keyring
KEYRING_CRED_REL=.local/share/howdy/keyring.cred

# ─── Global state ────────────────────────────────────────────────────
NEEDS_GDM_RESTART=false
NON_INTERACTIVE=0
DM_TYPE="none"
IR_DEVICE=""
IR_FORMAT=""
# Set by install_howdy when a previous config.ini was carried over
HOWDY_CONFIG_RESTORED=false

# ─── Root Check ──────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root. Use: sudo $0"
    fi
}

# ─── OS + Display Manager Version Gate ───────────────────────────────
check_supported_system() {
    if [[ ! -r /etc/os-release ]]; then
        error "Cannot read /etc/os-release — unsupported system"
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "$ID" != "fedora" ]]; then
        error "This script supports Fedora only. Detected: ${ID:-unknown} ${VERSION_ID:-}"
    fi

    if [[ "${VERSION_ID:-0}" -lt 40 ]]; then
        error "Fedora ${VERSION_ID} is not supported. Minimum: Fedora 40."
    fi

    info "OS: Fedora ${VERSION_ID} (${VARIANT_ID:-?})"

    # Display manager detection
    if systemctl is-active --quiet gdm; then
        DM_TYPE="gdm"
    elif systemctl is-active --quiet sddm; then
        DM_TYPE="sddm"
    elif systemctl is-active --quiet lightdm; then
        DM_TYPE="lightdm"
    fi

    if [[ "$DM_TYPE" == "gdm" ]]; then
        info "Display manager: gdm"
    elif [[ "$DM_TYPE" == "none" ]]; then
        warn "No active display manager detected. GDM-specific steps will be skipped."
    else
        warn "Display manager is $DM_TYPE, not GDM. This script targets GDM."
        if [[ "${NON_INTERACTIVE:-0}" != "1" ]]; then
            read -rp "  Continue anyway? (y/N): " REPLY
            [[ $REPLY =~ ^[Yy]$ ]] || exit 0
        fi
    fi
}

# ─── IR Camera Detection ─────────────────────────────────────────────
# Sets globals: IR_DEVICE, IR_FORMAT
# Caches result in /etc/howdy/.detected-device (bypass with FORCE_DETECT=1)
detect_ir_camera() {
    header "IR Camera Detection"

    if ! command -v v4l2-ctl &>/dev/null; then
        error "v4l-utils not installed. Run: sudo dnf install v4l-utils"
    fi

    local ir_candidates=()
    local all_capture=()

    for dev in /dev/video*; do
        [[ -e "$dev" ]] || continue

        local dev_info
        dev_info=$(v4l2-ctl --device="$dev" --info 2>/dev/null || true)

        # Skip metadata-only devices
        if echo "$dev_info" | grep "Device Caps" | grep -q "Metadata"; then
            continue
        fi
        # Must support video capture
        if ! echo "$dev_info" | grep -q "Video Capture"; then
            continue
        fi

        local card_label
        card_label=$(echo "$dev_info" | grep 'Card type' | sed 's/.*: //')

        local formats
        formats=$(v4l2-ctl --device="$dev" --list-formats-ext 2>/dev/null || true)

        local has_ir_fmt=false
        local has_rgb_fmt=false

        # IR cameras output grayscale / bayer formats
        if echo "$formats" | grep -qiE "GREY|GRAY|Y8|Y10|Y12|Y16|L8|SRGGB|SGRBG|SBGGR|SGBRG"; then
            has_ir_fmt=true
        fi
        # RGB cameras output color / compressed formats
        if echo "$formats" | grep -qiE "MJPG|MJPEG|YUYV|NV12|H264|RGB|BGR"; then
            has_rgb_fmt=true
        fi

        all_capture+=("$dev")

        if $has_ir_fmt && ! $has_rgb_fmt; then
            ir_candidates+=("$dev")
            echo -e "  ${GREEN}★ $dev: $card_label — IR camera (grayscale only)${NC}"
        elif $has_ir_fmt && $has_rgb_fmt; then
            ir_candidates+=("$dev")
            echo -e "  ${YELLOW}◆ $dev: $card_label — possible IR (mixed formats)${NC}"
        else
            echo -e "  ○ $dev: $card_label — regular RGB webcam"
        fi
    done
    echo ""

    IR_DEVICE=""
    IR_FORMAT=""

    if [[ ${#ir_candidates[@]} -eq 1 ]]; then
        IR_DEVICE="${ir_candidates[0]}"
        success "Auto-detected IR camera at $IR_DEVICE"
    elif [[ ${#ir_candidates[@]} -gt 1 ]]; then
        info "Multiple IR candidates found. Pick one:"
        echo ""
        local i=1
        for dev in "${ir_candidates[@]}"; do
            local card_info
            card_info=$(v4l2-ctl --device="$dev" --info 2>/dev/null | grep 'Card type' | sed 's/.*: //')
            local fmts
            fmts=$(v4l2-ctl --device="$dev" --list-formats 2>/dev/null \
                   | grep -E "^\s+\[[0-9]+\]" | sed -E "s/.*'(\S+)'.*/\1/" | paste -sd,)
            echo "  $i) $dev — $card_info  [${fmts:-unknown}]"
            ((i++))
        done
        echo ""
        echo "  Tip: Test each with: ffplay /dev/videoX   (IR shows grayscale; no visible LEDs)"
        echo ""
        if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
            IR_DEVICE="${ir_candidates[0]}"
            info "Non-interactive mode: defaulting to $IR_DEVICE"
        else
            local choice
            read -rp "  Choose [1-${#ir_candidates[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ir_candidates[@]} )); then
                IR_DEVICE="${ir_candidates[$((choice-1))]}"
                success "Selected $IR_DEVICE"
            else
                error "Invalid choice: $choice"
            fi
        fi
    fi

    if [[ -z "$IR_DEVICE" ]]; then
        warn "Could not auto-detect IR camera by pixel format."
        echo ""
        echo "  Available capture devices: ${all_capture[*]}"
        echo ""
        echo "  Tip: On ASUS Zenbooks the IR camera is often the higher-numbered"
        echo "       device. Test with: ffplay /dev/videoX (IR shows grayscale)."
        echo ""
        if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
            error "Cannot detect IR camera in non-interactive mode — plug in or specify the device manually"
        fi
        read -rp "  Enter the IR camera device path: " IR_DEVICE
        if [[ ! -e "$IR_DEVICE" ]]; then
            error "Device $IR_DEVICE does not exist!"
        fi
    fi

    # Determine the best pixel format for the selected device
    local sel_formats
    sel_formats=$(v4l2-ctl --device="$IR_DEVICE" --list-formats-ext 2>/dev/null || true)
    if echo "$sel_formats" | grep -qiE "YUYV"; then
        IR_FORMAT="YUYV"
    elif echo "$sel_formats" | grep -qiE "MJPG|MJPEG"; then
        IR_FORMAT="MJPG"
    elif echo "$sel_formats" | grep -qiE "GREY|GRAY"; then
        IR_FORMAT="GREY"
    else
        IR_FORMAT="YUYV"
    fi

    success "Selected device: $IR_DEVICE  format: $IR_FORMAT"

    # Cache result so re-runs don't re-prompt
    mkdir -p /etc/howdy
    cat > /etc/howdy/.detected-device <<EOF
IR_DEVICE=$IR_DEVICE
IR_FORMAT=$IR_FORMAT
DETECTED_AT=$(date -Iseconds)
EOF
}

# ─── Install Dependencies ─────────────────────────────────────────────
install_dependencies() {
    header "Installing Dependencies"

    dnf install -y \
        python3 \
        python3-pip \
        python3-devel \
        python3-opencv \
        opencv \
        v4l-utils \
        git \
        bzip2 \
        polkit-devel \
        policycoreutils-python-utils \
        audit 2>&1 | tail -5

    # Install dlib via pip (Fedora doesn't ship a compatible python3-dlib RPM)
    info "Installing dlib via pip..."
    pip3 install dlib --break-system-packages 2>&1 | tail -3 || pip3 install dlib 2>&1 | tail -3

    # ffmpeg-python is the Python binding used by howdy's ffmpeg recorder
    info "Installing ffmpeg-python via pip..."
    pip3 install ffmpeg-python --break-system-packages 2>&1 | tail -3 || pip3 install ffmpeg-python 2>&1 | tail -3

    success "Dependencies installed"
}

# ─── Ensure dlib is importable system-wide ───────────────────────────
fix_dlib_symlinks() {
    header "Ensuring dlib is accessible system-wide"

    # Step 1: Find where pip installed dlib
    local pip_site=""
    pip_site=$(pip3 show dlib 2>/dev/null | grep "^Location:" | sed 's/Location: //' || true)

    # Fallback: search common paths
    if [[ -z "$pip_site" ]] || [[ ! -d "$pip_site/dlib" ]]; then
        local py_ver
        py_ver=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        for candidate in \
            "/usr/local/lib64/python${py_ver}/site-packages" \
            "/usr/local/lib/python${py_ver}/site-packages" \
            "/usr/local/lib/python${py_ver}/dist-packages"; do
            if [[ -d "$candidate/dlib" ]]; then
                pip_site="$candidate"
                break
            fi
        done
    fi

    if [[ -z "$pip_site" ]] || [[ ! -d "$pip_site/dlib" ]]; then
        fail "dlib not found via pip or in common locations"
        info "Installing dlib via pip..."
        pip3 install dlib --break-system-packages 2>&1 | tail -3 || pip3 install dlib 2>&1 | tail -3
        pip_site=$(pip3 show dlib 2>/dev/null | grep "^Location:" | sed 's/Location: //' || true)
        if [[ -z "$pip_site" ]]; then
            error "Failed to install dlib."
        fi
    fi

    info "dlib installed at: $pip_site"

    # Step 2: Find the pybind .so file
    local pybind_so=""
    pybind_so=$(ls "$pip_site"/_dlib_pybind11*.so 2>/dev/null | head -1 || true)
    if [[ -z "$pybind_so" ]]; then
        pybind_so=$(find "$pip_site" -maxdepth 2 -name '_dlib_pybind11*' -type f 2>/dev/null | head -1 || true)
    fi
    if [[ -z "$pybind_so" ]]; then
        fail "_dlib_pybind11*.so not found in $pip_site"
        echo "  Contents of $pip_site:"
        ls -la "$pip_site" | grep -i dlib | sed 's/^/    /'
        echo ""
        echo "  If dlib was installed via pip, try reinstalling:"
        echo "    pip3 install --force-reinstall dlib --break-system-packages"
        return 1
    fi
    local pybind_name
    pybind_name=$(basename "$pybind_so")

    # Step 3: Symlink into ALL system site-packages directories
    # PAM modules may resolve Python paths differently than a regular shell,
    # so we ensure dlib is reachable from every site-packages dir.
    local site_dirs
    site_dirs=$(python3 -c "import site; [print(p) for p in site.getsitepackages()]" 2>/dev/null)

    while IFS= read -r sys_site; do
        [[ -d "$sys_site" ]] || continue
        [[ "$sys_site" == "$pip_site" ]] && continue

        local changed=false

        if [[ ! -e "$sys_site/dlib" ]]; then
            ln -sf "$pip_site/dlib" "$sys_site/dlib"
            changed=true
        fi

        if [[ ! -e "$sys_site/$pybind_name" ]]; then
            ln -sf "$pybind_so" "$sys_site/"
            changed=true
        fi

        local dist_info
        dist_info=$(find "$pip_site" -maxdepth 1 -type d -name 'dlib*.dist-info' 2>/dev/null | head -1)
        if [[ -n "$dist_info" ]] && [[ ! -e "$sys_site/$(basename "$dist_info")" ]]; then
            ln -sf "$dist_info" "$sys_site/"
        fi

        if $changed; then
            success "Symlinked dlib into $sys_site"
        fi
    done <<< "$site_dirs"

    if [[ ! -e "$pip_site/$pybind_name" ]] && [[ -f "$pybind_so" ]]; then
        ln -sf "$pybind_so" "$pip_site/"
    fi

    # Verify
    if python3 -c "import dlib" 2>/dev/null; then
        success "dlib imports correctly"
    else
        fail "dlib import still failing — check manually"
        echo "  pip_site:   $pip_site"
        echo "  pybind_so:  $pybind_so"
        echo "  site_dirs:  $(python3 -c 'import site; print(site.getsitepackages())' 2>/dev/null)"
        return 1
    fi

    if id gdm &>/dev/null; then
        if sudo -u gdm python3 -c "import dlib" 2>/dev/null; then
            success "dlib imports correctly as gdm user"
        else
            warn "gdm user cannot import dlib (GDM face unlock may not work)"
        fi
    fi
}

# ─── howdy-auth PAM wrapper ──────────────────────────────────────────
# Called by pam_exec.so. Shows a Windows Hello-style "Looking for you…" while
# compare.py scans, then a greeting or the reason face unlock failed, and logs
# the details to the journal. How it's shown depends on the caller:
#   sudo/su in a terminal  animated face drawn straight on the terminal
#   polkit dialog          light animation (the dialog swaps in each stdout line)
#   GDM and anything else  one stdout line per state (GDM holds every message
#                          for ≥2 s, so frames would pile up)
# Exit codes are normalised to 0 (success) or 1 (failure) so pam_exec.so
# always gets a clean result regardless of compare.py's internal codes
# (10=no model, 11=timeout, 13=too dark, etc.).
#
# compare.py ignores the [core] disabled / ignore_ssh / ignore_closed_lid
# options — upstream checks them in pam.py, which pam_exec never runs — so
# the wrapper enforces them itself.
#
# `howdy-auth --demo success|fail|dark|noface|error` plays the messages with
# a simulated scan and no camera (used by --preview).
write_auth_wrapper() {
    cat > "$HOWDY_INSTALL_DIR/howdy-auth" << 'EOF'
#!/bin/bash
# Generated by install-howdy.sh — regenerate with: sudo ./install-howdy.sh --fix
#
#   howdy-auth                                  (from pam_exec.so)
#   howdy-auth --demo OUTCOME [SERVICE]         preview; no camera, always exits 1
#     OUTCOME: success | fail | dark | noface | error

DEMO=""
if [[ "${1:-}" == "--demo" ]]; then
    DEMO="${2:-success}"
    PAM_USER="${PAM_USER:-$(id -un)}"
    PAM_SERVICE="${3:-sudo}"
fi
[[ -z "${PAM_USER}" ]] && exit 1

HOWDY_DIR=/usr/lib64/security/howdy
CONFIG="$HOWDY_DIR/config.ini"

_log() {
    [[ -n "$DEMO" ]] && return 0
    command -v logger &>/dev/null && logger -t howdy "$1" 2>/dev/null
}

_cfg_true() {
    grep -qiE "^[[:space:]]*$1[[:space:]]*=[[:space:]]*true" "$CONFIG" 2>/dev/null
}

# Sound settings written by install-howdy.sh --sounds
FEEDBACK_CONF=/etc/howdy/feedback.conf
_feedback() {
    sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$FEEDBACK_CONF" 2>/dev/null | tail -1
}

# Play a short sound (scan | success | fail) for whoever is at the screen:
# the active session on seat0, which at the login screen is the greeter.
# Runs detached with every fd closed so it never holds up pam_exec, and uses
# setpriv rather than runuser, which would open a PAM session of its own.
play_sound() {
    [[ "$(_feedback sounds)" == on ]] || return 0
    local file sid uid gid
    file=$(_feedback "${1}_sound")
    [[ -r "$file" ]] && command -v pw-play &>/dev/null || return 0
    sid=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null)
    [[ -n "$sid" ]] || return 0
    uid=$(loginctl show-session "$sid" -p User --value 2>/dev/null)
    [[ -n "$uid" && -S "/run/user/$uid/pipewire-0" ]] || return 0
    if [[ "$(id -u)" == 0 ]]; then
        gid=$(getent passwd "$uid" | cut -d: -f4)
        setpriv --reuid="$uid" --regid="${gid:-$uid}" --clear-groups \
            env XDG_RUNTIME_DIR="/run/user/$uid" pw-play "$file" \
            < /dev/null > /dev/null 2>&1 8>&- 9>&- &
    elif [[ "$(id -u)" == "$uid" ]]; then
        XDG_RUNTIME_DIR="/run/user/$uid" pw-play "$file" \
            < /dev/null > /dev/null 2>&1 8>&- 9>&- &
    fi
    return 0
}

if [[ -z "$DEMO" ]]; then
    if _cfg_true disabled; then
        _log "Howdy: disabled in config — skipping face scan for ${PAM_USER}"
        exit 1
    fi

    if _cfg_true ignore_closed_lid && grep -qs closed /proc/acpi/button/lid/*/state; then
        _log "Howdy: lid closed — skipping face scan for ${PAM_USER}"
        exit 1
    fi

    if _cfg_true ignore_ssh; then
        remote=false
        [[ -n "${PAM_RHOST:-}" ]] && remote=true
        # pam_exec passes only the PAM environment, so look at the calling
        # process (sudo/su) directly, and at the logind session we belong to
        if tr '\0' '\n' < "/proc/$PPID/environ" 2>/dev/null \
                | grep -qE '^(SSH_CONNECTION|SSH_CLIENT|SSHD_OPTS)='; then
            remote=true
        fi
        sid=$(cat /proc/self/sessionid 2>/dev/null)
        if [[ -n "$sid" && "$sid" != 4294967295 ]] && \
           [[ "$(loginctl show-session "$sid" -p Remote --value 2>/dev/null)" == yes ]]; then
            remote=true
        fi
        if $remote; then
            _log "Howdy: remote session — skipping face scan for ${PAM_USER}"
            exit 1
        fi
    fi

    # One scan at a time: a concurrent auth goes straight to the password prompt
    # instead of fighting over the camera. Locks this (world-readable) script so
    # it also works when pam_exec runs us as the calling user (polkit).
    exec 9<"$0"
    if ! flock -n 9; then
        _log "Howdy: another face scan is in progress — skipping for ${PAM_USER}"
        exit 1
    fi
fi

# ─── Presentation ────────────────────────────────────────────────────
# Greet by first name from the account's full name, like Windows Hello
NAME=$(getent passwd "$PAM_USER" | cut -d: -f5 | cut -d, -f1)
NAME="${NAME%% *}"
NAME="${NAME:-$PAM_USER}"

SCAN_TEXT="Looking for you"
DOTS=("   " ".  " ".. " "...")

MODE="lines"
case "${PAM_SERVICE:-}" in
    gdm-*)
        ;;
    polkit-1|polkit)
        # Only GNOME Shell's dialog replaces the message in place; a text agent
        # (pkttyagent) would print every frame on its own line
        helper_parent=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')
        [[ -n "$helper_parent" && "$(ps -o comm= -p "$helper_parent" 2>/dev/null)" == gnome-shell ]] && \
            MODE="polkit"
        ;;
    *)
        if (: > /dev/tty) 2>/dev/null; then
            exec 8> /dev/tty
            MODE="tty"
        fi
        ;;
esac

OUT=$(mktemp 2>/dev/null) || OUT=/dev/null
PID=""
cleanup() {
    if [[ -n "$PID" ]]; then
        pkill -P "$PID" 2>/dev/null
        kill "$PID" 2>/dev/null
    fi
    [[ "$OUT" != /dev/null ]] && rm -f "$OUT"
    [[ "$MODE" == tty ]] && printf '\033[?25h' >&8
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# One terminal line, redrawn in place: face, then styled text
tty_draw() {
    printf '\r\033[2K  %s  %b' "$1" "$2" >&8
}

scan_frames() {
    local tick=0 face
    case "$MODE" in
        tty)
            printf '\033[?25l' >&8
            while kill -0 "$PID" 2>/dev/null; do
                face="👀"
                (( tick % 16 == 15 )) && face="😑"      # blink
                tty_draw "$face" "\033[2m${SCAN_TEXT}${DOTS[(tick / 3) % 4]}\033[0m"
                sleep 0.12
                tick=$((tick + 1))
            done
            ;;
        polkit)
            while kill -0 "$PID" 2>/dev/null; do
                face="👀"
                (( tick % 6 == 5 )) && face="😑"
                echo "${face} ${SCAN_TEXT}${DOTS[tick % 4]%% *}"
                sleep 0.5
                tick=$((tick + 1))
            done
            ;;
        *)
            echo "👀 ${SCAN_TEXT}…"
            ;;
    esac
}

# $1 = face, $2 = message, $3 = ANSI style for the terminal
show_result() {
    if [[ "$MODE" == tty ]]; then
        tty_draw "$1" "${3}${2}\033[0m"
        printf '\n' >&8
    else
        echo "$1 $2"
    fi
}

# ─── Scan ────────────────────────────────────────────────────────────
START=$(date +%s%N)
if [[ -n "$DEMO" ]]; then
    case "$DEMO" in
        success) demo_rc=0 ;; fail) demo_rc=11 ;; dark) demo_rc=13 ;;
        noface) demo_rc=10 ;; *) demo_rc=1 ;;
    esac
    { sleep 2.5; echo 'Winning model: 0 ("demo")'; exit "$demo_rc"; } > "$OUT" 2>&1 &
else
    /usr/bin/python3 "$HOWDY_DIR/compare.py" "${PAM_USER}" > "$OUT" 2>&1 &
fi
PID=$!

play_sound scan
scan_frames
wait "$PID"
rc=$?
PID=""
ms=$(( ($(date +%s%N) - START) / 1000000 ))
secs="$((ms / 1000)).$(( (ms % 1000) / 100 ))s"

if [ "$rc" -eq 0 ]; then
    # compare.py prints 'Winning model: N ("label")' when end_report=true
    label=$(grep -oE 'Winning model: [0-9]+ \("[^"]+"\)' "$OUT" \
        | grep -oE '"[^"]+"' | tr -d '"' | head -1)
    if [[ "$MODE" == tty ]]; then
        # The Windows Hello wink
        tty_draw "🙂" "\033[1;32mWelcome back, ${NAME}!\033[0m"; sleep 0.12
        tty_draw "😉" "\033[1;32mWelcome back, ${NAME}!\033[0m"; sleep 0.35
    fi
    play_sound success
    greeting="Welcome back, ${NAME}!"
    # The login and lock screens also show which face model matched, and how
    # fast, on a second line. It has to stay one message: GDM holds every
    # message for at least 2 s before finishing the unlock. U+2028 (LINE
    # SEPARATOR) passes through pam_exec's line splitting and Pango renders
    # it as a line break.
    if [[ "${PAM_SERVICE:-}" == gdm-* && -n "$label" ]]; then
        # shellcheck disable=SC1111  # typographic quotes are intended
        greeting+=$'\xe2\x80\xa8'"✅ Matched “${label}” in ${secs}"
    fi
    show_result "😊" "$greeting" "\033[1;32m"
    _log "Howdy: Recognized '${label:-?}' for ${PAM_USER} in ${secs} — access granted"
    [[ -n "$DEMO" ]] && exit 1
    exit 0
fi

case "$rc" in
    10) face="🙈"; msg="No face enrolled for ${PAM_USER} — enter your password"; reason="no face model enrolled" ;;
    11) face="😕"; msg="Couldn't recognize you — enter your password"; reason="no match before timeout" ;;
    13) face="🌑"; msg="Too dark to see you — enter your password"; reason="all frames too dark" ;;
    *)  face="⚠️"; msg="Face unlock isn't working — enter your password"; reason="compare.py error" ;;
esac
play_sound fail
if [[ "$MODE" == tty ]]; then
    tty_draw "😐" "\033[33m${msg}\033[0m"
    sleep 0.15
fi
show_result "$face" "$msg" "\033[33m"
details=""
if [[ "$rc" != 10 && "$rc" != 11 && "$rc" != 13 && "$OUT" != /dev/null ]]; then
    details=" — compare.py: $(tail -n 3 "$OUT" | tr '\n' ' ')"
fi
_log "Howdy: Face not recognized for ${PAM_USER} (${reason}, exit ${rc}, ${secs}) — falling back to password${details}"
exit 1
EOF
    chmod 0755 "$HOWDY_INSTALL_DIR/howdy-auth"
}
# ─── Install Howdy from Source ───────────────────────────────────────
install_howdy() {
    header "Installing Howdy from Source"

    local howdy_dir keep_dir=""
    howdy_dir=$(mktemp -d -t howdy-install-XXXXXX)
    # Self-clearing: a RETURN trap outlives the function that set it and would
    # otherwise fire again (with these locals unbound) when the caller returns
    trap 'rm -rf "$howdy_dir"; [[ -z "$keep_dir" ]] || rmdir "$keep_dir" 2>/dev/null || true; trap - RETURN' RETURN

    info "Cloning howdy repository (ref: $HOWDY_REF)..."
    git clone "$HOWDY_REPO" "$howdy_dir" 2>&1 | tail -3
    git -C "$howdy_dir" checkout "$HOWDY_REF" 2>&1 | tail -3
    info "Installing from commit $(git -C "$howdy_dir" rev-parse --short HEAD)"

    # Carry user data over a reinstall: enrolled face models, the tuned config
    # and its backup, snapshots, and the ~27 MB of dlib model data. Stashed on
    # the same filesystem so the moves are renames and survive an interruption.
    local keep_items=(models snapshots dlib-data config.ini config.ini.pre-install)
    if [[ -d "$HOWDY_INSTALL_DIR" ]]; then
        keep_dir=$(mktemp -d "$(dirname "$HOWDY_INSTALL_DIR")/.howdy-keep-XXXXXX")
        local item
        for item in "${keep_items[@]}"; do
            [[ -e "$HOWDY_INSTALL_DIR/$item" ]] && mv "$HOWDY_INSTALL_DIR/$item" "$keep_dir/"
        done
    fi

    # Install Python files
    rm -rf "$HOWDY_INSTALL_DIR"
    mkdir -p "$HOWDY_INSTALL_DIR"
    cp -r "$howdy_dir/src/." "$HOWDY_INSTALL_DIR/"

    if [[ -n "$keep_dir" ]]; then
        [[ -e "$keep_dir/config.ini" ]] && HOWDY_CONFIG_RESTORED=true
        for item in "${keep_items[@]}"; do
            [[ -e "$keep_dir/$item" ]] || continue
            rm -rf "${HOWDY_INSTALL_DIR:?}/$item"
            mv "$keep_dir/$item" "$HOWDY_INSTALL_DIR/"
        done
        success "Kept existing face models and configuration"
    fi

    # Fix shebangs to python3
    find "$HOWDY_INSTALL_DIR" -name "*.py" -exec \
        sed -i '1s|^#!/usr/bin/env python$|#!/usr/bin/env python3|;1s|^#!/usr/bin/python$|#!/usr/bin/python3|' {} \;
    chmod +x "$HOWDY_INSTALL_DIR/cli.py"

    # Patch ffmpeg_reader.py (v2.6.1 ships with three bugs):
    #  1. probe() regex path assigns (height, width) but format string is "WxH" — swap to (width, height)
    #  2. record() reshape uses [-1, width, height, 3] — should be [-1, height, width, 3]
    #  3. read() compares a numpy array to () with ==, which raises ValueError — use isinstance()
    local ffmpeg_reader="$HOWDY_INSTALL_DIR/recorders/ffmpeg_reader.py"
    sed -i \
        's/(height, width) = \[x\.strip() for x in probe\[0\]\.split("x")\]/(width, height) = [x.strip() for x in probe[0].split("x")]/' \
        "$ffmpeg_reader"
    sed -i \
        's/\.reshape(\[-1, self\.width, self\.height, 3\])/.reshape([-1, self.height, self.width, 3])/' \
        "$ffmpeg_reader"
    sed -i \
        's/if self\.video == ():/if isinstance(self.video, tuple):/' \
        "$ffmpeg_reader"
    # ffmpeg_reader returns 0 for success; video_capture checks "if not ret" so 0 always fails — use True
    sed -i \
        's/return 0, self\.video/return True, self.video/g' \
        "$ffmpeg_reader"
    # ffmpeg.probe() fallback returns height/width as int, but the isdigit()
    # checks on lines 69-71 assume strings — wrap with str() to handle both
    sed -i \
        's/if height\.isdigit()/if str(height).isdigit()/' \
        "$ffmpeg_reader"
    sed -i \
        's/if width\.isdigit()/if str(width).isdigit()/' \
        "$ffmpeg_reader"
    info "ffmpeg_reader.py patched (6 upstream bugs fixed)"

    write_auth_wrapper

    # howdy command
    ln -sf "$HOWDY_INSTALL_DIR/cli.py" /usr/bin/howdy

    # Polkit policy
    mkdir -p /usr/share/polkit-1/actions
    cp "$howdy_dir/fedora/com.github.boltgolt.howdy.policy" /usr/share/polkit-1/actions/

    # Bash completion
    mkdir -p /usr/share/bash-completion/completions
    cp "$howdy_dir/autocomplete/howdy" /usr/share/bash-completion/completions/

    if command -v howdy &>/dev/null; then
        success "howdy command available at $(command -v howdy)"
    else
        warn "howdy command not found in PATH"
    fi

    mkdir -p /etc/howdy
    git -C "$howdy_dir" rev-parse HEAD > /etc/howdy/.installed-ref
    echo "$HOWDY_REF" > /etc/howdy/.installed-tag

    success "Howdy installed from source"

    install_dlib_data
}

# ─── Download dlib Face Recognition Data ─────────────────────────────
install_dlib_data() {
    header "Downloading Face Recognition Models"

    local data_dir="$HOWDY_INSTALL_DIR/dlib-data"
    mkdir -p "$data_dir"

    if [[ -f "$data_dir/dlib_face_recognition_resnet_model_v1.dat" ]] && \
       [[ -f "$data_dir/mmod_human_face_detector.dat" ]] && \
       [[ -f "$data_dir/shape_predictor_5_face_landmarks.dat" ]]; then
        success "dlib face recognition models already downloaded"
        return
    fi

    info "Downloading face recognition models..."

    local base_url="https://github.com/davisking/dlib-models/raw/master"
    local files=(
        "dlib_face_recognition_resnet_model_v1.dat.bz2"
        "mmod_human_face_detector.dat.bz2"
        "shape_predictor_5_face_landmarks.dat.bz2"
    )

    for file in "${files[@]}"; do
        local dat_file="${file%.bz2}"
        if [[ ! -f "$data_dir/$dat_file" ]]; then
            info "Downloading $file..."
            curl -L -o "$data_dir/$file" "$base_url/$file" 2>&1 | tail -2
            bunzip2 -f "$data_dir/$file"
        fi
    done

    success "Face recognition models downloaded to $data_dir"
}

# ─── Configure Howdy ─────────────────────────────────────────────────
configure_howdy() {
    local ir_device="$1"
    local ir_format="${2:-YUYV}"
    local config="$HOWDY_INSTALL_DIR/config.ini"

    header "Configuring Howdy"

    if [[ ! -f "$config" ]]; then
        # Fallback: write a minimal v2.6.1-compatible config
        cat > "$config" << EOF
[core]
detection_notice = false
no_confirmation = true
suppress_unknown = false
ignore_ssh = true
ignore_closed_lid = true
disabled = false
use_cnn = false

[video]
certainty = 3.5
timeout = 12
device_path = none
max_height = 320
frame_width = -1
frame_height = -1
dark_threshold = 50
recording_plugin = ffmpeg
device_format = v4l2
force_mjpeg = false
exposure = -1

[snapshots]
capture_failed = false
capture_successful = false

[debug]
end_report = true
EOF
    fi

    if [[ -f "${config}.pre-install" ]]; then
        true  # backup already exists
    else
        cp "$config" "${config}.pre-install"
    fi

    # Apply required overrides regardless of which config was copied from source.
    # The v2.6.1 source ships recording_plugin=opencv and timeout=4, both of
    # which break authentication in PAM context with MJPG cameras.
    sed -i "s|^device_path.*|device_path = $ir_device|" "$config"
    sed -i "s/^recording_plugin.*/recording_plugin = ffmpeg/" "$config"
    # Keep a timeout the user tuned before a reinstall; a fresh upstream config needs the override
    if [[ "$HOWDY_CONFIG_RESTORED" != "true" ]]; then
        sed -i "s/^timeout.*/timeout = ${TIMEOUT_DEFAULT}/" "$config"
    fi
    # end_report=true makes compare.py print the winning model label on success,
    # which howdy-auth captures and re-emits as the "recognized as" message.
    sed -i "s/^end_report.*/end_report = true/" "$config"
    sed -i "s/^no_confirmation.*/no_confirmation = true/" "$config"

    success "Howdy config: device=$ir_device format=$ir_format (ffmpeg plugin)"
}

# ─── PAM file editing ────────────────────────────────────────────────
# Print what a PAM file should look like: any existing howdy line is dropped
# and the current PAM_LINE is inserted right after pam_rootok (so root never
# waits on a face scan, e.g. in su) or otherwise before the first auth line.
# Rendering from scratch makes every edit idempotent and migrates old lines
# (missing `stdout`, wrong position) in the same step.
pam_render() {
    awk -v line="$PAM_LINE" -v re="$HOWDY_PAM_RE" '
        $0 ~ re { next }
        { l[++n] = $0 }
        /^auth/ && !first { first = n }
        /^auth.*pam_rootok\.so/ { rootok = n }
        END {
            at = rootok ? rootok + 1 : (first ? first : 1)
            for (i = 1; i <= n; i++) { if (i == at) print line; print l[i] }
            if (at > n) print line
        }' "$1"
}

# True when the file exists and differs from its rendered form
pam_needs_update() {
    [[ -f "$1" ]] && ! pam_render "$1" | cmp -s - "$1"
}

# Timestamped backup on every change (forensic trail), plus the permanent
# backup the uninstaller restores from (only if not yet present)
_pam_backup() {
    cp -a "$1" "${1}.howdy-backup-$(date +%Y%m%d-%H%M%S)"
    [[ -f "${1}.howdy-backup" ]] || cp -a "$1" "${1}.howdy-backup"
}

# Stage new content in a sibling tempfile (same FS, so the mv is atomic)
_pam_commit() {
    local pam_file="$1" tmpfile="$2"
    chmod --reference="$pam_file" "$tmpfile" 2>/dev/null || chmod 0644 "$tmpfile"
    _pam_backup "$pam_file"
    mv "$tmpfile" "$pam_file"
    [[ "$pam_file" =~ gdm- ]] && NEEDS_GDM_RESTART=true
    return 0
}

add_howdy_to_pam() {
    local pam_file="$1" label="$2"

    if [[ ! -f "$pam_file" ]]; then
        warn "$label: file not found ($pam_file)"
        return 0
    fi

    local tmpfile
    tmpfile=$(mktemp "${pam_file}.howdy-staging-XXXX")
    pam_render "$pam_file" > "$tmpfile"

    if cmp -s "$tmpfile" "$pam_file"; then
        rm -f "$tmpfile"
        success "$label — already configured"
        return 0
    fi

    # Validate: every non-howdy auth line kept, exactly one howdy entry
    local orig_auth new_auth howdy_count
    orig_auth=$(grep -E "^auth" "$pam_file" | grep -cvE "$HOWDY_PAM_RE" || true)
    new_auth=$(grep -c "^auth" "$tmpfile" || true)
    howdy_count=$(grep -cE "$HOWDY_PAM_RE" "$tmpfile" || true)

    if (( new_auth != orig_auth + 1 )) || (( howdy_count != 1 )); then
        fail "$label — validation failed (auth: $orig_auth → $new_auth, howdy: $howdy_count)"
        rm -f "$tmpfile"
        return 1
    fi

    if grep -qE "$HOWDY_PAM_RE" "$pam_file"; then
        _pam_commit "$pam_file" "$tmpfile"
        success "$label — updated (current flags and position)"
    else
        _pam_commit "$pam_file" "$tmpfile"
        success "$label — configured"
    fi
}

remove_howdy_from_pam() {
    local pam_file="$1" label="$2" reason="$3"

    [[ -f "$pam_file" ]] && grep -qE "$HOWDY_PAM_RE" "$pam_file" || return 0

    local tmpfile
    tmpfile=$(mktemp "${pam_file}.howdy-staging-XXXX")
    grep -vE "$HOWDY_PAM_RE" "$pam_file" > "$tmpfile" || true
    _pam_commit "$pam_file" "$tmpfile"
    success "$label — howdy removed ($reason)"
}

# The polkit PAM file to use, or empty. Fedora 44+ ships polkit-1 in
# /usr/lib/pam.d/, which configure_pam copies to /etc/pam.d/ as an override.
polkit_pam_file() {
    local f
    for f in /etc/pam.d/polkit-1 /etc/pam.d/polkit; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 0
}

# GDM 50+ ships gdm-switchable-auth: one PAM service offering several login
# mechanisms (SSSD passkey / web login, via authselect's with-switchable-auth).
# Every other authselect setup generates its stack as a stub that refuses all
# logins (pam_debug auth=authinfo_unavail). A `sufficient` howdy line in front
# of that stub would quietly turn a disabled service into a working login, so
# howdy goes into gdm-switchable-auth only while the stack is live.
switchable_auth_enabled() {
    [[ -f "$GDM_SWITCHABLE_PAM" && -f "$SWITCHABLE_STACK_PAM" ]] || return 1
    ! grep -qE "^[[:space:]]*auth[[:space:]].*pam_debug\.so.*auth=authinfo_unavail" "$SWITCHABLE_STACK_PAM"
}

# Every PAM change configure_pam would make, without making it
pam_config_needs_fix() {
    local f
    for f in /etc/pam.d/sudo /etc/pam.d/su "$(polkit_pam_file)"; do
        [[ -n "$f" ]] && pam_needs_update "$f" && return 0
    done
    [[ -z "$(polkit_pam_file)" && -f /usr/lib/pam.d/polkit-1 ]] && return 0
    if [[ "${DM_TYPE:-}" == "gdm" ]]; then
        pam_needs_update /etc/pam.d/gdm-password && return 0
        grep -qsE "$HOWDY_PAM_RE" /etc/pam.d/gdm-fingerprint && return 0
        if switchable_auth_enabled; then
            pam_needs_update "$GDM_SWITCHABLE_PAM" && return 0
        else
            grep -qsE "$HOWDY_PAM_RE" "$GDM_SWITCHABLE_PAM" && return 0
        fi
    fi
    return 1
}

# ─── Configure PAM ───────────────────────────────────────────────────
configure_pam() {
    header "Configuring PAM (Facial Auth with Password Fallback)"

    echo "  ⚠  About to modify PAM files. If anything goes wrong:"
    echo "       Ctrl+Alt+F3 to switch to a TTY"
    echo "       Log in with password"
    echo "       Restore: for f in /etc/pam.d/*.howdy-backup; do cp \"\$f\" \"\${f%.howdy-backup}\"; done"
    echo ""
    sleep 2

    local failures=0

    # GDM (GNOME login and lock screen) — only when GDM is active
    if [[ "${DM_TYPE:-}" == "gdm" ]]; then
        add_howdy_to_pam "/etc/pam.d/gdm-password" "GDM login/unlock" || failures=$((failures + 1))
        # GDM runs the password and fingerprint conversations in parallel, so a
        # howdy line in both starts two scans that fight over the camera
        remove_howdy_from_pam "/etc/pam.d/gdm-fingerprint" "GDM fingerprint" \
            "it runs in parallel with gdm-password"
        # See switchable_auth_enabled. If GDM ever runs it alongside
        # gdm-password, howdy-auth's lock lets only one scan use the camera.
        if switchable_auth_enabled; then
            add_howdy_to_pam "$GDM_SWITCHABLE_PAM" "GDM switchable auth" || failures=$((failures + 1))
        elif [[ -f "$GDM_SWITCHABLE_PAM" ]]; then
            remove_howdy_from_pam "$GDM_SWITCHABLE_PAM" "GDM switchable auth" \
                "authselect has its stack disabled"
            info "GDM switchable auth: stack disabled by authselect — skipped (nothing uses it)"
        fi
    fi

    # Shell access
    add_howdy_to_pam "/etc/pam.d/sudo" "sudo" || failures=$((failures + 1))
    add_howdy_to_pam "/etc/pam.d/su" "su" || failures=$((failures + 1))

    # Polkit GUI prompts
    local polkit_file
    polkit_file=$(polkit_pam_file)
    if [[ -z "$polkit_file" && -f /usr/lib/pam.d/polkit-1 ]]; then
        cp /usr/lib/pam.d/polkit-1 /etc/pam.d/polkit-1
        polkit_file=/etc/pam.d/polkit-1
    fi
    if [[ -n "$polkit_file" ]]; then
        add_howdy_to_pam "$polkit_file" "Polkit GUI prompts" || failures=$((failures + 1))
    else
        warn "Polkit PAM file not found (checked /etc/pam.d/ and /usr/lib/pam.d/)"
    fi

    if (( failures > 0 )); then
        fail "PAM configuration finished with $failures failure(s) — files left unchanged"
    else
        success "PAM configuration complete"
    fi
}

# ─── Fix GDM permissions (video group) ───────────────────────────────
fix_gdm_permissions() {
    if [[ "${DM_TYPE:-}" != "gdm" ]]; then
        info "Skipping GDM permissions (DM_TYPE=${DM_TYPE:-unset})"
        return
    fi

    header "Fixing GDM Camera Permissions"

    if ! id gdm &>/dev/null; then
        warn "gdm user does not exist"
        return
    fi

    if id gdm 2>/dev/null | grep -q "(video)"; then
        success "gdm is already in the video group"
    else
        usermod -aG video gdm
        success "Added gdm to the video group"
        NEEDS_GDM_RESTART=true
    fi
}

# ─── SELinux audit-based fallback ────────────────────────────────────
_selinux_audit_fallback() {
    local denials
    denials=$(ausearch -m avc -ts today 2>/dev/null | grep -iE "howdy|xdm.*video" || true)
    if [[ -n "$denials" ]]; then
        # Feed audit2allow only the howdy/GDM-camera denials; everything else
        # denied today is none of our business and must not be allowed
        local work_dir
        work_dir=$(mktemp -d -t howdy-selinux-XXXXXX)
        if (cd "$work_dir" && printf '%s\n' "$denials" | audit2allow -M howdy_gdm >/dev/null 2>&1 && \
            semodule -i howdy_gdm.pp 2>/dev/null); then
            success "SELinux policy installed from audit log (howdy_gdm)"
            NEEDS_GDM_RESTART=true
        else
            warn "Could not install audit-based SELinux policy"
        fi
        rm -rf "$work_dir"
    else
        info "No SELinux denials found yet — policy may be generated on first use"
        info "If GDM unlock fails, re-run: sudo $0 --fix"
    fi
}

# ─── Fix SELinux policies ─────────────────────────────────────────────
fix_selinux() {
    header "Configuring SELinux for Howdy"

    local selinux_status
    selinux_status=$(getenforce 2>/dev/null || echo "Disabled")

    if [[ "$selinux_status" == "Disabled" ]]; then
        info "SELinux is disabled — no policy needed"
        return
    fi

    info "SELinux is $selinux_status"

    # Locate policy source shipped alongside the script
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local policy_te="$script_dir/selinux/howdy_pam.te"
    # Hash of the .te last installed, so an updated policy gets reloaded
    local hash_file=/etc/howdy/.selinux-te.sha256

    local installed=false
    semodule -l 2>/dev/null | grep -q "howdy_pam" && installed=true

    if [[ ! -f "$policy_te" ]]; then
        if $installed; then
            success "howdy_pam SELinux policy already installed"
            return
        fi
        warn "Policy source not found at $policy_te"
        warn "Falling back to audit-based generation"
        _selinux_audit_fallback
        return
    fi

    local te_hash
    te_hash=$(sha256sum "$policy_te" | cut -d' ' -f1)
    if $installed && [[ "$(cat "$hash_file" 2>/dev/null)" == "$te_hash" ]]; then
        success "howdy_pam SELinux policy already installed (up to date)"
        return
    fi

    if $installed; then
        info "Updating howdy_pam SELinux policy from $policy_te"
    else
        info "Building SELinux policy from $policy_te"
    fi

    local policy_dir
    policy_dir=$(mktemp -d -t howdy-selinux-XXXXXX)
    trap 'rm -rf "$policy_dir"; trap - RETURN' RETURN

    cp "$policy_te" "$policy_dir/howdy_pam.te"

    if checkmodule -M -m -o "$policy_dir/howdy_pam.mod" "$policy_dir/howdy_pam.te" 2>/dev/null && \
       semodule_package -o "$policy_dir/howdy_pam.pp" -m "$policy_dir/howdy_pam.mod" 2>/dev/null && \
       semodule -i "$policy_dir/howdy_pam.pp" 2>/dev/null; then
        mkdir -p /etc/howdy
        echo "$te_hash" > "$hash_file"
        success "SELinux policy installed (howdy_pam)"
        NEEDS_GDM_RESTART=true
    else
        warn "Pre-built policy failed — trying audit-based fallback"
        _selinux_audit_fallback
    fi
}

# ─── Consolidated GDM restart prompt ─────────────────────────────────
prompt_gdm_restart() {
    [[ "$NEEDS_GDM_RESTART" == "true" ]] || return 0
    [[ "${DM_TYPE:-}" == "gdm" ]] || return 0

    echo ""
    echo -e "  ${YELLOW}⚠  GDM restart required for changes to take effect.${NC}"
    echo "     This will close all GUI sessions. For safety:"
    echo "       Ctrl+Alt+F3 → log in (so you have a recovery shell)"
    echo ""
    if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        info "Non-interactive mode: skipping GDM restart"
        echo "  Restart later with: sudo systemctl restart gdm"
        return 0
    fi
    read -rp "  Restart GDM now? (y/N): " REPLY
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        systemctl restart gdm
    else
        info "Restart later with: sudo systemctl restart gdm"
    fi
}

# ─── Add Face Model ───────────────────────────────────────────────────
add_face_model() {
    header "Face Model Registration"

    local actual_user="${SUDO_USER:-$USER}"
    if [[ "$actual_user" == "root" ]]; then
        read -rp "Enter username to register: " actual_user
    fi

    echo ""
    echo "  Instructions:"
    echo "    1. Position your face in front of the IR camera"
    echo "    2. The IR LEDs should light up"
    echo "    3. Keep your face still during capture"
    echo ""
    echo -e "  ${BOLD}${YELLOW}💡 Highly recommended: register MULTIPLE face models${NC}"
    echo "     Better accuracy and fewer false rejections come from having"
    echo "     several enrolled angles/conditions. Re-run this option to add"
    echo "     additional models:"
    echo "       • One without glasses, one with glasses (if you wear them)"
    echo "       • One in normal indoor lighting, one in dimmer light"
    echo "       • Slight head-angle variations (straight on, slight left/right)"
    echo "     Multiple models also let you run with a shorter timeout"
    echo "     (option 7 → Tune timeout) — 8s works well with 3+ models;"
    echo "     12s is the safe default for a single model."
    echo ""
    read -rp "  Press Enter when ready..."
    echo ""
    warn "Note: 'ioctl(VIDIOC_QBUF): Bad file descriptor' may appear — this is harmless OpenCV noise with MJPG cameras and does not affect capture."
    echo ""

    howdy add -U "$actual_user" || {
        fail "Face registration failed"
        echo ""
        echo "  Troubleshooting:"
        echo "    - Run: sudo $0 --diagnose"
        echo "    - Test scan: sudo $0 --test"
        echo "    - Edit config: sudo howdy config"
        return 1
    }

    success "Face model added for user: $actual_user"
    echo ""
    info "Tip: run 'sudo howdy list' to see all enrolled models."
    info "     Re-run option 6 to add another (with/without glasses, etc.)."
}

# ─── Tune Recognition Timeout ────────────────────────────────────────
# Adjusts the per-attempt face-scan timeout in /usr/lib64/security/howdy/config.ini.
# Valid range: 4–18 seconds (anything outside this is rejected as harmful: too
# short and cold-start scans never finish; too long and PAM feels broken).
#
# Optional first argument: a numeric value to set directly (used by --set-timeout).
# Without an argument, prompts interactively.
tune_timeout() {
    local requested="${1:-}"
    local config="$HOWDY_INSTALL_DIR/config.ini"

    header "Tune Recognition Timeout"

    if [[ ! -f "$config" ]]; then
        error "Howdy is not installed at $HOWDY_INSTALL_DIR. Run a full install first."
    fi

    local current
    current=$(grep "^timeout" "$config" 2>/dev/null | sed 's/.*= *//' | head -1)
    current="${current:-$TIMEOUT_DEFAULT}"

    echo -e "  Current timeout: ${BOLD}${current}s${NC}"
    echo ""
    echo "  Recommended values:"
    echo -e "    ${GREEN}8s${NC}  — fast, works well with ${BOLD}multiple${NC} enrolled face models"
    echo "          (with/without glasses, varied lighting): more candidate"
    echo "          models means a match is usually found in the first few"
    echo "          frames, so a shorter window is plenty"
    echo -e "    ${GREEN}12s${NC} — safe default for a ${BOLD}single${NC} enrolled face model"
    echo "          (extra headroom for cold-start camera, dlib load, and"
    echo "          face search; the v1.2.1 default)"
    echo ""
    echo "  Range: ${TIMEOUT_MIN} (minimum) – ${TIMEOUT_MAX} (maximum) seconds"
    echo ""

    local new="$requested"

    if [[ -z "$new" ]]; then
        if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
            info "Non-interactive mode and no value provided — leaving timeout at ${current}s"
            info "Use --set-timeout N to change it directly"
            return 0
        fi
        read -rp "  Enter new timeout in seconds [${current}]: " new
        new="${new:-$current}"
    fi

    if ! [[ "$new" =~ ^[0-9]+$ ]]; then
        error "Invalid timeout: '$new' (must be a positive integer)"
    fi

    if (( new < TIMEOUT_MIN )) || (( new > TIMEOUT_MAX )); then
        error "Timeout ${new}s is out of range (must be ${TIMEOUT_MIN}–${TIMEOUT_MAX} seconds)"
    fi

    if [[ "$new" == "$current" ]]; then
        info "Timeout unchanged (${current}s)"
        return 0
    fi

    sed -i "s/^timeout.*/timeout = $new/" "$config"
    success "Timeout updated: ${current}s → ${new}s"
    info "Takes effect on the next auth attempt — no restart needed."

    if (( new <= 6 )); then
        warn "Heads up: ${new}s is quite short. If you only have 1 enrolled model,"
        warn "you may see more 'Face not recognized' failures. Enroll additional"
        warn "models (option 6) to compensate."
    fi
}

# ─── Test Face Recognition ───────────────────────────────────────────
# Stand-in for `howdy test`, which v2.6.1 refuses to run when
# recording_plugin != opencv. We ship recording_plugin=ffmpeg (opencv
# fails in PAM context on Fedora MJPG cameras — see install_howdy()),
# so we invoke compare.py directly. This exercises the exact same code
# path PAM uses via howdy-auth, so a pass/fail here mirrors real auth.
test_face() {
    header "Face Recognition Test"

    local actual_user="${SUDO_USER:-$USER}"
    if [[ "$actual_user" == "root" ]]; then
        read -rp "Enter username to test: " actual_user
    fi

    local compare_py="$HOWDY_INSTALL_DIR/compare.py"
    if [[ ! -f "$compare_py" ]]; then
        fail "compare.py not found at $compare_py — reinstall with: sudo $0"
        return 1
    fi

    local model_file="$HOWDY_INSTALL_DIR/models/${actual_user}.dat"
    if [[ ! -s "$model_file" ]]; then
        fail "No face models enrolled for '${actual_user}'. Run option 6 first."
        return 1
    fi

    echo ""
    info "Look at the IR camera — scanning..."
    echo ""

    local start elapsed output rc=0
    start=$(date +%s)
    # `|| rc=$?` keeps set -e from exiting on a failed scan
    output=$(/usr/bin/python3 "$compare_py" "$actual_user" 2>&1) || rc=$?
    elapsed=$(( $(date +%s) - start ))

    echo "$output"
    echo ""

    if [[ "$rc" -eq 0 ]]; then
        local label
        label=$(printf '%s\n' "$output" \
            | grep -oE 'Winning model: [0-9]+ \("[^"]+"\)' \
            | grep -oE '"[^"]+"' \
            | tr -d '"' \
            | head -1)
        success "😊 Recognized as '${label:-$actual_user}' in ${elapsed}s"
        return 0
    else
        warn "🤔 Not recognized (compare.py exit ${rc}, took ${elapsed}s)"
        echo ""
        echo "  Common exit codes:"
        echo "    10 = no enrolled model     → option 6 to enrol a face"
        echo "    11 = scan timeout          → option 7 to raise the timeout"
        echo "    13 = too dark              → improve IR lighting or add a dim model"
        echo "     1 = error                 → dlib data missing or Python error; run --diagnose"
        return 1
    fi
}

# ─── GNOME Keyring Auto-Unlock ───────────────────────────────────────
# A face login never sees the password, so pam_gnome_keyring cannot unlock
# the login keyring and GNOME prompts for it later. --setup-keyring changes
# the login keyring to a random password, seals it with systemd-creds (TPM2 +
# host key, user-scoped) and installs a user service that unseals it and
# unlocks the keyring at each graphical login. The login password itself is
# never stored, so a leaked secret can't be used for sudo, and changing the
# login password later doesn't invalidate the sealed one.

# Sets KR_USER, KR_UID, KR_HOME, KR_CRED (once per run)
_keyring_resolve_user() {
    [[ -n "${KR_USER:-}" ]] && return 0
    KR_USER="${SUDO_USER:-${USER:-root}}"
    if [[ "$KR_USER" == "root" ]]; then
        [[ "${NON_INTERACTIVE:-0}" == "1" ]] && \
            error "Run this with sudo from the account whose keyring should be unlocked"
        read -rp "  Enter the username whose keyring to manage: " KR_USER
    fi
    id "$KR_USER" &>/dev/null || error "No such user: $KR_USER"
    KR_UID=$(id -u "$KR_USER")
    KR_HOME=$(getent passwd "$KR_USER" | cut -d: -f6)
    KR_CRED="$KR_HOME/$KEYRING_CRED_REL"
}

# Run a command as KR_USER on their session bus
_as_user() {
    runuser -u "$KR_USER" -- env \
        HOME="$KR_HOME" \
        XDG_RUNTIME_DIR="/run/user/$KR_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$KR_UID/bus" \
        "$@"
}

_keyring_require_session() {
    [[ -S "/run/user/$KR_UID/bus" ]] || \
        error "$KR_USER has no running session bus — run this from $KR_USER's desktop session"
}

_keyring_ensure_gi() {
    python3 -c 'from gi.repository import Gio' 2>/dev/null && return 0
    info "Installing python3-gobject (D-Bus bindings for the keyring helper)..."
    dnf install -y python3-gobject-base 2>&1 | tail -2
    python3 -c 'from gi.repository import Gio' 2>/dev/null || error "python3-gobject is not importable"
}

# An earlier, never-finished prototype installed a setuid-bash helper and a
# unit under /usr/lib; neither worked. Only remove files carrying its markers.
_keyring_cleanup_legacy() {
    local legacy_helper=/usr/libexec/howdy-keyring-unlock
    local legacy_unit=/usr/lib/systemd/user/howdy-keyring-unlock.service
    local legacy_want=/usr/lib/systemd/user/graphical-session.target.wants/howdy-keyring-unlock.service

    if [[ -f "$legacy_helper" ]] && grep -q "PROTOTYPE" "$legacy_helper"; then
        rm -f "$legacy_helper"
        info "Removed old prototype helper $legacy_helper"
    fi
    if [[ -f "$legacy_unit" ]] && grep -q "/var/lib/howdy/keyring-creds" "$legacy_unit"; then
        rm -f "$legacy_unit"
        [[ -L "$legacy_want" ]] && rm -f "$legacy_want"
        info "Removed old prototype unit $legacy_unit"
    fi
    rmdir /var/lib/howdy/keyring-creds /var/lib/howdy 2>/dev/null || true
}

_keyring_install_files() {
    local script_dir src
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    src="$script_dir/keyring/howdy-keyring"
    [[ -f "$src" ]] || error "Keyring helper not found at $src (keep the keyring/ directory next to the script)"

    install -m 0755 "$src" "$KEYRING_HELPER"

    mkdir -p "$(dirname "$KEYRING_UNIT_FILE")"
    cat > "$KEYRING_UNIT_FILE" << EOF
# Installed by install-howdy.sh --setup-keyring
[Unit]
Description=Unlock the GNOME login keyring after a Howdy face login
# Silently skipped for users who have not run --setup-keyring
ConditionPathExists=%h/${KEYRING_CRED_REL}
Wants=gnome-keyring-daemon.service
After=gnome-keyring-daemon.service
# Before the shell and autostart apps, so nothing asks for a secret first
Before=graphical-session-pre.target

[Service]
Type=oneshot
ExecStart=${KEYRING_HELPER} unlock
TimeoutStartSec=20

[Install]
WantedBy=graphical-session-pre.target
EOF
    command -v restorecon &>/dev/null && restorecon "$KEYRING_HELPER" "$KEYRING_UNIT_FILE" 2>/dev/null
    systemctl --global enable "$KEYRING_UNIT" >/dev/null 2>&1 || \
        warn "Could not enable $KEYRING_UNIT for all users"
    _as_user systemctl --user daemon-reload 2>/dev/null || true
}

setup_keyring() {
    header "Keyring Auto-Unlock"

    [[ "${NON_INTERACTIVE:-0}" == "1" ]] && \
        error "--setup-keyring asks for your keyring password and can't run non-interactively"
    command -v systemd-creds &>/dev/null || error "systemd-creds not found (systemd 256+ required)"

    _keyring_resolve_user
    _keyring_require_session

    if [[ -f "$KR_CRED" ]]; then
        _keyring_install_files
        success "Keyring auto-unlock is already set up for $KR_USER (helper and unit refreshed)"
        info "To undo it: sudo $0 --remove-keyring"
        return 0
    fi

    [[ -f "$KR_HOME/.local/share/keyrings/login.keyring" ]] || \
        error "No login keyring found for $KR_USER ($KR_HOME/.local/share/keyrings/login.keyring)"

    echo "  After a face login GNOME asks for your keyring password, because face"
    echo "  unlock never sees your password. This fixes that:"
    echo ""
    echo "    • Your login keyring gets a new random password, sealed with"
    echo "      systemd-creds to this machine's TPM and to your user account."
    echo "    • At each graphical login a user service unseals it and unlocks the"
    echo "      keyring. Your login password is never stored, and changing it later"
    echo "      won't break this."
    echo "    • Trade-off: the keyring is unlocked at every login, face or password,"
    echo "      just like after a password login today."
    echo ""

    if systemd-creds has-tpm2 &>/dev/null; then
        info "TPM2 available — sealing to TPM2 + host key"
    else
        warn "No usable TPM2 — sealing with the host key only (/var/lib/systemd/credential.secret)."
        warn "That protects it only as well as your disk encryption does."
    fi
    echo ""
    read -rp "  Continue? (y/N): " REPLY
    [[ $REPLY =~ ^[Yy]$ ]] || { info "Aborted — nothing changed"; return 0; }

    _keyring_ensure_gi
    _keyring_cleanup_legacy
    _keyring_install_files
    # Make sure the installed uninstaller knows to refuse while a keyring is re-keyed
    if [[ -f /usr/local/bin/howdy-uninstall ]]; then
        create_uninstaller
    fi

    local old_pw new_pw check
    echo ""
    read -rsp "  Current login keyring password (normally your login password): " old_pw
    echo ""
    [[ -n "$old_pw" ]] || error "Empty password — nothing changed"

    new_pw=$(head -c 32 /dev/urandom | base64 | tr -d '=+/\n')

    # Seal first and prove it unseals before the keyring is touched
    install -d -o "$KR_USER" -g "$(id -gn "$KR_USER")" -m 0700 "$(dirname "$KR_CRED")"
    printf '%s' "$new_pw" | \
        _as_user systemd-creds encrypt --user --name="$KEYRING_CRED_NAME" - "$KR_CRED" || \
        error "Sealing with systemd-creds failed — nothing changed"
    chmod 0600 "$KR_CRED"
    check=$(_as_user systemd-creds decrypt --user --name="$KEYRING_CRED_NAME" "$KR_CRED" - 2>/dev/null) || check=""
    if [[ "$check" != "$new_pw" ]]; then
        rm -f "$KR_CRED"
        error "Sealed password did not unseal correctly — nothing changed"
    fi

    if ! printf '%s\0%s' "$old_pw" "$new_pw" | _as_user "$KEYRING_HELPER" change; then
        rm -f "$KR_CRED"
        error "Could not change the keyring password (wrong current password?) — nothing changed"
    fi
    unset old_pw check
    success "Login keyring re-keyed and sealed for $KR_USER"

    echo ""
    echo -e "  ${BOLD}Recovery password${NC} — store it somewhere other than this keyring:"
    echo ""
    echo -e "      ${BOLD}${new_pw}${NC}"
    echo ""
    echo "  You only need it if the sealed copy is lost (TPM cleared, OS reinstalled)."
    echo "  While this machine works you can print it again with:"
    echo "      systemd-creds decrypt --user --name=$KEYRING_CRED_NAME ~/$KEYRING_CRED_REL -"
    unset new_pw
    echo ""

    read -rp "  Lock the keyring now and check that it unlocks automatically? (Y/n): " REPLY
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        if _as_user "$KEYRING_HELPER" lock && \
           _as_user systemctl --user start "$KEYRING_UNIT" && \
           [[ "$(_as_user "$KEYRING_HELPER" status 2>/dev/null)" == "unlocked" ]]; then
            success "Keyring was locked and unlocked automatically"
        else
            fail "Automatic unlock did not work — check: journalctl --user -u $KEYRING_UNIT"
            info "Unlock it by hand with the recovery password above (Passwords and Keys → Login)"
        fi
    fi

    echo ""
    info "Takes effect from your next login. Undo with: sudo $0 --remove-keyring"
}

remove_keyring() {
    header "Remove Keyring Auto-Unlock"

    [[ "${NON_INTERACTIVE:-0}" == "1" ]] && \
        error "--remove-keyring asks for a new keyring password and can't run non-interactively"

    _keyring_resolve_user
    if [[ ! -f "$KR_CRED" ]]; then
        info "Keyring auto-unlock is not set up for $KR_USER"
        return 0
    fi
    _keyring_require_session
    _keyring_ensure_gi
    [[ -x "$KEYRING_HELPER" ]] || _keyring_install_files

    local cur_pw new_pw new_pw2
    cur_pw=$(_as_user systemd-creds decrypt --user --name="$KEYRING_CRED_NAME" "$KR_CRED" - 2>/dev/null) || cur_pw=""
    if [[ -z "$cur_pw" ]]; then
        warn "Could not unseal the stored keyring password (TPM cleared or host key changed?)"
        read -rsp "  Recovery password: " cur_pw
        echo ""
    fi

    echo "  Choose the keyring password to go back to. Use your login password so"
    echo "  password logins unlock the keyring automatically again."
    read -rsp "  New keyring password: " new_pw
    echo ""
    read -rsp "  Repeat it: " new_pw2
    echo ""
    [[ -n "$new_pw" && "$new_pw" == "$new_pw2" ]] || error "Passwords are empty or don't match — nothing changed"

    printf '%s\0%s' "$cur_pw" "$new_pw" | _as_user "$KEYRING_HELPER" change || \
        error "Could not change the keyring password — nothing changed"
    unset cur_pw new_pw new_pw2

    rm -f "$KR_CRED"
    success "Keyring auto-unlock removed for $KR_USER; keyring password reset"
}

# Menu entry: set up, or offer removal when already set up
keyring_menu() {
    _keyring_resolve_user
    if [[ -f "$KR_CRED" ]]; then
        read -rp "  Keyring auto-unlock is set up for $KR_USER. Remove it? (y/N): " REPLY
        [[ $REPLY =~ ^[Yy]$ ]] && remove_keyring
        return 0
    fi
    setup_keyring
}

# ─── Scan Sounds ─────────────────────────────────────────────────────
# Create the sound settings if missing (off by default). The *_sound paths
# can be pointed at any file pw-play understands.
ensure_feedback_conf() {
    [[ -f "$FEEDBACK_CONF" ]] && return 0
    mkdir -p "$(dirname "$FEEDBACK_CONF")"
    cat > "$FEEDBACK_CONF" << EOF
# Face unlock sounds, read by howdy-auth on every scan.
# Turn on or off with: sudo ./install-howdy.sh --sounds on|off
sounds = off
scan_sound = ${SOUND_DIR}/message.oga
success_sound = ${SOUND_DIR}/complete.oga
fail_sound = ${SOUND_DIR}/dialog-warning.oga
EOF
    chmod 0644 "$FEEDBACK_CONF"
}

set_sounds() {
    local state="${1:-}"
    [[ "$state" == on || "$state" == off ]] || error "Usage: --sounds on|off"

    ensure_feedback_conf
    if [[ "$state" == on ]]; then
        command -v pw-play &>/dev/null || dnf install -y pipewire-utils 2>&1 | tail -2
        [[ -d "$SOUND_DIR" ]] || dnf install -y sound-theme-freedesktop 2>&1 | tail -2
    fi
    sed -i -E "s/^[[:space:]]*sounds[[:space:]]*=.*/sounds = ${state}/" "$FEEDBACK_CONF"
    grep -qE "^[[:space:]]*sounds[[:space:]]*=" "$FEEDBACK_CONF" || echo "sounds = ${state}" >> "$FEEDBACK_CONF"
    success "Scan sounds ${state} — takes effect on the next scan"
    [[ "$state" == on ]] && info "Hear them with: ./install-howdy.sh --preview"
    return 0
}

# ─── Preview Scan Messages ───────────────────────────────────────────
# Plays howdy-auth's messages with a simulated scan (no camera, no auth):
# the animated terminal version sudo/su show, and the one-line-per-state
# version GDM shows on the login and lock screens.
preview_messages() {
    header "Scan Message Preview"

    local wrapper="$HOWDY_INSTALL_DIR/howdy-auth"
    [[ -x "$wrapper" ]] || error "howdy-auth is not installed — run a full install first"
    grep -q -- "--demo" "$wrapper" || error "Installed howdy-auth predates the preview — run: sudo $0 --fix"

    local outcomes=(success fail dark)
    [[ -n "${1:-}" ]] && outcomes=("$1")
    local who="${SUDO_USER:-$USER}"
    local o

    echo -e "  ${BOLD}Terminal (sudo, su)${NC}"
    for o in "${outcomes[@]}"; do
        PAM_USER="$who" "$wrapper" --demo "$o" sudo || true
    done
    echo ""
    echo -e "  ${BOLD}Login and lock screen (GDM shows each line for at least 2 s)${NC}"
    for o in "${outcomes[@]}"; do
        PAM_USER="$who" "$wrapper" --demo "$o" gdm-password < /dev/null | sed 's/^/    /' || true
        echo ""
    done
    info "Polkit dialogs animate the dots in place, like the terminal version."
    if grep -qE "^[[:space:]]*sounds[[:space:]]*=[[:space:]]*on" "$FEEDBACK_CONF" 2>/dev/null; then
        info "Scan sounds are on (each outcome above played its sound)."
    else
        info "Scan sounds are off — turn them on with: sudo $0 --sounds on"
    fi
}

# ─── PAM Configuration Check ─────────────────────────────────────────
check_pam() {
    header "PAM Configuration Check"

    if [[ -f "$HOWDY_INSTALL_DIR/pam.py" ]]; then
        success "Howdy PAM script found: $HOWDY_INSTALL_DIR/pam.py"
    else
        fail "Howdy not installed at $HOWDY_INSTALL_DIR"
        echo "  Run: sudo $0   (full install)"
    fi

    if [[ -f /usr/lib64/security/pam_exec.so ]] || [[ -f /usr/lib/security/pam_exec.so ]]; then
        success "pam_exec.so available (standard PAM)"
    else
        fail "pam_exec.so not found — this is part of the pam package"
    fi

    if [[ -f "$HOWDY_INSTALL_DIR/howdy-auth" ]]; then
        success "howdy-auth wrapper found: $HOWDY_INSTALL_DIR/howdy-auth"
    else
        fail "howdy-auth wrapper missing — reinstall with: sudo $0"
    fi

    echo ""

    local pam_files=(
        "/etc/pam.d/gdm-password:GDM login/unlock"
        "/etc/pam.d/gdm-fingerprint:GDM fingerprint"
        "${GDM_SWITCHABLE_PAM}:GDM switchable auth"
        "/etc/pam.d/sudo:sudo"
        "/etc/pam.d/su:su"
        "/etc/pam.d/polkit-1:Polkit (polkit-1)"
        "/etc/pam.d/polkit:Polkit (polkit)"
    )

    for entry in "${pam_files[@]}"; do
        local file="${entry%%:*}"
        local label="${entry##*:}"

        # Fedora 44+ ships polkit-1 to /usr/lib/pam.d/ instead of /etc/pam.d/
        local effective_file="$file"
        if [[ ! -f "$file" ]] && [[ "$file" == "/etc/pam.d/polkit-1" ]] && [[ -f "/usr/lib/pam.d/polkit-1" ]]; then
            effective_file="/usr/lib/pam.d/polkit-1"
        fi

        if [[ ! -f "$effective_file" ]]; then
            echo -e "  ${YELLOW}—${NC} $label: file not found"
            continue
        fi

        if [[ "$file" == "/etc/pam.d/gdm-fingerprint" ]]; then
            # Deliberately left without howdy (see configure_pam)
            if grep -qE "$HOWDY_PAM_RE" "$effective_file"; then
                echo -e "  ${YELLOW}⚠${NC} $label: has howdy — runs in parallel with gdm-password and fights over the camera; run --fix"
            else
                echo -e "  ${GREEN}✓${NC} $label: no howdy line (intended — gdm-password handles face unlock)"
            fi
            continue
        fi

        if [[ "$file" == "$GDM_SWITCHABLE_PAM" ]] && ! switchable_auth_enabled; then
            if grep -qE "$HOWDY_PAM_RE" "$effective_file"; then
                echo -e "  ${YELLOW}⚠${NC} $label: has howdy but authselect has the stack disabled — the line would enable it; run --fix"
            else
                echo -e "  ${GREEN}✓${NC} $label: stack disabled by authselect (not used) — howdy not added"
            fi
            continue
        fi

        if grep -qE "$HOWDY_PAM_RE" "$effective_file"; then
            local howdy_line
            howdy_line=$(grep -nE "$HOWDY_PAM_RE" "$effective_file" | head -1 | cut -d: -f1)

            if ! pam_needs_update "$effective_file"; then
                echo -e "  ${GREEN}✓${NC} $label: howdy on line $howdy_line [stdout: scan result visible to user]"
            elif ! grep -E "$HOWDY_PAM_RE" "$effective_file" | grep -q stdout; then
                echo -e "  ${YELLOW}⚠${NC} $label: howdy on line $howdy_line ${YELLOW}[no stdout flag — scan result hidden; run --fix to upgrade]${NC}"
            else
                echo -e "  ${YELLOW}⚠${NC} $label: howdy on line $howdy_line is in the wrong position (should follow pam_rootok / precede other auth); run --fix"
            fi
        else
            echo -e "  ${RED}✗${NC} $label: howdy NOT configured"
            if [[ "$effective_file" == "/usr/lib/pam.d/polkit-1" ]]; then
                echo -e "       Run: sudo $0 --fix   (will copy to /etc/pam.d/ and configure)"
            fi
        fi
    done

    echo ""
    echo -e "${BOLD}Auth lines in key PAM files:${NC}"
    for file in /etc/pam.d/gdm-password /etc/pam.d/sudo; do
        if [[ -f "$file" ]]; then
            echo -e "\n  ${CYAN}$file:${NC}"
            grep "^auth" "$file" | while IFS= read -r line; do
                if echo "$line" | grep -qE "pam_exec.*howdy-auth"; then
                    echo -e "    ${GREEN}$line${NC}"
                else
                    echo "    $line"
                fi
            done
        fi
    done
}

# ─── Full Diagnostic ──────────────────────────────────────────────────
diagnose() {
    header "Howdy Diagnostic Report"

    local issues=0

    # 1. Howdy installed?
    echo -e "${BOLD}1. Howdy Installation${NC}"
    if command -v howdy &>/dev/null; then
        success "howdy command found: $(command -v howdy)"
    else
        fail "howdy command not found"
        issues=$((issues + 1))
    fi

    if [[ -f "$HOWDY_INSTALL_DIR/pam.py" ]]; then
        success "Howdy Python files found at $HOWDY_INSTALL_DIR"
    else
        fail "Howdy not installed at $HOWDY_INSTALL_DIR"
        echo "  Fix: Reinstall with: sudo $0"
        issues=$((issues + 1))
    fi

    if [[ -f "$HOWDY_INSTALL_DIR/howdy-auth" ]]; then
        success "howdy-auth wrapper found: $HOWDY_INSTALL_DIR/howdy-auth"
    else
        fail "howdy-auth wrapper missing — reinstall with: sudo $0"
        issues=$((issues + 1))
    fi

    if [[ -f /usr/lib64/security/pam_exec.so ]] || [[ -f /usr/lib/security/pam_exec.so ]]; then
        success "pam_exec.so available"
    else
        fail "pam_exec.so not found (part of the pam package)"
        issues=$((issues + 1))
    fi

    if [[ -f /etc/howdy/.installed-tag ]]; then
        info "Installed ref: $(cat /etc/howdy/.installed-tag) ($(cut -c1-7 /etc/howdy/.installed-ref 2>/dev/null || echo '?'))"
    fi
    info "Installer version: ${SCRIPT_VERSION}"
    echo ""

    # 2. dlib
    echo -e "${BOLD}2. Python dlib Module${NC}"
    if python3 -c "import dlib" 2>/dev/null; then
        local dlib_loc
        dlib_loc=$(python3 -c "import dlib; print(dlib.__file__)" 2>/dev/null)
        success "dlib imports OK ($dlib_loc)"
    else
        fail "python3 cannot import dlib"
        echo "  Fix: sudo $0 --fix"
        issues=$((issues + 1))
    fi

    if id gdm &>/dev/null; then
        if sudo -u gdm python3 -c "import dlib" 2>/dev/null; then
            success "dlib imports OK as gdm user"
        else
            fail "gdm user cannot import dlib (GDM unlock will fail)"
            echo "  Fix: sudo $0 --fix"
            issues=$((issues + 1))
        fi
    fi
    echo ""

    # 3. IR Camera
    echo -e "${BOLD}3. IR Camera${NC}"
    local config_device=""
    if [[ -f "$HOWDY_INSTALL_DIR/config.ini" ]]; then
        config_device=$(grep "^device_path" "$HOWDY_INSTALL_DIR/config.ini" 2>/dev/null | sed 's/.*= *//')
    fi

    if [[ -n "$config_device" ]]; then
        info "Configured device: $config_device"
        if [[ -e "$config_device" ]]; then
            success "Device exists"
            if v4l2-ctl --device="$config_device" --get-fmt-video &>/dev/null; then
                success "Device is accessible"
            else
                fail "Cannot query device (permissions?)"
                issues=$((issues + 1))
            fi
        else
            fail "Device $config_device does not exist!"
            echo "  Fix: sudo $0 --detect-ir, then edit $HOWDY_INSTALL_DIR/config.ini"
            issues=$((issues + 1))
        fi
    else
        fail "No device configured in $HOWDY_INSTALL_DIR/config.ini"
        issues=$((issues + 1))
    fi
    echo ""

    # 4. GDM permissions
    echo -e "${BOLD}4. GDM Permissions${NC}"
    if id gdm &>/dev/null; then
        if id gdm 2>/dev/null | grep -q "(video)"; then
            success "gdm is in the video group"
        else
            fail "gdm is NOT in the video group (GDM unlock will fail)"
            echo "  Fix: sudo usermod -aG video gdm && sudo systemctl restart gdm"
            issues=$((issues + 1))
        fi
    else
        warn "gdm user not found (not using GDM?)"
    fi
    echo ""

    # 5. SELinux
    echo -e "${BOLD}5. SELinux${NC}"
    local se_status
    se_status=$(getenforce 2>/dev/null || echo "Disabled")
    info "SELinux status: $se_status"

    if [[ "$se_status" != "Disabled" ]]; then
        if semodule -l 2>/dev/null | grep -q "howdy"; then
            success "Howdy SELinux policy is installed"
        else
            warn "No howdy SELinux policy found"
            issues=$((issues + 1))
        fi

        local recent_denials
        recent_denials=$(ausearch -m avc -ts recent 2>/dev/null | grep -ciE "howdy|xdm.*video" || true)
        if [[ "$recent_denials" -gt 0 ]]; then
            fail "Found $recent_denials recent SELinux denial(s) related to howdy/GDM"
            echo "  Fix: sudo $0 --fix"
            issues=$((issues + 1))
        else
            success "No recent SELinux denials"
        fi
    fi
    echo ""

    # 6. PAM configuration
    echo -e "${BOLD}6. PAM Configuration${NC}"
    check_pam
    echo ""

    # 7. dlib data files
    echo -e "${BOLD}7. dlib Face Recognition Models${NC}"
    local data_dir="$HOWDY_INSTALL_DIR/dlib-data"
    local data_ok=true
    for dat in dlib_face_recognition_resnet_model_v1.dat mmod_human_face_detector.dat shape_predictor_5_face_landmarks.dat; do
        if [[ -f "$data_dir/$dat" ]]; then
            success "$dat"
        else
            fail "$dat missing"
            data_ok=false
            issues=$((issues + 1))
        fi
    done
    if ! $data_ok; then
        echo "  Fix: sudo $0 --fix"
    fi
    echo ""

    # 8. Face models
    echo -e "${BOLD}8. Face Models${NC}"
    if command -v howdy &>/dev/null; then
        local model_output
        model_output=$(howdy list 2>&1 || true)

        local model_count
        model_count=$(echo "$model_output" | grep -cE '^\s*[0-9]+\s+[0-9]{4}-' || true)

        if [[ "$model_count" -gt 0 ]]; then
            success "$model_count face model(s) registered:"
            echo "$model_output" | sed 's/^/    /'
        else
            fail "No face models enrolled"
            echo "  Fix: sudo howdy add"
            issues=$((issues + 1))
        fi
    fi
    echo ""

    # 9. Keyring auto-unlock (optional)
    echo -e "${BOLD}9. Keyring Auto-Unlock${NC}"
    local kr_user="${SUDO_USER:-}"
    if [[ -z "$kr_user" || "$kr_user" == "root" ]]; then
        info "Run via sudo from your own account to check your keyring setup"
    else
        local kr_home kr_cred
        kr_home=$(getent passwd "$kr_user" | cut -d: -f6)
        kr_cred="$kr_home/$KEYRING_CRED_REL"
        if [[ ! -f "$kr_cred" ]]; then
            info "Not set up for $kr_user (optional: sudo $0 --setup-keyring)"
        else
            if [[ -x "$KEYRING_HELPER" ]] && systemctl --global is-enabled --quiet "$KEYRING_UNIT" 2>/dev/null; then
                success "Helper installed and $KEYRING_UNIT enabled"
            else
                fail "Helper or user unit missing"
                echo "  Fix: sudo $0 --setup-keyring   (refreshes them)"
                issues=$((issues + 1))
            fi
            if runuser -u "$kr_user" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$kr_user")" \
                    systemd-creds decrypt --user --name="$KEYRING_CRED_NAME" "$kr_cred" - >/dev/null 2>&1; then
                success "Sealed keyring password unseals for $kr_user"
            else
                fail "Sealed keyring password can't be unsealed (TPM cleared or host key changed?)"
                echo "  Fix: sudo $0 --remove-keyring (with your recovery password), then --setup-keyring"
                issues=$((issues + 1))
            fi
        fi
    fi
    echo ""

    # Summary
    header "Diagnostic Summary"
    if [[ $issues -eq 0 ]]; then
        success "All checks passed! Howdy should be working."
    else
        fail "$issues issue(s) found."
        echo "  Run: sudo $0 --fix    to auto-fix"
    fi
}

# ─── Auto-Fix Common Issues ───────────────────────────────────────────
auto_fix() {
    header "Auto-Fix"

    check_root
    check_supported_system

    # Fix 1: dlib symlinks
    fix_dlib_symlinks

    # Fix 2: GDM video group
    fix_gdm_permissions

    # Fix 3: SELinux
    fix_selinux

    # Fix 4: Check and repair PAM
    # Re-run configure_pam if any file differs from what it would write:
    # howdy line missing, older line without the `stdout` flag, line in the
    # wrong position (e.g. before pam_rootok in su), or a leftover line in
    # gdm-fingerprint.
    echo ""
    info "Checking PAM configuration..."
    if pam_config_needs_fix; then
        info "Re-applying PAM configuration (will migrate any old lines)..."
        configure_pam
    else
        success "PAM configuration looks correct"
    fi

    # Fix 5: dlib face recognition model data
    local data_dir="$HOWDY_INSTALL_DIR/dlib-data"
    if [[ -f "$data_dir/dlib_face_recognition_resnet_model_v1.dat" ]] && \
       [[ -f "$data_dir/mmod_human_face_detector.dat" ]] && \
       [[ -f "$data_dir/shape_predictor_5_face_landmarks.dat" ]]; then
        success "dlib face recognition models present"
    else
        install_dlib_data
    fi

    # Fix 6: Enforce critical config values that the v2.6.1 source ships wrong.
    # recording_plugin=opencv fails in PAM context with MJPG cameras (ioctl errors
    # make every frame invalid → timeout → exit 11 → password fallback).
    # end_report=true exposes the winning model label so howdy-auth can print
    # "Recognized as '…'". The timeout is only reset when it is outside the
    # accepted range, so a value set with --set-timeout survives --fix.
    local config="$HOWDY_INSTALL_DIR/config.ini"
    if [[ -f "$config" ]]; then
        local config_changed=false
        _fix_cfg() {
            local section="$1" key="$2" val="$3"
            if grep -qE "^${key}[[:space:]]*=" "$config"; then
                if ! grep -qE "^${key}[[:space:]]*=[[:space:]]*${val}[[:space:]]*$" "$config"; then
                    sed -i -E "s/^${key}[[:space:]]*=.*/${key} = ${val}/" "$config"
                    success "Fixed config: ${key} = ${val}"
                    config_changed=true
                fi
            else
                # configparser keys belong to a section — add under the right header
                if grep -q "^\[${section}\]" "$config"; then
                    sed -i "/^\[${section}\]/a ${key} = ${val}" "$config"
                else
                    printf '\n[%s]\n%s = %s\n' "$section" "$key" "$val" >> "$config"
                fi
                success "Added config: [${section}] ${key} = ${val}"
                config_changed=true
            fi
        }
        _fix_cfg video recording_plugin ffmpeg
        _fix_cfg debug end_report       true
        _fix_cfg core  no_confirmation  true
        local cur_timeout
        cur_timeout=$(sed -nE 's/^timeout[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$config" | head -1)
        if [[ -z "$cur_timeout" ]] || (( cur_timeout < TIMEOUT_MIN || cur_timeout > TIMEOUT_MAX )); then
            _fix_cfg video timeout "$TIMEOUT_DEFAULT"
        fi
        $config_changed || success "Config values already correct"
        unset -f _fix_cfg
    fi

    # Fix 7: Regenerate howdy-auth wrapper (picks up messaging, guard and exit-code fixes)
    if [[ -f "$HOWDY_INSTALL_DIR/compare.py" ]]; then
        ensure_feedback_conf
        write_auth_wrapper
        success "howdy-auth wrapper regenerated"
    fi

    # Fix 8: Verify howdy Python files exist
    if [[ ! -f "$HOWDY_INSTALL_DIR/pam.py" ]]; then
        fail "Howdy not installed at $HOWDY_INSTALL_DIR — reinstalling"
        if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
            info "Non-interactive mode: skipping reinstall prompt"
        else
            read -rp "Reinstall howdy now? (Y/n): " REPLY
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                install_dependencies
                install_howdy
            fi
        fi
    else
        success "Howdy Python files present at $HOWDY_INSTALL_DIR"
    fi

    # Fix 9: Regenerate the uninstaller (picks up new cleanup steps and guards)
    if [[ -f /usr/local/bin/howdy-uninstall ]]; then
        create_uninstaller
    fi

    header "Fix Complete"
    echo "  Run: sudo $0 --diagnose   to verify"

    prompt_gdm_restart
}

# ─── Create Uninstaller ───────────────────────────────────────────────
create_uninstaller() {
    info "Creating uninstaller..."

    cat > /usr/local/bin/howdy-uninstall << 'UNINSTALL_EOF'
#!/bin/bash
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

echo -e "${RED}Howdy Uninstaller${NC}"
echo "This will remove Howdy and restore PAM configuration."
# --setup-keyring gave these users' login keyrings a random password; removing
# the helper without resetting it would leave them with a password they don't know
rekeyed=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $1 ":" $6 }' | \
    while IFS=: read -r u h; do
        [[ -f "$h/.local/share/howdy/keyring.cred" ]] && echo "$u"
    done || true)
if [[ -n "$rekeyed" ]]; then
    echo "Keyring auto-unlock is still set up for: $(echo $rekeyed)"
    echo "First run, from each of those accounts: sudo ./install-howdy.sh --remove-keyring"
    exit 1
fi

read -rp "Continue? (y/N): " REPLY
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

echo "Removing keyring auto-unlock..."
systemctl --global disable howdy-keyring-unlock.service >/dev/null 2>&1 || true
rm -f /etc/systemd/user/howdy-keyring-unlock.service /usr/libexec/howdy-keyring

echo "Removing howdy from PAM files..."
for pam_file in /etc/pam.d/gdm-password /etc/pam.d/gdm-fingerprint \
                /etc/pam.d/gdm-switchable-auth \
                /etc/pam.d/sudo /etc/pam.d/su \
                /etc/pam.d/polkit-1 /etc/pam.d/polkit \
                /etc/pam.d/system-auth; do
    if [[ -f "$pam_file" ]]; then
        if [[ -f "${pam_file}.howdy-backup" ]]; then
            cp "${pam_file}.howdy-backup" "$pam_file"
            rm -f "${pam_file}.howdy-backup"
        else
            sed -i '/pam_exec.*howdy-auth/d' "$pam_file"
        fi
        # Remove any timestamped backup files
        rm -f "${pam_file}".howdy-backup-*
    fi
done

echo "Removing howdy SELinux policies..."
semodule -r howdy_pam 2>/dev/null || true
semodule -r howdy_gdm 2>/dev/null || true

echo "Removing howdy files..."
rm -rf /etc/howdy
rm -rf /var/lib/howdy
rm -rf /var/log/howdy
rm -rf /usr/lib64/security/howdy
rm -f /usr/bin/howdy
rm -f /usr/share/polkit-1/actions/com.github.boltgolt.howdy.policy
rm -f /usr/share/bash-completion/completions/howdy

echo "Removing dlib symlinks..."
for site_dir in $(python3 -c "import site; [print(p) for p in site.getsitepackages()]" 2>/dev/null); do
    [[ -L "$site_dir/dlib" ]] && rm -f "$site_dir/dlib"
    for so in "$site_dir"/_dlib_pybind11*.so; do
        [[ -L "$so" ]] && rm -f "$so"
    done
    for di in "$site_dir"/dlib*.dist-info; do
        [[ -L "$di" ]] && rm -f "$di"
    done
done

rm -f /usr/local/bin/howdy-uninstall

echo -e "${GREEN}Howdy has been completely uninstalled.${NC}"
UNINSTALL_EOF

    chmod +x /usr/local/bin/howdy-uninstall
    success "Uninstaller at /usr/local/bin/howdy-uninstall"
}

# ─── Print Final Summary ──────────────────────────────────────────────
print_summary() {
    header "Installation Complete"

    echo "  Configuration:"
    echo "    Config file : $HOWDY_INSTALL_DIR/config.ini"
    echo "    IR Camera   : $IR_DEVICE ($IR_FORMAT)"
    if [[ -f /etc/howdy/.installed-tag ]]; then
        echo "    Howdy ref   : $(cat /etc/howdy/.installed-tag)"
    fi
    echo ""
    echo "  Howdy Commands:"
    echo "    howdy add          Add a face model"
    echo "    howdy list         List enrolled faces"
    echo "    howdy remove <id>  Remove a face model"
    echo "    sudo $0 --test     Test face recognition (uses ffmpeg plugin)"
    echo "    howdy config       Edit configuration"
    echo "    howdy disable      Temporarily disable"
    echo "    howdy enable       Re-enable"
    echo ""
    echo "  Services with facial authentication:"
    echo "    ✓ GDM (GNOME login & lock screen)"
    echo "    ✓ sudo"
    echo "    ✓ su"
    echo "    ✓ Polkit GUI prompts"
    echo ""
    echo "  Password fallback is always available."
    echo ""
    echo "  Optional — stop the 'Unlock Login Keyring' prompt after face logins:"
    echo "    sudo $0 --setup-keyring"
    echo ""
    echo "  Maintenance:"
    echo "    sudo $0 --diagnose    Check installation health"
    echo "    sudo $0 --fix         Auto-fix common issues"
    echo "    sudo $0 --check-pam   Inspect PAM configuration"
    echo "    sudo howdy-uninstall         Uninstall everything"
    echo ""
}

# ─── Full Install ─────────────────────────────────────────────────────
full_install() {
    header "Howdy Facial Recognition Installer for Fedora  v${SCRIPT_VERSION}"
    echo "  Source: $HOWDY_REPO  (ref: $HOWDY_REF)"
    echo "  Python-based install via pam_exec"
    echo ""

    check_root
    check_supported_system

    install_dependencies

    # Honor previously detected device; re-detect if cache is stale or forced
    if [[ -f /etc/howdy/.detected-device ]] && [[ "${FORCE_DETECT:-0}" != "1" ]]; then
        # shellcheck disable=SC1091
        . /etc/howdy/.detected-device
        if [[ -e "$IR_DEVICE" ]]; then
            info "Using previously detected device: $IR_DEVICE ($IR_FORMAT)"
            info "  (re-run with FORCE_DETECT=1 to re-detect)"
        else
            warn "Cached device $IR_DEVICE no longer exists, re-detecting..."
            detect_ir_camera
        fi
    else
        detect_ir_camera
    fi

    install_howdy
    configure_howdy "$IR_DEVICE" "$IR_FORMAT"
    ensure_feedback_conf
    fix_dlib_symlinks
    configure_pam
    fix_gdm_permissions
    fix_selinux
    create_uninstaller

    # Offer to add face model
    echo ""
    if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        info "Non-interactive mode: skipping face enrollment and test"
    else
        read -rp "Play a sound when a scan starts, matches, or fails? (y/N): " REPLY
        [[ $REPLY =~ ^[Yy]$ ]] && set_sounds on

        read -rp "Add your face model now? (Y/n): " REPLY
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            add_face_model

            echo ""
            read -rp "Test face recognition? (Y/n): " REPLY
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                test_face || warn "Test had issues — run: sudo $0 --diagnose"
            fi
        fi
    fi

    print_summary
    prompt_gdm_restart
}

# ─── Uninstall ────────────────────────────────────────────────────────
do_uninstall() {
    check_root
    if [[ -f /usr/local/bin/howdy-uninstall ]]; then
        /usr/local/bin/howdy-uninstall
    else
        error "Uninstaller not found. Remove manually or reinstall first."
    fi
}

# ─── Interactive Menu ─────────────────────────────────────────────────
show_menu() {
    check_root

    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Howdy Facial Recognition — Fedora Installer  v${SCRIPT_VERSION}${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
    echo ""
    echo "  1)  Full install        Build & configure howdy from source"
    echo "  2)  Diagnose            Check installation health (9-point check)"
    echo "  3)  Auto-fix            Fix common issues (dlib, SELinux, PAM, GDM)"
    echo "  4)  Check PAM           Inspect PAM configuration files"
    echo "  5)  Detect IR camera    Scan for Windows Hello IR sensor"
    echo "  6)  Add face model      Register your face (run multiple times!)"
    echo "  7)  Tune timeout        Adjust scan timeout (4–18s; default 12s)"
    echo "  8)  Test                Test face recognition"
    echo "  9)  Keyring unlock      No keyring prompt after face login (set up / remove)"
    echo " 10)  Uninstall           Remove howdy completely"
    echo " 11)  Help                Show command-line usage"
    echo "  0)  Exit"
    echo ""
    read -rp "  Choose [0-11]: " choice

    case "$choice" in
        1) full_install ;;
        2) diagnose ;;
        3) auto_fix ;;
        4) check_pam ;;
        5) detect_ir_camera ;;
        6) add_face_model ;;
        7) tune_timeout ;;
        8)
            if [[ -f "$HOWDY_INSTALL_DIR/compare.py" ]]; then
                test_face
            else
                fail "Howdy is not installed. Choose option 1 first."
            fi
            ;;
        9) keyring_menu ;;
        10) do_uninstall ;;
        11) show_help ;;
        0) exit 0 ;;
        *) error "Invalid choice: $choice" ;;
    esac
}

# ─── Help Text ────────────────────────────────────────────────────────
show_help() {
    echo "Howdy Facial Recognition Installer for Fedora  v${SCRIPT_VERSION}"
    echo ""
    echo "Usage: sudo $0 [--non-interactive|-y] [OPTION]"
    echo ""
    echo "Options:"
    echo "  (none)              Interactive menu"
    echo "  --install           Full installation (skip menu)"
    echo "  --diagnose          Check installation health"
    echo "  --fix               Auto-fix common issues"
    echo "  --check-pam         Inspect PAM configuration"
    echo "  --detect-ir         Detect IR camera only"
    echo "  --add-face          Register a face model"
    echo "  --tune-timeout      Interactively adjust scan timeout (4–18s)"
    echo "  --set-timeout N     Set scan timeout to N seconds (4–18, no prompt)"
    echo "  --test              Test face recognition (works with ffmpeg plugin)"
    echo "  --sounds on|off     Play a sound when a scan starts, matches, or fails"
    echo "  --preview [OUTCOME] Play the scan messages without the camera"
    echo "                      (OUTCOME: success, fail, dark, noface, error)"
    echo "  --setup-keyring     Unlock the GNOME login keyring automatically after face login"
    echo "  --remove-keyring    Undo --setup-keyring and reset the keyring password"
    echo "  --uninstall         Remove howdy completely"
    echo "  --non-interactive   Skip all interactive prompts (alias: -y)"
    echo "  --help              Show this help"
    echo ""
    echo "Environment overrides:"
    echo "  HOWDY_REF=<tag>     Pin to a specific howdy git ref (default: v2.6.1)"
    echo "  FORCE_DETECT=1      Ignore cached IR device and re-detect"
}

# ─── Main Entrypoint ─────────────────────────────────────────────────
# Parse --non-interactive / -y before dispatching
while [[ "${1:-}" =~ ^(--non-interactive|-y)$ ]]; do
    NON_INTERACTIVE=1
    shift
done

case "${1:-}" in
    --install)
        full_install
        ;;
    --diagnose|--diag)
        check_root
        diagnose
        ;;
    --fix)
        auto_fix
        ;;
    --check-pam|--pam)
        check_root
        check_pam
        ;;
    --detect-ir|--detect)
        check_root
        detect_ir_camera
        ;;
    --add-face|--add)
        check_root
        add_face_model
        ;;
    --tune-timeout)
        check_root
        tune_timeout
        ;;
    --set-timeout)
        check_root
        if [[ -z "${2:-}" ]]; then
            error "--set-timeout requires a value (4–18). Example: --set-timeout 8"
        fi
        tune_timeout "$2"
        ;;
    --test)
        check_root
        test_face
        ;;
    --preview)
        preview_messages "${2:-}"
        ;;
    --sounds)
        check_root
        set_sounds "${2:-}"
        ;;
    --setup-keyring)
        check_root
        setup_keyring
        ;;
    --remove-keyring)
        check_root
        remove_keyring
        ;;
    --uninstall|--remove)
        do_uninstall
        ;;
    --help|-h)
        show_help
        ;;
    "")
        show_menu
        ;;
    *)
        error "Unknown option: $1 (use --help for usage)"
        ;;
esac
