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
HOWDY_REF="${HOWDY_REF:-v3.2.1}"   # override with HOWDY_REF=master to track upstream
SCRIPT_VERSION="1.1.0"

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
        opencv-devel \
        v4l-utils \
        cmake \
        make \
        gcc \
        gcc-c++ \
        pam-devel \
        inih-devel \
        libevdev-devel \
        git \
        meson \
        ninja-build \
        gtk3-devel \
        polkit-devel \
        policycoreutils-python-utils \
        audit 2>&1 | tail -5

    # Install dlib via pip (Fedora doesn't ship a compatible python3-dlib RPM)
    info "Installing dlib via pip..."
    pip3 install dlib --break-system-packages 2>&1 | tail -3 || pip3 install dlib 2>&1 | tail -3

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

# ─── Build & Install Howdy from Source ───────────────────────────────
install_howdy() {
    header "Building Howdy from Source"

    local howdy_dir
    howdy_dir=$(mktemp -d -t howdy-install-XXXXXX)
    trap 'rm -rf "$howdy_dir"' RETURN

    info "Cloning howdy repository (ref: $HOWDY_REF)..."
    git clone "$HOWDY_REPO" "$howdy_dir" 2>&1 | tail -3
    git -C "$howdy_dir" checkout "$HOWDY_REF" 2>&1 | tail -3
    info "Building from commit $(git -C "$howdy_dir" rev-parse --short HEAD)"

    cd "$howdy_dir"

    info "Configuring build..."
    meson setup build --prefix=/usr -Dlibdir=lib64

    info "Compiling..."
    meson compile -C build

    info "Installing..."
    meson install -C build

    # Verify pam_howdy.so was built
    if [[ -f /usr/lib64/security/pam_howdy.so ]]; then
        success "pam_howdy.so installed at /usr/lib64/security/pam_howdy.so"
    elif [[ -f /usr/lib/security/pam_howdy.so ]]; then
        success "pam_howdy.so installed at /usr/lib/security/pam_howdy.so"
    else
        error "pam_howdy.so was not built! Check meson build output above."
    fi

    if command -v howdy &>/dev/null; then
        success "howdy command available"
    else
        warn "howdy command not found in PATH"
    fi

    # Record what was installed so --diagnose can report it
    mkdir -p /etc/howdy
    git -C "$howdy_dir" rev-parse HEAD > /etc/howdy/.installed-ref
    echo "$HOWDY_REF" > /etc/howdy/.installed-tag

    cd /
    success "Howdy built and installed from source"

    install_dlib_data
}

# ─── Download dlib Face Recognition Data ─────────────────────────────
install_dlib_data() {
    header "Downloading Face Recognition Models"

    local data_dir="/usr/share/dlib-data"

    if [[ -f "$data_dir/dlib_face_recognition_resnet_model_v1.dat" ]] && \
       [[ -f "$data_dir/mmod_human_face_detector.dat" ]] && \
       [[ -f "$data_dir/shape_predictor_5_face_landmarks.dat" ]]; then
        success "dlib face recognition models already downloaded"
        return
    fi

    if [[ -f "$data_dir/install.sh" ]]; then
        info "Running dlib data installer..."
        cd "$data_dir"
        bash ./install.sh
        cd /
        success "Face recognition models downloaded"
    else
        info "Downloading face recognition models manually..."
        mkdir -p "$data_dir"

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

        success "Face recognition models downloaded"
    fi
}

# ─── Configure Howdy ─────────────────────────────────────────────────
configure_howdy() {
    local ir_device="$1"
    local ir_format="${2:-YUYV}"

    header "Configuring Howdy"

    mkdir -p /etc/howdy

    if [[ -f /etc/howdy/config.ini ]] && [[ ! -f /etc/howdy/config.ini.pre-install ]]; then
        cp /etc/howdy/config.ini /etc/howdy/config.ini.pre-install
    fi

    if [[ -f /etc/howdy/config.ini ]]; then
        sed -i "s|^device_path.*|device_path = $ir_device|" /etc/howdy/config.ini
        sed -i "s|^device_format.*|device_format = $ir_format|" /etc/howdy/config.ini
        sed -i 's|^dark_threshold.*|dark_threshold = 60|' /etc/howdy/config.ini
        sed -i 's|^certainty.*|certainty = 3.5|' /etc/howdy/config.ini
        sed -i 's|^timeout.*|timeout = 4|' /etc/howdy/config.ini
    else
        cat > /etc/howdy/config.ini << EOF
[core]
detection_notice = true
abort_if_lid_closed = true
no_confirmation = false

[video]
device_path = $ir_device
device_format = $ir_format
max_height = 480
max_width = 640
rotate = 0
hflip = false
vflip = false
exposure = -1
frame_scale = 1

[detection]
certainty = 3.5
contiguous_count = 2
timeout = 4
dark_threshold = 60
retry_delay = 0.05

[snapshots]
save_failed = false
save_successful = false
snapshots_path = /var/log/howdy/snapshots
EOF
    fi

    success "Howdy config: device=$ir_device format=$ir_format"
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

    local PAM_LINE="auth        sufficient    pam_howdy.so"

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

        if grep -q "pam_howdy.so" "$pam_file"; then
            success "$label — already configured"
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
        howdy_count=$(grep -c "pam_howdy.so" "$tmpfile" || true)

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

    # Polkit GUI prompts (Fedora uses different names across versions)
    if [[ -f "/etc/pam.d/polkit-1" ]]; then
        add_howdy_to_pam "/etc/pam.d/polkit-1" "Polkit GUI prompts"
    elif [[ -f "/etc/pam.d/polkit" ]]; then
        add_howdy_to_pam "/etc/pam.d/polkit" "Polkit GUI prompts"
    else
        warn "Polkit PAM file not found (neither polkit-1 nor polkit)"
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

    local pam_module=""
    if [[ -f /usr/lib64/security/pam_howdy.so ]]; then
        pam_module="/usr/lib64/security/pam_howdy.so"
    elif [[ -f /usr/lib/security/pam_howdy.so ]]; then
        pam_module="/usr/lib/security/pam_howdy.so"
    fi

    if [[ -n "$pam_module" ]]; then
        success "PAM module found: $pam_module"
    else
        fail "pam_howdy.so not found! Howdy needs to be built from source."
        echo "  Run: sudo $0   (full install)"
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

        if [[ ! -f "$file" ]]; then
            echo -e "  ${YELLOW}—${NC} $label: file not found"
            continue
        fi

        if grep -q "pam_howdy.so" "$file"; then
            local howdy_line
            howdy_line=$(grep -n "pam_howdy.so" "$file" | head -1 | cut -d: -f1)
            local first_other_auth
            first_other_auth=$(grep -n "^auth" "$file" | grep -v "pam_howdy" | head -1 | cut -d: -f1)

            if [[ -n "$howdy_line" ]] && [[ -n "$first_other_auth" ]] && [[ "$howdy_line" -lt "$first_other_auth" ]]; then
                echo -e "  ${GREEN}✓${NC} $label: howdy on line $howdy_line (before other auth)"
            elif [[ -n "$howdy_line" ]]; then
                echo -e "  ${YELLOW}⚠${NC} $label: howdy present but may be in wrong position"
            fi
        else
            echo -e "  ${RED}✗${NC} $label: howdy NOT configured"
        fi
    done

    echo ""
    echo -e "${BOLD}Auth lines in key PAM files:${NC}"
    for file in /etc/pam.d/gdm-password /etc/pam.d/sudo; do
        if [[ -f "$file" ]]; then
            echo -e "\n  ${CYAN}$file:${NC}"
            grep "^auth" "$file" | while IFS= read -r line; do
                if echo "$line" | grep -q "pam_howdy"; then
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

    if [[ -f /usr/lib64/security/pam_howdy.so ]]; then
        success "pam_howdy.so found (native C++ module)"
    elif [[ -f /usr/lib/security/pam_howdy.so ]]; then
        success "pam_howdy.so found at /usr/lib/security/"
    else
        fail "pam_howdy.so NOT found — PAM cannot use howdy"
        echo "  Fix: Rebuild from source with: sudo $0"
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
    if [[ -f /etc/howdy/config.ini ]]; then
        config_device=$(grep "^device_path" /etc/howdy/config.ini 2>/dev/null | sed 's/.*= *//')
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
    local data_dir="/usr/share/dlib-data"
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
        echo "  Fix: cd /usr/share/dlib-data && sudo ./install.sh"
        echo "  Or:  sudo $0 --fix"
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
    echo ""
    info "Checking PAM configuration..."
    local needs_pam_fix=false
    for file in /etc/pam.d/gdm-password /etc/pam.d/sudo /etc/pam.d/su; do
        if [[ -f "$file" ]] && ! grep -q "pam_howdy.so" "$file"; then
            needs_pam_fix=true
            break
        fi
    done

    if $needs_pam_fix; then
        info "Re-applying PAM configuration..."
        configure_pam
    else
        success "PAM configuration looks correct"
    fi

    # Fix 5: dlib face recognition model data
    local data_dir="/usr/share/dlib-data"
    if [[ -f "$data_dir/dlib_face_recognition_resnet_model_v1.dat" ]] && \
       [[ -f "$data_dir/mmod_human_face_detector.dat" ]] && \
       [[ -f "$data_dir/shape_predictor_5_face_landmarks.dat" ]]; then
        success "dlib face recognition models present"
    else
        install_dlib_data
    fi

    # Fix 6: Verify pam_howdy.so exists
    if [[ ! -f /usr/lib64/security/pam_howdy.so ]] && [[ ! -f /usr/lib/security/pam_howdy.so ]]; then
        fail "pam_howdy.so is missing — howdy needs to be rebuilt from source"
        if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
            info "Non-interactive mode: skipping rebuild prompt"
        else
            read -rp "Rebuild howdy now? (Y/n): " REPLY
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                install_dependencies
                install_howdy
            fi
        fi
    else
        success "pam_howdy.so is present"
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
            sed -i '/pam_howdy.so/d' "$pam_file"
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
rm -f /usr/lib64/security/pam_howdy.so
rm -f /usr/lib/security/pam_howdy.so
rm -rf /usr/lib64/howdy
rm -rf /usr/lib/howdy
rm -f /usr/bin/howdy

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
    echo "  Builds from source with native PAM module"
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
    echo "  HOWDY_REF=<tag>     Pin to a specific howdy git ref (default: v3.2.1)"
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
