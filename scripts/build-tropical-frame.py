#!/usr/bin/env python3
"""
scripts/build-tropical-frame.py - Generate production-ready Tropical frame asset for Photobooth-App.

Loads:
- Source Tropical artwork: ui/assets/themes/tropical_fram.png (1536x1024 RGB)
- Production geometry/alpha template: ui/assets/themes/modern-gold-frame-v2.png (1800x1560 RGBA)

Generates:
- ui/assets/themes/tropical-frame-v1.png (1800x1560 RGBA)

Guarantees:
- Exact 1800x1560 RGBA canvas matching verified Photobooth-App production frame geometry.
- Byte-for-byte exact alpha channel copied from the Gold production template.
- Transparent photo window at x=[90, 1709], y=[90, 1169] (1620x1080, exact 3:2 ratio).
- Baked-in checkerboard pattern inside photo window completely eliminated (alpha=0, RGB zeroed).
- Runs automated PASS/FAIL validation checks.
"""

import sys
from pathlib import Path
from PIL import Image
import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent
THEMES_DIR = REPO_ROOT / "ui" / "assets" / "themes"

SOURCE_PATH = THEMES_DIR / "tropical_fram.png"
TEMPLATE_PATH = THEMES_DIR / "modern-gold-frame-v2.png"
OUTPUT_PATH = THEMES_DIR / "tropical-frame-v1.png"

REQUIRED_WIDTH = 1800
REQUIRED_HEIGHT = 1560
REQUIRED_MODE = "RGBA"
REQUIRED_TRANSPARENT_PIXELS = 1749600


def build_tropical_frame(
    src_path: Path = SOURCE_PATH,
    template_path: Path = TEMPLATE_PATH,
    out_path: Path = OUTPUT_PATH,
) -> bool:
    print("================================================================")
    print("  Building Production-Ready Tropical Frame Asset")
    print("================================================================")
    print(f"Source Artwork:   {src_path}")
    print(f"Template Frame:   {template_path}")
    print(f"Target Output:    {out_path}")
    print("----------------------------------------------------------------")

    # 1. Load template and extract exact alpha channel
    if not template_path.exists():
        sys.stderr.write(f"FAIL: Template file does not exist: {template_path}\n")
        return False

    if not src_path.exists():
        sys.stderr.write(f"FAIL: Source artwork does not exist: {src_path}\n")
        return False

    template_img = Image.open(template_path)
    template_rgba = np.array(template_img.convert("RGBA"))
    template_alpha = template_rgba[:, :, 3]

    # Verify template geometry
    tpl_w, tpl_h = template_img.size
    if (tpl_w, tpl_h) != (REQUIRED_WIDTH, REQUIRED_HEIGHT):
        sys.stderr.write(f"FAIL: Template dimensions are {tpl_w}x{tpl_h}, expected 1800x1560\n")
        return False

    # 2. Load source Tropical artwork and scale to 1800x1560
    source_img = Image.open(src_path)
    source_resized = source_img.resize((REQUIRED_WIDTH, REQUIRED_HEIGHT), Image.Resampling.LANCZOS)
    source_rgb = np.array(source_resized.convert("RGB"))

    # 3. Assemble output RGBA array
    output_arr = np.zeros((REQUIRED_HEIGHT, REQUIRED_WIDTH, 4), dtype=np.uint8)
    output_arr[:, :, :3] = source_rgb

    # Zero out RGB under transparent cutout to scrub any baked-in checkerboard artifacts
    output_arr[template_alpha == 0, :3] = 0

    # Copy template alpha channel exactly
    output_arr[:, :, 3] = template_alpha

    # 4. Save output image
    output_img = Image.fromarray(output_arr)
    output_img.save(out_path, format="PNG")
    print(f"[OK] Saved output image to: {out_path}")

    # 5. Reload and perform strict verification checks
    reloaded_img = Image.open(out_path)
    reloaded_arr = np.array(reloaded_img)
    reloaded_alpha = reloaded_arr[:, :, 3]

    width, height = reloaded_img.size
    mode = reloaded_img.mode
    transparent_pixels = int((reloaded_alpha == 0).sum())
    total_pixels = width * height
    pct_transparent = (transparent_pixels / total_pixels) * 100.0

    print("----------------------------------------------------------------")
    print("  Validation Checks")
    print("----------------------------------------------------------------")

    # Check 1: Dimensions
    dim_pass = (width == REQUIRED_WIDTH and height == REQUIRED_HEIGHT)
    print(f"[{'PASS' if dim_pass else 'FAIL'}] Dimensions: {width}x{height} (required: {REQUIRED_WIDTH}x{REQUIRED_HEIGHT})")

    # Check 2: Mode
    mode_pass = (mode == REQUIRED_MODE)
    print(f"[{'PASS' if mode_pass else 'FAIL'}] Color Mode: {mode} (required: {REQUIRED_MODE})")

    # Check 3: Alpha Channel Byte-for-Byte Equality
    alpha_equal = bool(np.array_equal(reloaded_alpha, template_alpha))
    print(f"[{'PASS' if alpha_equal else 'FAIL'}] Alpha matches template byte-for-byte: {alpha_equal}")

    # Check 4: Transparent pixel count
    pixel_pass = (transparent_pixels == REQUIRED_TRANSPARENT_PIXELS)
    print(f"[{'PASS' if pixel_pass else 'FAIL'}] Transparent pixels: {transparent_pixels:,} ({pct_transparent:.2f}%) (required: {REQUIRED_TRANSPARENT_PIXELS:,})")

    # Check 5: Cutout window geometry
    y_idxs, x_idxs = np.where(reloaded_alpha == 0)
    min_x, max_x = int(x_idxs.min()), int(x_idxs.max())
    min_y, max_y = int(y_idxs.min()), int(y_idxs.max())
    cutout_w = max_x - min_x + 1
    cutout_h = max_y - min_y + 1
    geom_pass = (min_x == 90 and max_x == 1709 and min_y == 90 and max_y == 1169)
    print(f"[{'PASS' if geom_pass else 'FAIL'}] Photo Cutout Window: x=[{min_x}, {max_x}], y=[{min_y}, {max_y}] -> {cutout_w}x{cutout_h}")

    all_passed = dim_pass and mode_pass and alpha_equal and pixel_pass and geom_pass
    print("----------------------------------------------------------------")
    print(f"Overall Result: {'ALL CHECKS PASSED' if all_passed else 'SOME CHECKS FAILED'}")
    print("================================================================")
    return all_passed


def main() -> None:
    success = build_tropical_frame()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
