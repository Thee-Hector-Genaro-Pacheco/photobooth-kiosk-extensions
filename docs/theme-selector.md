# Theme Selector Extension

## Current Phase: Responsive Production Theme Selector Baseline

This extension provides a dedicated, touch-friendly theme selector UI for Photobooth-App kiosks, allowing users to toggle between verified frame styles without navigating complex admin menus.

The responsive gallery presentation ("Photo Booth Frame Collection") is the accepted production baseline.

---

## Supported Themes & Asset Registry

All themes are defined centrally in `scripts/apply-theme.py` (`THEME_CONFIGS`) and exposed via `scripts/theme-selector-server.py` (`/api/themes`).

### Preview vs. Production Asset Distinction
- **Preview Asset (`preview_asset`):** Relative to `ui/`, used strictly for display within the frontend gallery cards (e.g. `assets/themes/tropical-frame-v1.png`).
- **Production Asset (`production_frame`):** Photobooth-App userdata path (e.g. `userdata/tropical-frame-v1.png`) used exclusively in the live booth configuration patch (`img_frame_file` and `livestream_frameoverlay_image`).
- **Source Artwork Isolation:** Original unnormalized source artwork (such as raw RGB files or checkerboard files from downloads) is never referenced in live booth configurations.

### Theme Registry Table

| Theme ID | Display Name | Preview Asset (`ui/`) | Production Frame (`userdata/`) | Live Overlay Enabled |
| :--- | :--- | :--- | :--- | :--- |
| `modern-gold` | **Modern Gold** | `assets/themes/modern-gold-frame-v2.png` | `userdata/modern-gold-frame-v2.png` | `true` |
| `tropical` | **Tropical** | `assets/themes/tropical-frame-v1.png` | `userdata/tropical-frame-v1.png` | `true` |
| `black-gold` | **Black & Gold** | `assets/themes/black-and-gold-frame-v1.png` | `userdata/black-and-gold-frame-v1.png` | `true` |
| `floral` | **Elegant Floral** | `assets/themes/floral-frame-v1.png` | `userdata/floral-frame-v1.png` | `true` |
| `celebration` | **Celebration** | `assets/themes/confetti-frame-v1.png` | `userdata/confetti-frame-v1.png` | `true` |
| `halloween` | **Halloween** | `assets/themes/halloween-frame-v1.png` | `userdata/halloween-frame-v1.png` | `true` |
| `thanksgiving` | **Thanksgiving** | `assets/themes/thanksgiving-frame-v1.png` | `userdata/thanksgiving-frame-v1.png` | `true` |
| `christmas` | **Christmas** | `assets/themes/christmas-frame-v1.png` | `userdata/christmas-frame-v1.png` | `true` |
| `new-year` | **New Year** | `assets/themes/new-year-frame-v1.png` | `userdata/new-year-frame-v1.png` | `true` |
| `none` | **No Border** | *None (CSS preview)* | *None* | `false` |

*Note: For `none` (No Border), frame overlays and collage front files are disabled (`img_frame_enable = false`, `enable_livestream_frameoverlay = false`).*

---

## Canonical Production Frame Specification

All production theme overlays are normalized to match `ui/assets/themes/modern-gold-frame-v2.png`:

- **Dimensions:** Exactly `1800 × 1560` pixels
- **Color Mode:** `RGBA` (32-bit)
- **Alpha Channel Requirement:** Byte-for-byte exact match to `modern-gold-frame-v2.png` alpha channel
- **Transparent Camera Opening:**
  - `x = 90..1709` (width: `1620px`)
  - `y = 90..1169` (height: `1080px`)
  - Exact 3:2 camera aspect ratio
- **Transparent Pixel Count:** Exactly `1,749,600` fully transparent pixels (`62.31%` of total canvas)
- **Zero Under Alpha:** Fully transparent pixels have RGB values zeroed out (`(0, 0, 0, 0)`) to eliminate ghost artifacts.

Normalization is managed deterministically via `scripts/build-production-frames.py`.

---

## Responsive Frontend Architecture

The frontend (`ui/`) uses a flattened hierarchy with CSS Grid:

```
gallery-container
  collection-header (brand + icon left, category tagline right)
  theme-grid (CSS Grid gallery)
    theme-card (button with data-theme)
      preview-wrapper (aspect-ratio: 1800/1560)
        img / plain-photo-sample
        card-badge (CURRENT THEME overlay)
      theme-name (clean label)
  collection-footer (compact status bar)
```

### Responsive Breakpoints
- **Large Viewports (`>= 1100px`):** 3 columns (`repeat(3, minmax(0, 1fr))`)
- **Medium Viewports (`700px – 1099px`):** 2 columns (`repeat(2, minmax(0, 1fr))`)
- **Small Viewports (`< 700px`):** 1 column (`minmax(0, 1fr)`), bounded to `max-width: 480px` centered to prevent vertical distortion

### Geometry & Sizing Guarantees
- **Unified Preview Aspect Ratio:** Every preview uses `aspect-ratio: 1800 / 1560;` with `object-fit: contain`. No letterboxing and zero distortion.
- **No Border Equality:** The "No Border" option is rendered within the identical `.preview-wrapper` container (`width: 100%; height: 100%`), ensuring it never exceeds or collapses relative to framed options.
- **Natural Document Flow:** Theme cards and labels participate in normal grid flow. Next rows begin strictly after the tallest element; zero vertical row collisions.
- **Single Page Scrolling:** No internal scroll containers (`overflow-y: auto` removed from grid). The document scrolls naturally as one unified page.
- **Zero Shift on Selection:** Selected state applies non-displacing `box-shadow` and gold `border-color` to `.preview-wrapper`. Card dimensions and grid coordinates remain invariant.

---

## Production / Live Apply Safety Model

The live apply workflow (`scripts/apply-theme.py --apply`) enforces strict read-modify-write safety:

1. **Authentication:**
   - Server-side OAuth2 token negotiation via `POST /api/admin/auth/token`.
   - Admin credentials are never stored, logged, or exposed to frontend JavaScript.
2. **Read Full Config:**
   - Performs `GET /api/config` to retrieve the entire active configuration.
3. **Password Protection Fix:**
   - Photobooth-App's `GET /api/config` returns masked placeholder values for passwords.
   - The real admin password is automatically restored into `common.admin_password` before modification to prevent credential reset.
4. **Targeted Field Modification:**
   - Modifies **only** verified theme fields:
     - `actions.image[0].processing.img_frame_enable`
     - `actions.image[0].processing.img_frame_file`
     - `actions.collage[0].processing.canvas_img_front_file`
     - `uisettings.enable_livestream_frameoverlay`
     - `uisettings.livestream_frameoverlay_image`
   - All unrelated configuration sections remain untouched.
5. **Patch Without Reload:**
   - Submits `PATCH /api/admin/config/app?reload=false` with Bearer token.
6. **Post-Apply Verification:**
   - Re-reads full configuration via `GET /api/config` and validates updated fields match expected values.

---

## Kiosk Integration & Running Locally

### Running Locally (Preview Mode)
```bash
# Start local UI server on port 8080
python3 scripts/theme-selector-server.py --port 8080
```
Open `http://localhost:8080/` in a browser. In preview mode, theme selections update the local UI state without sending live PATCH requests to the booth.

### Live CLI Apply
```bash
# Preview config patch as JSON (offline)
python3 scripts/apply-theme.py modern-gold --json

# Apply theme live to Photobooth-App
python3 scripts/apply-theme.py tropical --apply --url http://192.168.2.3:8000
```
