# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.1.0 Robustness & UX Improvements

### Added

- `--non-interactive` / `-y` flag for unattended deployments (Kickstart, Ansible)
- OS and display manager version gate: enforces Fedora 40+, detects and warns on non-GDM setups (SDDM, LightDM), skips GDM-specific steps accordingly
- Interactive IR camera disambiguation — when multiple IR candidates are found, lists each with card name and format details and prompts the user to choose; detected device cached in `/etc/howdy/.detected-device` (bypass with `FORCE_DETECT=1`)
- Consolidated GDM restart prompt at the end of install/fix — replaces scattered reminder messages; skipped automatically in `--non-interactive` mode
- `SCRIPT_VERSION` constant (`1.1.0`) printed in the interactive menu header
- SELinux policy extracted to `selinux/howdy_pam.te` alongside the script; audit-log fallback used automatically if the file is missing
- Timestamped PAM backup files (`*.howdy-backup-YYYYMMDD-HHMMSS`) preserved on every install for a forensic trail alongside the permanent rollback backup
- Installer records the pinned ref in `/etc/howdy/.installed-tag` and `/etc/howdy/.installed-ref`; `--diagnose` displays these

### Changed

- Howdy is now cloned at a pinned tagged release (configurable via `HOWDY_REF` env var; default verified tag); override with `HOWDY_REF=master` to track upstream
- Build temp directory (`/tmp/howdy-install-*`) and SELinux temp directory (`/tmp/howdy-selinux-*`) use `mktemp` + `trap RETURN` for guaranteed cleanup on both success and failure
- PAM edits are staged in a sibling tempfile, validated (auth-line count, single howdy entry), then committed atomically via `mv`; validation failure rolls back automatically
- Diagnose menu entry corrected from "7-point" to "8-point"

### Fixed

- Temp directories no longer linger when `meson` or another build step fails mid-run
- PAM configuration is now idempotent: re-running `--fix` on an already-configured file is a safe no-op

---

## [1.0.0] - 2026-01-31

### Added

- Initial release of Howdy Fedora Helper Script
- Interactive menu with 9 options (install, diagnose, fix, check-pam, detect-ir, add-face, test, uninstall, help)
- Automatic IR camera detection by scanning pixel formats (GREY, YUYV, MJPG)
- Source build of Howdy with native `pam_howdy.so` PAM module
- Automatic download of dlib face recognition neural network models
- dlib symlink creation for system-wide Python accessibility
- GDM video group configuration for lock screen camera access
- SELinux policy generation and installation for Fedora
- PAM configuration for GDM, sudo, su, and polkit
- 8-point diagnostic health check
- Auto-fix mode for common issues
- Clean uninstaller that preserves pip-installed dlib
- Comprehensive manual (HOWDY-MANUAL.md)
- Command-line flags for non-interactive use

### Fixed

- COPR package dependency on Python 2.7 (bypassed via source build)
- dlib import failures due to pip vs system site-packages mismatch
- GDM lock screen failures due to missing video group membership
- SELinux denials blocking GDM camera access (`xdm_t` to `v4l_device_t`)
- Face model detection in diagnostics matching actual `howdy list` output format

### Notes

- Tested on Fedora Workstation 43 with GNOME 49
- Tested on ASUS Zenbook with Windows Hello IR camera
- Has been working for over 4 months before the initial public release v1.0.0
- Requires internet connection for initial setup (howdy source + dlib models)
