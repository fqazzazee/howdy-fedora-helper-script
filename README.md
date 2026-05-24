# Howdy Fedora Helper Script

**Automated facial authentication setup for Fedora Workstation with GNOME**

This helper script sets up [Howdy](https://github.com/boltgolt/howdy) on Fedora, enabling Windows Hello-style face unlock using your laptop's infrared camera. It handles the Fedora-specific issues that make a manual installation painful: installing the Python-based face recognition engine, wiring it into PAM via `pam_exec`, fixing dlib paths, configuring SELinux, and setting up GDM permissions.

Once configured, you can unlock your screen, authorize sudo commands, and authenticate anywhere a password prompt appears — just by looking at your laptop.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Version](https://img.shields.io/badge/version-1.2.3-informational.svg)
![Desktop](https://img.shields.io/badge/desktop-GNOME%20%2F%20GDM-success.svg?logo=gnome)

### Fedora compatibility

![Fedora 40+](https://img.shields.io/badge/Fedora_40%2B-required-blue?logo=fedora&logoColor=white)
![Fedora 43](https://img.shields.io/badge/Fedora_43-tested-brightgreen?logo=fedora&logoColor=white)
![Fedora 44](https://img.shields.io/badge/Fedora_44-tested-brightgreen?logo=fedora&logoColor=white)
![Fedora 45](https://img.shields.io/badge/Fedora_45-untested-lightgrey?logo=fedora&logoColor=white)

| Status | Versions | Notes |
|---|---|---|
| ✅ **Required minimum** | Fedora 40 | Enforced by the installer; older versions are rejected at startup |
| ✅ **Tested & verified** | Fedora 43, 44 | All features working end-to-end (GDM, sudo, su, polkit) |
| ⚠️ **Likely works** | Fedora 41, 42 | Same package set as 43/44; not regression-tested |
| ❔ **Untested** | Fedora 45+ | Should work; please open an issue with `--diagnose` output if it doesn't |
| ❌ **Unsupported** | Fedora 39 and older | Predates the PAM 1.7.x changes the installer relies on |

## Features

- **Interactive menu** — No flags to memorize; just run the script
- **Automatic IR camera detection** — Identifies Windows Hello sensors by pixel format; interactive disambiguation when multiple candidates are found
- **Python-based install** — Installs howdy v2.6.1 Python files to `/usr/lib64/security/howdy/`; hooks into PAM via `pam_exec.so` (standard PAM, no compilation, no Python 2 dependency)
- **dlib handling** — Creates symlinks so face recognition works system-wide
- **SELinux policy** — Pre-built `.te` policy file (`selinux/howdy_pam.te`) for GDM camera access; audit-log fallback if needed
- **GDM integration** — Adds gdm user to video group automatically
- **OS/DM version gate** — Enforces Fedora 40+; detects and warns on non-GDM display managers
- **Transactional PAM edits** — Staged, validated, and atomically committed; timestamped backups kept for rollback
- **8-point diagnostics** — Checks everything that can go wrong
- **Auto-fix mode** — Repairs common issues with one command
- **Clean uninstaller** — Removes everything including PAM modifications
- **Non-interactive mode** — `--non-interactive` / `-y` for Kickstart/Ansible deployments

## Supported Authentication

| Service | Description |
|---------|-------------|
| GDM | GNOME login screen and lock screen |
| sudo | Terminal privilege escalation |
| su | User switching |
| Polkit | GUI password dialogs (Software Center, etc.) |

Password fallback is always available — if face recognition fails or times out, you get the normal password prompt.

## Quick Start

```bash
# Run installer
chmod +x install-howdy.sh
sudo ./install-howdy.sh
```

Choose **option 1** for a full installation. The script will:

1. Install dependencies (dlib via pip, v4l-utils, audit)
2. Detect your IR camera
3. Download and install howdy v2.6.1 Python files
4. Download face recognition models (~27 MB)
5. Configure PAM, SELinux, and GDM permissions
6. Prompt you to register your face

After installation, lock your screen (Super+L) and look at the camera to test.

## Usage

```bash
sudo ./install-howdy.sh                        # Interactive menu
sudo ./install-howdy.sh --install              # Full installation (skip menu)
sudo ./install-howdy.sh --diagnose             # Health check
sudo ./install-howdy.sh --fix                  # Auto-fix issues
sudo ./install-howdy.sh --check-pam            # Inspect PAM files
sudo ./install-howdy.sh --detect-ir            # Re-detect camera
sudo ./install-howdy.sh --tune-timeout         # Adjust scan timeout interactively (4–18s)
sudo ./install-howdy.sh --set-timeout 8        # Set scan timeout to N seconds, no prompt
sudo ./install-howdy.sh --uninstall            # Remove everything
sudo ./install-howdy.sh --non-interactive ...  # Skip all prompts (also -y)
```

**Environment overrides:**

```bash
HOWDY_REF=master sudo ./install-howdy.sh --install   # Track upstream instead of pinned tag
FORCE_DETECT=1   sudo ./install-howdy.sh --install   # Force IR camera re-detection
```

### Howdy Commands

After installation, howdy's own commands are available:

```bash
sudo howdy add              # Register your face
sudo howdy list             # List face models
sudo howdy remove <id>      # Remove a model
sudo howdy test             # Live camera test
sudo howdy config           # Edit configuration
sudo howdy disable          # Temporarily disable
sudo howdy enable           # Re-enable
```

## Requirements

- Fedora Workstation 40+ (enforced; tested on Fedora 43 and 44)
- GNOME desktop with GDM (non-GDM setups are warned and can opt to continue)
- Laptop with Windows Hello compatible IR camera
- Internet connection (for source code and models)

## Repository Structure

```
howdy-fedora-helper-script/
├── install-howdy.sh      # Main installer script
├── selinux/
│   └── howdy_pam.te      # SELinux type enforcement policy for GDM camera access
├── README.md
├── CHANGELOG.md
├── CONTRIBUTING.md
├── FAQ.md
├── Home.md
└── Tested-Hardware.md
```

## Documentation

- **[HOWDY-MANUAL.md](HOWDY-MANUAL.md)** — Complete setup guide, configuration, and troubleshooting
- **[Wiki](../../wiki)** — FAQ and additional notes

## Troubleshooting

Run the diagnostic:

```bash
sudo ./install-howdy.sh --diagnose
```

This checks: howdy installation, dlib module, IR camera, GDM permissions, SELinux policy, PAM configuration, face recognition models, and registered face models.

For most issues, the auto-fixer handles it:

```bash
sudo ./install-howdy.sh --fix
```

If GDM lock screen was fixed, restart GDM (open a TTY with Ctrl+Alt+F3 first):

```bash
sudo systemctl restart gdm
```

See [HOWDY-MANUAL.md](HOWDY-MANUAL.md) for detailed troubleshooting.

## How It Works

The installer downloads [Howdy](https://github.com/boltgolt/howdy) v2.6.1 and copies its Python files to `/usr/lib64/security/howdy/`. A thin shell wrapper (`howdy-auth`) is invoked by `pam_exec.so` — a standard PAM module bundled with every Linux system that runs an external command and uses its exit code as the auth result.

### PAM authentication flow

```text
   ┌──────────────────────────────┐
   │  User triggers an auth event │   sudo, GDM login/lock,
   │  (any PAM-protected action)  │   polkit prompt, su, …
   └───────────────┬──────────────┘
                   │
                   ▼
   ┌──────────────────────────────────────────────────────────┐
   │  /etc/pam.d/<service>                                    │
   │                                                          │
   │  auth  sufficient  pam_exec.so quiet stdout \            │
   │                     /usr/lib64/security/howdy/howdy-auth │
   │  auth  include     system-auth        ← password module  │
   └───────────────┬──────────────────────────────────────────┘
                   │
                   ▼  (pam_exec runs the wrapper)
   ┌──────────────────────────────┐
   │  howdy-auth  (bash wrapper)  │
   │     └─ python3 compare.py    │
   │           └─ IR camera grab  │
   │              + dlib match    │
   └───────────────┬──────────────┘
                   │
                   ▼
            ╭─────────────╮
            │ exit code 0?│
            ╰──┬───────┬──╯
          Yes  │       │  No
               ▼       ▼
   ┌───────────────┐  ┌─────────────────────────┐
   │ ✅  sufficient│  │ 🔒  sufficient ignored  │
   │     succeeded │  │     on failure          │
   │     AUTH ENDS │  │     → fall through to   │
   │     no pwd    │  │       system-auth       │
   │     prompt    │  │     → password prompt   │
   └───────────────┘  └─────────────────────────┘
```

**Key flags**
- `sufficient` — success short-circuits the auth stack (no password); failure is silently ignored so the next module runs
- `stdout` — `pam_exec.so` relays the wrapper's stdout to the calling application (sudo/GDM/polkit) so you see the "Recognized" / "Not recognized" message inline
- `quiet` — suppresses `pam_exec`'s own "command exited with status N" syslog noise (the wrapper logs its own structured messages via `logger -t howdy`)

### Fedora-specific handling

The script also handles things that aren't part of upstream howdy:
- **dlib path**: pip installs to `/usr/local/...` but howdy needs `/usr/lib64/...` — script creates symlinks
- **GDM permissions**: adds `gdm` user to `video` group for camera access
- **SELinux**: installs a policy allowing GDM to access video devices
- **PAM file locations**: Fedora 44 ships `polkit-1` to `/usr/lib/pam.d/`; the installer copies it as a local override before editing

## Recommended: register multiple face models

For best accuracy, **register more than one face model**. A single model captures one moment in time and is the leading cause of false rejections. Re-run option 6 (or `sudo howdy add`) for each:

- **One without glasses, one with** (if you wear glasses sometimes)
- **One in normal lighting, one dimmer** (evening vs. day)
- **Slight head-angle variations** (straight, slightly left, slightly right)

Three or more enrolled models lets you drop the scan timeout to ~8s (option 7 / `--set-timeout 8`) because a match is typically found in the first few frames. With a single model, keep the default 12s timeout.

## Credits

This installer is a wrapper around **[Howdy](https://github.com/boltgolt/howdy)** by [boltgolt](https://github.com/boltgolt) and contributors. Howdy does all the actual face recognition work using [dlib](http://dlib.net/)'s neural networks.

- **Howdy**: https://github.com/boltgolt/howdy
- **dlib**: http://dlib.net/

This installer script adds Fedora-specific automation, diagnostics, and fixes. It does not modify or redistribute Howdy's source code.

## License

This installer script is released under the **MIT License**. See [LICENSE](LICENSE) for details.

Note: [Howdy](https://github.com/boltgolt/howdy) itself is licensed under the MIT License. [dlib](http://dlib.net/) is licensed under the Boost Software License. This installer downloads and builds these projects but does not redistribute their code.

## AI Usage Disclosure

Portions of this installer (script logic, PAM diagnostics, documentation) were drafted with the assistance of AI tools (Anthropic's Claude). All code is human-reviewed, tested on real hardware, and the maintainer takes full responsibility for what ships. AI was used as a collaborator, not an unattended author.

## Contributing

Issues and pull requests are welcome. Please test on your Fedora version before submitting.

## Security Note

Face recognition via IR is more resistant to photo-based spoofing than a regular webcam, but it is not as secure as a strong password or hardware security key. Your password remains as a fallback and is never weakened by adding Howdy.
