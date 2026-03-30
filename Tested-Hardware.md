# Tested Hardware

This page lists hardware configurations confirmed to work with the Howdy Fedora Helper Script. Please add your hardware if you've successfully set up face recognition.

## Confirmed Working

| Laptop | IR Camera | Fedora Version | GNOME | IR Device | Notes |
|--------|-----------|----------------|-------|-----------|-------|
| ASUS Zenbook 14 Flip UP3404VA-DS74T | USB2.0 FHD UVC WebCam (IR) | Fedora 43 | GNOME 49 | `/dev/video2` | Auto-detected as "possible IR (mixed formats)" |

## How to Add Your Hardware

Edit this page and add a row with:

1. **Laptop**: Make and model
2. **IR Camera**: Output from `v4l2-ctl --device=/dev/videoX --info | grep "Card type"`
3. **Fedora Version**: `cat /etc/fedora-release`
4. **GNOME**: `gnome-shell --version`
5. **IR Device**: Which `/dev/video*` device is the IR camera
6. **Notes**: Any quirks or special configuration needed

## Identifying Your IR Camera

Run the detector:

```bash
sudo ./install-howdy.sh --detect-ir
```

Or manually:

```bash
# List all video devices
v4l2-ctl --list-devices

# Check each device's formats
v4l2-ctl --device=/dev/video0 --list-formats-ext
v4l2-ctl --device=/dev/video2 --list-formats-ext
```

IR cameras typically support grayscale formats (GREY, Y8, Y10) while RGB webcams support color formats (MJPEG, YUYV).

## Known Issues by Hardware

### ASUS Zenbooks

- IR camera and RGB webcam share the same card name ("USB2.0 FHD UVC WebCam")
- IR camera is typically `/dev/video2` but device numbers can change after reboot
- Both YUYV and GREY formats may be reported; YUYV works reliably

### Lenovo ThinkPads

*(Add your experience here)*

### Dell XPS

*(Add your experience here)*

### HP Spectre / Envy

*(Add your experience here)*

## Hardware That Doesn't Work

| Laptop | Reason |
|--------|--------|
| *(None reported yet)* | |

If your hardware doesn't work, please open an issue with:
- Laptop make/model
- Output of `sudo ./install-howdy.sh --diagnose`
- Output of `v4l2-ctl --list-devices`
- Output of `v4l2-ctl --device=/dev/videoX --list-formats-ext` for all devices
