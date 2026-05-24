# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.3] - 2026-05-24 — Fix Test option for ffmpeg recorder

### Fixed

- Menu option 8 ("Test") and the post-install "Test face recognition?" prompt called `howdy test`, which upstream v2.6.1 hard-rejects whenever `recording_plugin != opencv` (prints "Howdy has been configured to use a recorder which doesn't support the test command yet" and aborts). Since v1.2.0 ships `recording_plugin = ffmpeg` (opencv fails in PAM context on Fedora MJPG IR cameras with `ioctl(VIDIOC_QBUF): Bad file descriptor`), the test path was broken on every install. Replaced with a direct `compare.py $USER` invocation that exercises the same code path PAM uses via `howdy-auth` — same plugin, same config, same model dir, so a pass mirrors real auth

### Added

- `test_face()` helper: validates compare.py and the user's enrolled model exist, times the scan, prints the winning model label (`😊 Recognized as 'label' in Ns`) on success or the compare.py exit code with a hint table (10 = no model, 11 = timeout, 12 = no face detected, 13 = too dark) on failure
- `--test` CLI flag for unattended/scripted runs

### Changed

- Stale `sudo howdy test` references replaced with `sudo install-howdy.sh --test` in the post-install summary and the `add_face_model` troubleshooting hint

---

## [1.2.2] - 2026-05-24 — Tunable timeout, multi-face guidance, doc polish

### Added

- **Tunable scan timeout** (option 7 in the menu, `--tune-timeout` interactively, or `--set-timeout N` for unattended use). Valid range 4–18 seconds; rejects out-of-range values with a clear error. Persists to `/usr/lib64/security/howdy/config.ini` and takes effect on the next auth attempt — no restart needed
- **Multi-face enrollment guidance** in `add_face_model()`: prominent prompt during enrollment recommending multiple models (with/without glasses, varied lighting, slight angle changes) for accuracy, and post-enrollment tip pointing to `howdy list` and the option to re-run for additional models
- **Beautified scan-result messages** — the wrapper now prefixes the verbose `Howdy: …` line with a friendly emoji line (`😊 Welcome back, <user>! ✨` on success, `🤔 Hmm, that doesn't look like <user>…` on failure) that appears inline in sudo/GDM/polkit prompts. Both the structured log line and the emoji line go to stdout and `journalctl -t howdy`
- **Fedora compatibility matrix** in `README.md` with shields.io badges for F40+ (required), F43/F44 (tested), F41/F42 (likely works), F45+ (untested), and pre-F40 (unsupported)
- **ASCII PAM authentication-flow diagram** in `README.md`'s "How It Works" section, illustrating where the wrapper sits in the auth stack and how `sufficient` short-circuiting interacts with the password fallback
- **AI Usage Disclosure** section in `README.md` after the License section
- **FAQ entry** covering intermittent "Face not recognized" failures with both fixes (enroll more models, tune timeout)

### Changed

- Interactive menu grew from 9 to 10 numbered options to accommodate "Tune timeout"; menu prompt reads `Choose [0-10]`. Option ordering: 6 = Add face → 7 = Tune timeout → 8 = Test → 9 = Uninstall → 10 = Help
- `add_face_model()` now points users at option 7 for timeout tuning after they understand multi-model registration
- `README.md` "How It Works" rewritten with the new diagram and accurate `sufficient` flag explanation (the previous text referenced the v1.0-era `[success=end default=ignore]` flag that hasn't been used since v1.2.0)
- `FAQ.md` "face AND password" entry updated to reference `sufficient` instead of the obsolete `[success=end default=ignore]`

---

## [1.2.1] - 2026-05-24 — Visible scan results & reliability

### Added

- `pam_exec.so stdout` flag in the PAM line so the wrapper's "Recognized" / "Not recognized" message is relayed to the calling application (sudo, GDM, polkit) as a PAM_TEXT_INFO message and shown inline during the auth prompt — previously the result was only visible in `journalctl -t howdy`
- `--check-pam` now reports whether each howdy line has the `stdout` flag, calling out lines that need a `--fix` upgrade
- `add_howdy_to_pam` migrates existing howdy lines that lack `stdout` in place; `--fix` triggers a re-apply whenever any PAM file is missing the flag, so upgraders don't need to uninstall/reinstall

### Changed

- **Timeout**: raised from 8 s to 12 s. 8 s was a thin margin over the observed cold-start scan time (~7 s) and caused intermittent compare.py exit 11 (timeout) → "Not recognized" → password fallback even when the camera and model were healthy
- **howdy-auth wrapper**: prints scan result to stdout (so pam_exec can relay it) in addition to the system journal; removed the `/dev/tty` write since stdout already covers interactive terminals

---

## [1.2.0] - 2026-05-24 — Fedora 44 Compatibility & PAM Fixes

### Fixed

- `HOWDY_REF` was pinned to `v3.2.1`, a tag that does not exist in the upstream repo; updated to `v2.6.1` (latest stable release)
- `pam_python` (the previous PAM hook) requires `libpython2.7`, which is not available on Fedora 44 — removed entirely
- `[success=end default=ignore]` PAM control flag broke sudo and su on Fedora 44 (PAM 1.7.2 does not accept `end` as a keyword — it requires a numeric jump count); replaced with `sufficient`
- Polkit PAM file on Fedora 44 ships to `/usr/lib/pam.d/polkit-1` instead of `/etc/pam.d/`; installer now copies it as a local override before modifying
- Four bugs in howdy v2.6.1's `ffmpeg_reader.py` fixed by the installer at copy time:
  - `probe()` regex path parses dimension strings as `WxH` but assigned `(height, width)` — swapped to `(width, height)`
  - `record()` called `.reshape([-1, width, height, 3])` — corrected to `[-1, height, width, 3]`
  - `read()` compared a numpy array to `()` with `==`, raising `ValueError` — replaced with `isinstance()` check
  - `read()` returned `0` (falsy) for the success flag; `video_capture.py` treats `not ret` as failure, so face auth always aborted — changed to return `True`

### Changed

- **Installation approach**: replaced meson/ninja source build with a direct copy of howdy v2.6.1's Python files to `/usr/lib64/security/howdy/`; no compilation step required
- **PAM hook**: replaced `pam_python.so` with a `pam_exec.so` wrapper (`howdy-auth`) that calls `compare.py` directly with `$PAM_USER`; `pam_exec.so` is part of the standard `pam` package and always available
- **PAM control flag**: uses `sufficient` — face success skips remaining auth modules; face failure falls through to password
- **howdy-auth wrapper**: redirects all subprocess output to `/dev/null` and normalises exit codes to 0/1, preventing compare.py output from touching the PAM conversation
- **Recording plugin**: switched from `opencv` to `ffmpeg`; OpenCV's MJPG format switch via `CAP_PROP_FOURCC` triggers `ioctl(VIDIOC_QBUF): Bad file descriptor` errors in PAM execution context, causing all frames to be invalid and every authentication to time out; ffmpeg negotiates the format before streaming starts and does not have this issue
- **Timeout**: raised from 4 s to 8 s to give the IR camera time to warm up from a cold start in PAM context
- **Dependencies**: removed build tools (`meson`, `ninja-build`, `cmake`, `gcc`, `gcc-c++`, `pam-devel`, `inih-devel`, `libevdev-devel`, `gtk3-devel`, `opencv-devel`); added `bzip2` for model decompression; added `ffmpeg-python` pip package for howdy's ffmpeg recorder
- **Config file location**: howdy config is now at `/usr/lib64/security/howdy/config.ini` (where `compare.py` reads it via `__file__`-relative path) instead of `/etc/howdy/config.ini`
- **dlib model location**: face recognition models now stored in `/usr/lib64/security/howdy/dlib-data/` (co-located with Python files) instead of `/usr/share/dlib-data/`
- Polkit policy and bash completion installed from the cloned repo's `fedora/` and `autocomplete/` directories

---

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
