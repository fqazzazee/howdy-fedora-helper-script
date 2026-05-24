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
SCRIPT_VERSION="1.2.1"

# ─── Global state ────────────────────────────────────────────────────
NEEDS_GDM_RESTART=false
NON_INTERACTIVE=0
DM_TYPE="none"
IR_DEVICE=""
IR_FORMAT=""

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

# ─── Install Howdy from Source ───────────────────────────────────────
install_howdy() {
    header "Installing Howdy from Source"

    local howdy_dir
    howdy_dir=$(mktemp -d -t howdy-install-XXXXXX)
    trap 'rm -rf "$howdy_dir"' RETURN

    info "Cloning howdy repository (ref: $HOWDY_REF)..."
    git clone "$HOWDY_REPO" "$howdy_dir" 2>&1 | tail -3
    git -C "$howdy_dir" checkout "$HOWDY_REF" 2>&1 | tail -3
    info "Installing from commit $(git -C "$howdy_dir" rev-parse --short HEAD)"

    # Install Python files
    rm -rf "$HOWDY_INSTALL_DIR"
    mkdir -p "$HOWDY_INSTALL_DIR"
    cp -r "$howdy_dir/src/." "$HOWDY_INSTALL_DIR/"

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

    # PAM exec wrapper — calls compare.py with PAM_USER from environment.
    # Prints the scan result to stdout (relayed to the calling application by
    # pam_exec.so's `stdout` flag, so sudo/GDM/polkit display it inline) and
    # also writes to the system journal. Exit codes are normalised to 0
    # (success) or 1 (failure) so pam_exec.so always gets a clean result
    # regardless of compare.py's internal codes (10=no model, 11=timeout,
    # 13=too dark, etc.).
    cat > "$HOWDY_INSTALL_DIR/howdy-auth" << 'EOF'
#!/bin/bash
[[ -z "${PAM_USER}" ]] && exit 1

_notify() {
    echo "$1"
    command -v logger &>/dev/null && logger -t howdy "$1" 2>/dev/null
}

output=$(/usr/bin/python3 /usr/lib64/security/howdy/compare.py "${PAM_USER}" 2>&1)
rc=$?

if [ "$rc" -eq 0 ]; then
    # compare.py prints 'Winning model: N ("label")' when end_report=true
    label=$(printf '%s\n' "$output" \
        | grep -oE 'Winning model: [0-9]+ \("[^"]+"\)' \
        | grep -oE '"[^"]+"' \
        | tr -d '"' \
        | head -1)
    if [ -n "$label" ]; then
        _notify "Howdy: Recognized '${label}' for ${PAM_USER} — access granted"
    else
        _notify "Howdy: Face recognized for ${PAM_USER} — access granted"
    fi
    exit 0
else
    _notify "Howdy: Face not recognized for ${PAM_USER} — falling back to password"
    exit 1
fi
EOF
    chmod +x "$HOWDY_INSTALL_DIR/howdy-auth"

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
    sed -i "s/^timeout.*/timeout = 12/" "$config"
    # end_report=true makes compare.py print the winning model label on success,
    # which howdy-auth captures and re-emits as the "recognized as" message.
    sed -i "s/^end_report.*/end_report = true/" "$config"
    sed -i "s/^no_confirmation.*/no_confirmation = true/" "$config"

    success "Howdy config: device=$ir_device format=$ir_format (ffmpeg plugin)"
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

    # `stdout` flag relays the wrapper's stdout to the calling application
    # (sudo/GDM/polkit) as PAM_TEXT_INFO messages, so the user sees the
    # face-scan result inline. `quiet` suppresses pam_exec's own syslog noise.
    local PAM_LINE="auth        sufficient    pam_exec.so quiet stdout ${HOWDY_INSTALL_DIR}/howdy-auth"

    add_howdy_to_pam() {
        local pam_file="$1"
        local label="$2"

        if [[ ! -f "$pam_file" ]]; then
            warn "$label: file not found ($pam_file)"
            return 1
        fi

        # Timestamped backup on every call (forensic trail)
        local ts_backup="${pam_file}.howdy-backup-$(date +%Y%m%d-%H%M%S)"
        cp -a "$pam_file" "$ts_backup"

        # Permanent backup the uninstaller restores from (only if not yet present)
        if [[ ! -f "${pam_file}.howdy-backup" ]]; then
            cp -a "$pam_file" "${pam_file}.howdy-backup"
        fi

        if grep -qE "pam_exec.*howdy-auth" "$pam_file"; then
            # Migrate older lines that lack the `stdout` flag, which is what
            # makes the wrapper's "Recognized / Not recognized" message visible
            # to the user during the auth prompt.
            if grep -E "pam_exec.*howdy-auth" "$pam_file" | grep -qv stdout; then
                awk -v new="$PAM_LINE" '
                    /howdy-auth/ { print new; next }
                    { print }
                ' "$pam_file" > "${pam_file}.howdy-migrate" && \
                    mv "${pam_file}.howdy-migrate" "$pam_file"
                success "$label — upgraded (added stdout flag for visible scan messages)"
                [[ "$pam_file" =~ gdm- ]] && NEEDS_GDM_RESTART=true
            else
                success "$label — already configured"
            fi
            return 0
        fi

        # Stage in a sibling tempfile (same FS guarantees atomic mv)
        local tmpfile
        tmpfile=$(mktemp "${pam_file}.howdy-staging-XXXX")
        chmod --reference="$pam_file" "$tmpfile" 2>/dev/null || chmod 0644 "$tmpfile"

        if grep -q "^auth" "$pam_file"; then
            awk -v line="$PAM_LINE" '
                !inserted && /^auth/ { print line; inserted=1 }
                { print }
            ' "$pam_file" > "$tmpfile"
        else
            { echo "$PAM_LINE"; cat "$pam_file"; } > "$tmpfile"
        fi

        # Validate: original auth line count preserved, exactly one howdy entry added
        local orig_auth new_auth howdy_count
        orig_auth=$(grep -c "^auth" "$pam_file" || true)
        new_auth=$(grep -c "^auth" "$tmpfile" || true)
        howdy_count=$(grep -cE "pam_exec.*howdy-auth" "$tmpfile" || true)

        if (( new_auth != orig_auth + 1 )) || (( howdy_count != 1 )); then
            fail "$label — validation failed (auth: $orig_auth → $new_auth, howdy: $howdy_count)"
            rm -f "$tmpfile"
            return 1
        fi

        # Atomic commit
        mv "$tmpfile" "$pam_file"
        success "$label — configured"

        if [[ "$pam_file" =~ gdm- ]]; then
            NEEDS_GDM_RESTART=true
        fi
    }

    # GDM (GNOME login and lock screen) — only when GDM is active
    if [[ "${DM_TYPE:-}" == "gdm" ]]; then
        add_howdy_to_pam "/etc/pam.d/gdm-password" "GDM login/unlock"
        add_howdy_to_pam "/etc/pam.d/gdm-fingerprint" "GDM fingerprint"
    fi

    # Shell access
    add_howdy_to_pam "/etc/pam.d/sudo" "sudo"
    add_howdy_to_pam "/etc/pam.d/su" "su"

    # Polkit GUI prompts — Fedora 44+ ships polkit-1 to /usr/lib/pam.d/ rather
    # than /etc/pam.d/; copy it as a local override before modifying.
    if [[ -f "/etc/pam.d/polkit-1" ]]; then
        add_howdy_to_pam "/etc/pam.d/polkit-1" "Polkit GUI prompts"
    elif [[ -f "/etc/pam.d/polkit" ]]; then
        add_howdy_to_pam "/etc/pam.d/polkit" "Polkit GUI prompts"
    elif [[ -f "/usr/lib/pam.d/polkit-1" ]]; then
        cp /usr/lib/pam.d/polkit-1 /etc/pam.d/polkit-1
        add_howdy_to_pam "/etc/pam.d/polkit-1" "Polkit GUI prompts"
    else
        warn "Polkit PAM file not found (checked /etc/pam.d/ and /usr/lib/pam.d/)"
    fi

    success "PAM configuration complete"
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
        if ausearch -m avc -ts today 2>/dev/null | audit2allow -M howdy_gdm 2>/dev/null && \
           semodule -i howdy_gdm.pp 2>/dev/null; then
            success "SELinux policy installed from audit log (howdy_gdm)"
            NEEDS_GDM_RESTART=true
        else
            warn "Could not install audit-based SELinux policy"
        fi
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

    if semodule -l 2>/dev/null | grep -q "howdy_pam"; then
        success "howdy_pam SELinux policy already installed"
        return
    fi

    # Locate policy source shipped alongside the script
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local policy_te="$script_dir/selinux/howdy_pam.te"

    if [[ ! -f "$policy_te" ]]; then
        warn "Policy source not found at $policy_te"
        warn "Falling back to audit-based generation"
        _selinux_audit_fallback
        return
    fi

    info "Building SELinux policy from $policy_te"

    local policy_dir
    policy_dir=$(mktemp -d -t howdy-selinux-XXXXXX)
    trap 'rm -rf "$policy_dir"' RETURN

    cp "$policy_te" "$policy_dir/howdy_pam.te"
    cd "$policy_dir"

    if checkmodule -M -m -o howdy_pam.mod howdy_pam.te 2>/dev/null && \
       semodule_package -o howdy_pam.pp -m howdy_pam.mod 2>/dev/null && \
       semodule -i howdy_pam.pp 2>/dev/null; then
        success "SELinux policy installed (howdy_pam)"
        NEEDS_GDM_RESTART=true
    else
        warn "Pre-built policy failed — trying audit-based fallback"
        _selinux_audit_fallback
    fi

    cd /
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
    read -rp "  Press Enter when ready..."
    echo ""
    warn "Note: 'ioctl(VIDIOC_QBUF): Bad file descriptor' may appear — this is harmless OpenCV noise with MJPG cameras and does not affect capture."
    echo ""

    howdy add -U "$actual_user" || {
        fail "Face registration failed"
        echo ""
        echo "  Troubleshooting:"
        echo "    - Run: sudo $0 --diagnose"
        echo "    - Check camera: sudo howdy test"
        echo "    - Edit config: sudo howdy config"
        return 1
    }

    success "Face model added for user: $actual_user"
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

        if grep -qE "pam_exec.*howdy-auth" "$effective_file"; then
            local howdy_line
            howdy_line=$(grep -nE "pam_exec.*howdy-auth" "$effective_file" | head -1 | cut -d: -f1)
            local first_other_auth
            first_other_auth=$(grep -n "^auth" "$effective_file" | grep -vE "pam_exec.*howdy-auth" | head -1 | cut -d: -f1)

            local has_stdout=""
            if grep -E "pam_exec.*howdy-auth" "$effective_file" | grep -q stdout; then
                has_stdout=" [stdout: scan result visible to user]"
            else
                has_stdout=" ${YELLOW}[no stdout flag — scan result hidden; run --fix to upgrade]${NC}"
            fi

            if [[ -n "$howdy_line" ]] && [[ -n "$first_other_auth" ]] && [[ "$howdy_line" -lt "$first_other_auth" ]]; then
                echo -e "  ${GREEN}✓${NC} $label: howdy on line $howdy_line (before other auth)${has_stdout}"
            elif [[ -n "$howdy_line" ]]; then
                echo -e "  ${YELLOW}⚠${NC} $label: howdy present but may be in wrong position${has_stdout}"
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
        ((issues++))
    fi

    if [[ -f "$HOWDY_INSTALL_DIR/pam.py" ]]; then
        success "Howdy Python files found at $HOWDY_INSTALL_DIR"
    else
        fail "Howdy not installed at $HOWDY_INSTALL_DIR"
        echo "  Fix: Reinstall with: sudo $0"
        ((issues++))
    fi

    if [[ -f "$HOWDY_INSTALL_DIR/howdy-auth" ]]; then
        success "howdy-auth wrapper found: $HOWDY_INSTALL_DIR/howdy-auth"
    else
        fail "howdy-auth wrapper missing — reinstall with: sudo $0"
        ((issues++))
    fi

    if [[ -f /usr/lib64/security/pam_exec.so ]] || [[ -f /usr/lib/security/pam_exec.so ]]; then
        success "pam_exec.so available"
    else
        fail "pam_exec.so not found (part of the pam package)"
        ((issues++))
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
        ((issues++))
    fi

    if id gdm &>/dev/null; then
        if sudo -u gdm python3 -c "import dlib" 2>/dev/null; then
            success "dlib imports OK as gdm user"
        else
            fail "gdm user cannot import dlib (GDM unlock will fail)"
            echo "  Fix: sudo $0 --fix"
            ((issues++))
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
                ((issues++))
            fi
        else
            fail "Device $config_device does not exist!"
            echo "  Fix: sudo $0 --detect-ir, then edit /etc/howdy/config.ini"
            ((issues++))
        fi
    else
        fail "No device configured in /etc/howdy/config.ini"
        ((issues++))
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
            ((issues++))
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
            ((issues++))
        fi

        local recent_denials
        recent_denials=$(ausearch -m avc -ts recent 2>/dev/null | grep -ciE "howdy|xdm.*video" || true)
        if [[ "$recent_denials" -gt 0 ]]; then
            fail "Found $recent_denials recent SELinux denial(s) related to howdy/GDM"
            echo "  Fix: sudo $0 --fix"
            ((issues++))
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
            ((issues++))
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
            ((issues++))
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
    # Re-run configure_pam if any expected file is either missing the howdy
    # line entirely OR has an older line without the `stdout` flag (which is
    # what makes the scan result visible to the user).
    echo ""
    info "Checking PAM configuration..."
    local needs_pam_fix=false
    for file in /etc/pam.d/gdm-password /etc/pam.d/sudo /etc/pam.d/su /etc/pam.d/polkit-1; do
        [[ -f "$file" ]] || continue
        if ! grep -qE "pam_exec.*howdy-auth" "$file"; then
            needs_pam_fix=true
            break
        fi
        if grep -E "pam_exec.*howdy-auth" "$file" | grep -qv stdout; then
            needs_pam_fix=true
            break
        fi
    done

    if $needs_pam_fix; then
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
    # timeout=4 is too short for cold-start PAM; end_report=true exposes the
    # winning model label so howdy-auth can print "Recognized as '…'".
    local config="$HOWDY_INSTALL_DIR/config.ini"
    if [[ -f "$config" ]]; then
        local config_changed=false
        _fix_cfg() {
            local key="$1" val="$2"
            if grep -q "^${key}" "$config"; then
                if ! grep -q "^${key} = ${val}$" "$config"; then
                    sed -i "s/^${key}.*/${key} = ${val}/" "$config"
                    success "Fixed config: ${key} = ${val}"
                    config_changed=true
                fi
            else
                echo "${key} = ${val}" >> "$config"
                success "Added config: ${key} = ${val}"
                config_changed=true
            fi
        }
        _fix_cfg recording_plugin ffmpeg
        _fix_cfg timeout          12
        _fix_cfg end_report       true
        _fix_cfg no_confirmation  true
        $config_changed || success "Config values already correct"
        unset -f _fix_cfg
    fi

    # Fix 7: Regenerate howdy-auth wrapper (picks up messaging and exit-code fixes)
    if [[ -f "$HOWDY_INSTALL_DIR/howdy-auth" ]]; then
        cat > "$HOWDY_INSTALL_DIR/howdy-auth" << 'AUTHEOF'
#!/bin/bash
[[ -z "${PAM_USER}" ]] && exit 1

_notify() {
    echo "$1"
    command -v logger &>/dev/null && logger -t howdy "$1" 2>/dev/null
}

output=$(/usr/bin/python3 /usr/lib64/security/howdy/compare.py "${PAM_USER}" 2>&1)
rc=$?

if [ "$rc" -eq 0 ]; then
    # compare.py prints 'Winning model: N ("label")' when end_report=true
    label=$(printf '%s\n' "$output" \
        | grep -oE 'Winning model: [0-9]+ \("[^"]+"\)' \
        | grep -oE '"[^"]+"' \
        | tr -d '"' \
        | head -1)
    if [ -n "$label" ]; then
        _notify "Howdy: Recognized '${label}' for ${PAM_USER} — access granted"
    else
        _notify "Howdy: Face recognized for ${PAM_USER} — access granted"
    fi
    exit 0
else
    _notify "Howdy: Face not recognized for ${PAM_USER} — falling back to password"
    exit 1
fi
AUTHEOF
        chmod +x "$HOWDY_INSTALL_DIR/howdy-auth"
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
read -rp "Continue? (y/N): " REPLY
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

echo "Removing howdy from PAM files..."
for pam_file in /etc/pam.d/gdm-password /etc/pam.d/gdm-fingerprint \
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
    echo "    Config file : /etc/howdy/config.ini"
    echo "    IR Camera   : $IR_DEVICE ($IR_FORMAT)"
    if [[ -f /etc/howdy/.installed-tag ]]; then
        echo "    Howdy ref   : $(cat /etc/howdy/.installed-tag)"
    fi
    echo ""
    echo "  Howdy Commands:"
    echo "    howdy add          Add a face model"
    echo "    howdy list         List enrolled faces"
    echo "    howdy remove <id>  Remove a face model"
    echo "    howdy test         Test face recognition"
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
        read -rp "Add your face model now? (Y/n): " REPLY
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            add_face_model

            echo ""
            read -rp "Test face recognition? (Y/n): " REPLY
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                howdy test || warn "Test had issues — run: sudo $0 --diagnose"
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
    echo "  2)  Diagnose            Check installation health (8-point check)"
    echo "  3)  Auto-fix            Fix common issues (dlib, SELinux, PAM, GDM)"
    echo "  4)  Check PAM           Inspect PAM configuration files"
    echo "  5)  Detect IR camera    Scan for Windows Hello IR sensor"
    echo "  6)  Add face model      Register your face"
    echo "  7)  Test                Test face recognition"
    echo "  8)  Uninstall           Remove howdy completely"
    echo "  9)  Help                Show command-line usage"
    echo "  0)  Exit"
    echo ""
    read -rp "  Choose [0-9]: " choice

    case "$choice" in
        1) full_install ;;
        2) diagnose ;;
        3) auto_fix ;;
        4) check_pam ;;
        5) detect_ir_camera ;;
        6) add_face_model ;;
        7)
            if command -v howdy &>/dev/null; then
                howdy test
            else
                fail "Howdy is not installed. Choose option 1 first."
            fi
            ;;
        8) do_uninstall ;;
        9) show_help ;;
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
