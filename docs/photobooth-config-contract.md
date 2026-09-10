# Photobooth-App Configuration Contract

> [!WARNING]
> These field names were verified against the live Photobooth-App configuration and must not be renamed, nested differently, or replaced with guessed equivalents.

This document defines the contract for theme-related configuration fields used by extensions interacting with Photobooth-App.

## Verified Theme Configuration Fields

### 1. Single Photo Capture
- `actions.image[0].processing.img_frame_enable` (boolean): Controls whether the frame overlay is enabled for single-photo captures.
- `actions.image[0].processing.img_frame_file` (string | null): File path to the single-photo frame overlay image in `userdata/`.

### 2. Collage Processing
- `actions.collage[0].processing.canvas_img_front_file` (string | null): File path to the front overlay image pasted over the collage canvas in `userdata/`.

### 3. Live View Overlay
- `uisettings.enable_livestream_frameoverlay` (boolean): Controls whether the live camera stream overlay is enabled in the UI.
- `uisettings.livestream_frameoverlay_image` (string | null): File path to the livestream overlay image in `userdata/`.

---

## Verified Theme Values: Modern Gold

For the `modern-gold` theme, the following verified asset paths are used:

- **Single Photo Frame & Live View Overlay:**
  `userdata/modern-gold-frame-v2.png`
- **Collage Front Overlay:**
  `userdata/modern-gold-collage.png`

### Summary Mapping

| Field | Modern Gold Value | None Value |
| :--- | :--- | :--- |
| `actions.image[0].processing.img_frame_enable` | `true` | `false` |
| `actions.image[0].processing.img_frame_file` | `"userdata/modern-gold-frame-v2.png"` | `null` |
| `actions.collage[0].processing.canvas_img_front_file` | `"userdata/modern-gold-collage.png"` | `null` |
| `uisettings.enable_livestream_frameoverlay` | `true` | `false` |
| `uisettings.livestream_frameoverlay_image` | `"userdata/modern-gold-frame-v2.png"` | `null` |
