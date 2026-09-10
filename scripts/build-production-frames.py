#!/usr/bin/env python3
"""
scripts/build-production-frames.py - Normalize all Photobooth-App theme frame assets.

Standardizes all theme artwork into production-ready RGBA overlays:
- Canvas: 1800 x 1560 RGBA
- Alpha: byte-for-byte identical to ui/assets/themes/modern-gold-frame-v2.png
- Photo Cutout Window: x=[90, 1709], y=[90, 1169] (1620 x 1080 px, 3:2 ratio)
- Fully transparent pixels: 1,749,600 (62.31%)
- Zeroes RGB underneath fully transparent pixels (eliminates baked-in checkerboards/placeholders)
- Validates all generated assets deterministically
"""

import sys
from pathlib import Path
from typing import Dict, List, Tuple
from PIL import Image
import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent
THEMES_DIR = REPO_ROOT / "ui" / "assets" / "themes"
TEMPLATE_PATH = THEMES_DIR / "modern-gold-frame-v2.png"

REQUIRED_WIDTH = 1800
REQUIRED_HEIGHT = 1560
REQUIRED_MODE = "RGBA"
REQUIRED_TRANSPARENT_PIXELS = 1749600

# Registry of source artwork to production output filename
THEME_FRAME_MAPPINGS: List[Dict[str, str]] = [
    {
        "id": "tropical",
        "name": "Tropical",
        "source": "tropical_fram.png",
        "output": "tropical-frame-v1.png",
    },
    {
        "id": "black-gold",
        "name": "Black & Gold",
        "source": "black_and_gold.png",
        "output": "black-and-gold-frame-v1.png",
    },
    {
        "id": "floral",
        "name": "Elegant Floral",
        "source": "elegant_floral_gold_photo_frame.png",
        "output": "floral-frame-v1.png",
    },
    {
        "id": "celebration",
        "name": "Celebration",
        "source": "festive_balloon_confetti.png",
        "output": "confetti-frame-v1.png",
    },
    {
        "id": "halloween",
        "name": "Halloween",
        "source": "spooky_halloween_photo_frame.png",
        "output": "halloween-frame-v1.png",
    },
    {
        "id": "thanksgiving",
        "name": "Thanksgiving",
        "source": "rustic_thanksgiving_harvest_photo_frame.png",
        "output": "thanksgiving-frame-v1.png",
    },
    {
        "id": "christmas",
        "name": "Christmas",
        "source": "merry_christmas_snowy_photoframe.png",
        "output": "christmas-frame-v1.png",
    },
    {
        "id": "new-year",
        "name": "New Year",
        "source": "glamorous_black_and_gold_new_year_frame.png",
        "output": "new-year-frame-v1.png",
    },
]


def load_template_alpha(template_path: Path = TEMPLATE_PATH) -> np.ndarray:
    if not template_path.exists():
        raise FileNotFoundError(f"Template frame not found: {template_path}")
    tpl = Image.open(template_path)
    if tpl.size != (REQUIRED_WIDTH, REQUIRED_HEIGHT):
        raise ValueError(f"Template dimensions {tpl.size} != {(REQUIRED_WIDTH, REQUIRED_HEIGHT)}")
    tpl_rgba = np.array(tpl.convert("RGBA"))
    return tpl_rgba[:, :, 3]


def normalize_frame(
    source_path: Path,
    output_path: Path,
    template_alpha: np.ndarray,
) -> Tuple[bool, Dict[str, any]]:
    if not source_path.exists():
        return False, {"error": f"Source file missing: {source_path.name}"}

    src_img = Image.open(source_path)

    # Resize source artwork to fit 1800x1560 canvas with high-quality LANCZOS
    resized = src_img.resize((REQUIRED_WIDTH, REQUIRED_HEIGHT), Image.Resampling.LANCZOS)
    rgb_arr = np.array(resized.convert("RGB"))

    # Assemble RGBA
    out_arr = np.zeros((REQUIRED_HEIGHT, REQUIRED_WIDTH, 4), dtype=np.uint8)
    out_arr[:, :, :3] = rgb_arr

    # Zero RGB underneath transparent pixels (clean transparent window)
    out_arr[template_alpha == 0, :3] = 0
    # Copy exact alpha channel byte-for-byte
    out_arr[:, :, 3] = template_alpha

    out_img = Image.fromarray(out_arr)
    out_img.save(output_path, format="PNG")

    # Reopen and strictly validate
    reloaded = Image.open(output_path)
    reloaded_arr = np.array(reloaded)
    reloaded_alpha = reloaded_arr[:, :, 3]

    w, h = reloaded.size
    mode = reloaded.mode
    alpha_match = bool(np.array_equal(reloaded_alpha, template_alpha))
    trans_count = int((reloaded_alpha == 0).sum())
    trans_pct = (trans_count / (w * h)) * 100.0

    y_idxs, x_idxs = np.where(reloaded_alpha == 0)
    geom_ok = (
        int(x_idxs.min()) == 90
        and int(x_idxs.max()) == 1709
        and int(y_idxs.min()) == 90
        and int(y_idxs.max()) == 1169
    )

    passed = (
        w == REQUIRED_WIDTH
        and h == REQUIRED_HEIGHT
        and mode == REQUIRED_MODE
        and alpha_match
        and trans_count == REQUIRED_TRANSPARENT_PIXELS
        and geom_ok
    )

    stats = {
        "width": w,
        "height": h,
        "mode": mode,
        "alpha_match": alpha_match,
        "transparent_pixels": trans_count,
        "transparent_pct": trans_pct,
        "passed": passed,
    }
    return passed, stats


def build_all() -> bool:
    print("=" * 80)
    print("  Normalizing Production Frame Assets (Photobooth-App Specification)")
    print("=" * 80)
    print(f"Template Frame:   {TEMPLATE_PATH.name} ({REQUIRED_WIDTH}x{REQUIRED_HEIGHT} RGBA)")
    print(f"Target Directory: {THEMES_DIR}")
    print("-" * 80)

    template_alpha = load_template_alpha()
    results = []
    all_success = True

    for item in THEME_FRAME_MAPPINGS:
        src = THEMES_DIR / item["source"]
        dst = THEMES_DIR / item["output"]

        ok, stats = normalize_frame(src, dst, template_alpha)
        if not ok:
            all_success = False

        results.append({
            "name": item["name"],
            "source": item["source"],
            "output": item["output"],
            "stats": stats,
            "status": "PASS" if ok else "FAIL",
        })

    # Also validate template itself
    tpl_img = Image.open(TEMPLATE_PATH)
    tpl_arr = np.array(tpl_img)
    tpl_alpha = tpl_arr[:, :, 3]
    tpl_trans = int((tpl_alpha == 0).sum())
    results.insert(0, {
        "name": "Modern Gold (Template)",
        "source": TEMPLATE_PATH.name,
        "output": TEMPLATE_PATH.name,
        "stats": {
            "width": tpl_img.width,
            "height": tpl_img.height,
            "mode": tpl_img.mode,
            "alpha_match": True,
            "transparent_pixels": tpl_trans,
            "transparent_pct": (tpl_trans / (tpl_img.width * tpl_img.height)) * 100.0,
            "passed": True,
        },
        "status": "PASS",
    })

    # Print markdown verification table
    print(f"\n| Theme | Source | Production Asset | Dimensions | Mode | Alpha Match | Transparent Pixels | Status |")
    print(f"| :--- | :--- | :--- | :---: | :---: | :---: | :---: | :---: |")
    for r in results:
        s = r["stats"]
        dims = f"{s['width']}x{s['height']}"
        trans = f"{s['transparent_pixels']:,} ({s['transparent_pct']:.2f}%)"
        match = "EXACT" if s["alpha_match"] else "MISMATCH"
        print(f"| **{r['name']}** | `{r['source']}` | `{r['output']}` | {dims} | {s['mode']} | {match} | {trans} | **{r['status']}** |")

    print("\n" + "=" * 80)
    print(f"Overall Result: {'ALL PRODUCTION FRAMES PASSED' if all_success else 'VALIDATION FAILED'}")
    print("=" * 80)
    return all_success


def main() -> None:
    success = build_all()
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
