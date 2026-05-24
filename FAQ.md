# Frequently Asked Questions

## Installation

### Why not use the COPR howdy package?

The COPR howdy package depends on `pam_python.so`, which requires `libpython2.7`. Fedora 44 removed Python 2.7 entirely, making the COPR package uninstallable. This script instead installs howdy v2.6.1's Python files directly and uses `pam_exec.so` — a standard PAM module bundled with every Linux system — to invoke howdy's `compare.py` during authentication. No Python 2, no compilation required.

### How long does installation take?

About 5–15 minutes on a typical system. Most of the time is spent compiling dlib via pip (if not already installed) and downloading the face recognition model files (~27 MB). The howdy installation itself is just a file copy with no compilation step.

### Can I use this on other distributions?

This helper script is specifically written for Fedora with GNOME/GDM. The PAM configuration, SELinux handling, and package management commands are Fedora-specific. For other distributions, see the [upstream Howdy project](https://github.com/boltgolt/howdy) for general installation instructions.

### Can I run this unattended (Kickstart, Ansible, CI)?

Yes. Pass `--non-interactive` (or `-y`) before your action flag:

```bash
sudo ./install-howdy.sh --non-interactive --install
```

In this mode all interactive prompts are skipped: the first IR camera candidate is selected automatically, non-GDM warnings are printed but execution continues, and GDM is not restarted automatically (a reminder command is printed instead).

### I'm using KDE/SDDM (not GNOME/GDM) — will this work?

Partially. The script detects your display manager at startup and warns you if it isn't GDM. You can choose to continue; it will still install Howdy and configure PAM for `sudo`, `su`, and polkit — but GDM-specific steps (video group, gdm PAM files, GDM restart) are skipped automatically. Lock-screen face unlock requires GDM.

## Hardware

### How do I know if my laptop has a Windows Hello IR camera?

Look for small dots or LEDs near your webcam — these are IR illuminators. On Windows, check Device Manager for "IR Camera" or "Windows Hello" devices. On Linux, run:

```bash
v4l2-ctl --list-devices
```

If you see multiple video devices from the same camera module, one is likely IR.

### The installer detected my camera but face recognition doesn't work

Try a different video device. On some laptops, the IR camera is `/dev/video2` or `/dev/video4`, not `/dev/video0`. Run:

```bash
sudo ./install-howdy.sh --detect-ir
```

Then test each candidate with `ffplay /dev/videoX` — the IR camera shows a grayscale image.

### Can I use a regular webcam instead of an IR camera?

Technically yes, but it's not recommended. Regular webcams are easily fooled by photos and don't work in low light. IR cameras are specifically designed for face recognition.

## Authentication

### Why does sudo work but the lock screen doesn't?

The GDM lock screen runs as the `gdm` user, which needs:
1. Membership in the `video` group (for camera access)
2. An SELinux policy allowing camera access

Run the auto-fixer — it will prompt you to restart GDM at the end (open a TTY first for safety):

```bash
sudo ./install-howdy.sh --fix
```

If you skipped the restart prompt or ran in `--non-interactive` mode:

```bash
sudo systemctl restart gdm
```

### Can I require both face AND password?

Yes, but it requires manual PAM configuration. Replace the `[success=end default=ignore]` control flag with `required` in the howdy PAM lines, and ensure a password module is also `required`. This makes face recognition an additional factor rather than a replacement.

### How do I temporarily disable face recognition?

```bash
sudo howdy disable
```

Re-enable with:

```bash
sudo howdy enable
```

### Does this work with fingerprint readers?

Yes, they're independent. You can have both howdy (face) and fprintd (fingerprint) configured. PAM will try each in order based on your configuration.

## Security

### Is face recognition secure?

IR-based face recognition is more secure than regular webcam recognition (can't be fooled by photos on a screen), but less secure than a strong password or hardware security key. Consider it a convenience feature.

### Can someone unlock my laptop with a photo of my face?

IR cameras are resistant to this attack because they detect infrared reflectance, not visible light. A printed photo or phone screen won't have the same IR signature as a real face. However, sophisticated 3D-printed masks might work — this isn't bank-vault security.

### Where is my face data stored?

Locally in `/usr/lib64/security/howdy/models/`. Face data never leaves your machine.

## Troubleshooting

### "ModuleNotFoundError: No module named 'dlib'"

The dlib Python symlinks are broken. Fix:

```bash
sudo ./install-howdy.sh --fix
```

If that doesn't work:

```bash
sudo pip3 install --force-reinstall dlib --break-system-packages
sudo ./install-howdy.sh --fix
```

### "Data files have not been downloaded"

The face recognition neural network models are missing. Run the auto-fixer, which will re-download them:

```bash
sudo ./install-howdy.sh --fix
```

Or download manually:

```bash
cd /usr/lib64/security/howdy/dlib-data
sudo curl -LO https://github.com/davisking/dlib-models/raw/master/dlib_face_recognition_resnet_model_v1.dat.bz2
sudo curl -LO https://github.com/davisking/dlib-models/raw/master/mmod_human_face_detector.dat.bz2
sudo curl -LO https://github.com/davisking/dlib-models/raw/master/shape_predictor_5_face_landmarks.dat.bz2
sudo bunzip2 *.bz2
```

### SELinux is blocking something

Check for denials:

```bash
sudo ausearch -m avc -ts recent | grep howdy
```

The auto-fixer generates policies from these denials:

```bash
sudo ./install-howdy.sh --fix
```

### Face recognition works in test but not in actual auth

Run the diagnostic to see which component is failing:

```bash
sudo ./install-howdy.sh --diagnose
```

Common causes:
- PAM not configured (check PAM section of diagnostic)
- GDM not in video group (check GDM section)
- SELinux blocking (check SELinux section)

## Uninstallation

### How do I completely remove howdy?

```bash
sudo ./install-howdy.sh --uninstall
```

Or:

```bash
sudo howdy-uninstall
```

This removes howdy, PAM modifications, SELinux policies, and dlib symlinks. It does not remove pip-installed dlib.

### Will uninstalling break my login?

No. The uninstaller removes howdy from PAM files, restoring normal password-only authentication. You can always log in with your password.
