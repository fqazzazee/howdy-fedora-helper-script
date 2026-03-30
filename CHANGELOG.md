# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
