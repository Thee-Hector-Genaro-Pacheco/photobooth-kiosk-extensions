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

---

## Verified Filter Configuration Fields

### Generic Photo Filter
- `actions.image[0].processing.image_filter` (string enum, default: `"original"`): Controls the active image filter applied to single-photo captures prior to frame overlay compositing.

### Filter Processing Order
In `photobooth/services/mediaprocessing/processes.py`:
1. `RemovebgStep` (if background removal enabled)
2. `ImageMountStep` (background image)
3. `FillBackgroundStep` (background color)
4. `PluginFilterStep(config.image_filter)` (**Filter applied here to photo**)
5. `ImageFrameStep(config.img_frame_file)` (**Frame overlay composited on top here**)
6. `TextStep(config.texts)`

> [!NOTE]
> Filters execute BEFORE frame compositing. The frame overlay is never filtered, retaining its true colors.

### Initial Generic Filter Set (`FILTER_CONFIGS`)
| Filter ID | Display Name | Verified Backend Enum Value |
| :--- | :--- | :--- |
| `original` | Original | `"original"` |
| `black-and-white` | Black & White | `"FilterPilgram2.inkwell"` |
| `vintage` | Vintage | `"FilterPilgram2._1977"` |
| `warm` | Warm | `"FilterPilgram2.aden"` |
| `vibrant` | Vibrant | `"FilterPilgram2.clarendon"` |
| `film` | Film | `"FilterPilgram2.moon"` |

