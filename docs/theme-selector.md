# Theme Selector Extension

## Current Phase: Phase 1 (Offline Config Patch Generator)

This phase establishes the foundational theme definitions and configuration patch generator for the Photobooth-App kiosk.

### Scope & Responsibilities
- **Theme Definition:** Encapsulate overlay assets and configuration values for supported themes.
- **Config Patch Generation:** Build structured Photobooth-App configuration patches targeting the app's `actions` and `uisettings` schema.
- **Dry-Run & Inspection:** Allow operators and automated scripts to inspect generated JSON patches via the CLI.

### Schema Reference
For the exact verified Photobooth-App field names and asset mappings, refer to [photobooth-config-contract.md](file:///Users/hectorpacheco/Desktop/Projects/photobooth-kiosk-extensions/docs/photobooth-config-contract.md). All theme generator and applicator implementations must strictly follow this contract.

### Supported Themes
1. **`modern-gold`**
   - Single-photo frame: `actions.image[0].processing.img_frame_file = "userdata/modern-gold-frame-v2.png"` (`img_frame_enable = true`)
   - Collage overlay: `actions.collage[0].processing.canvas_img_front_file = "userdata/modern-gold-collage.png"`
   - Live view overlay: `uisettings.livestream_frameoverlay_image = "userdata/modern-gold-frame-v2.png"` (`enable_livestream_frameoverlay = true`)
2. **`none`**
   - Single-photo frame disabled (`img_frame_enable = false`, `img_frame_file = null`)
   - Collage overlay disabled (`canvas_img_front_file = null`)
   - Live view overlay disabled (`enable_livestream_frameoverlay = false`, `livestream_frameoverlay_image = null`)

### Operational Constraints in Phase 1
- **Standard Library Only:** Zero external dependencies (uses Python built-in `argparse`, `json`, `sys`).
- **No Remote Calls:** Does not communicate with Raspberry Pi hardware or network endpoints.
- **No API Calls:** Does not send HTTP requests to the Photobooth-App REST API yet.
- **No File Mutation:** Does not modify local or remote configuration files.

### Usage
```bash
# Output JSON config patch for modern-gold
python3 scripts/apply-theme.py modern-gold --json

# Output JSON config patch for none
python3 scripts/apply-theme.py none --json
```

### Next Phases
- **Phase 2:** Implement Photobooth-App REST API integration (`PATCH /api/admin/config/app`) to persist configuration updates.
- **Phase 3:** Kiosk selector UI and hardware trigger integration.
