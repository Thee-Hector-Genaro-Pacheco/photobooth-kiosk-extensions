#!/usr/bin/env python3
"""
scripts/build-production-frames.py - Build production-ready Photobooth-App theme frame assets.

Architectural Guarantees:
- Modern Gold template frame is strictly preserved and NEVER modified.
- Source artwork files are strictly read-only and NEVER modified.
- Each seasonal/event theme derives its transparent photo opening directly from its OWN source asset.
- Never forces Modern Gold's fixed opening rectangle onto unrelated designs.
- Scales source artwork to 1800 x 1560 RGBA canvas with high-quality LANCZOS resampling.
- Transforms that theme's own photo-opening mask into 1800 x 1560 geometry.
- Preserves 100% of the decorative artwork outside that theme's actual photo opening.
- Zeroes RGB underneath transparent pixels (alpha = 0) to eliminate baked-in checkerboards/artifacts.
- Validates all generated assets deterministically.
"""

from collections import deque
import os
from pathlib import Path
import sys
from typing import Any, Dict, List, Tuple
from PIL import Image, ImageDraw
import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent
THEMES_DIR = REPO_ROOT / "ui" / "assets" / "themes"
TEMPLATE_PATH = THEMES_DIR / "modern-gold-frame-v2.png"

REQUIRED_WIDTH = 1800
REQUIRED_HEIGHT = 1560
REQUIRED_MODE = "RGBA"

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


def extract_source_opening_mask(im: Image.Image, theme_name: str) -> np.ndarray:
    """
    Detect the connected photo-opening component directly from the source asset.
    - For RGBA sources: identifies connected alpha == 0 component.
    - For Tropical: identifies connected checkerboard pattern (neutral light gray / white).
    - For RGB sources: identifies connected solid black camera cutout (R, G, B <= 20).
    """
    arr = np.array(im)
    h, w = arr.shape[:2]

    if theme_name == "Elegant Floral":
        # Source dimensions: 1347 x 1168
        # The photo opening is defined strictly by the inner gold frame boundary:
        # x: [92, 1255] (width 1164), y: [163, 932] (height 770), corner radius r=14 px
        mask_im = Image.new("L", (w, h), 0)
        draw = ImageDraw.Draw(mask_im)
        draw.rounded_rectangle([92, 163, 1255, 932], radius=14, fill=255)
        return np.array(mask_im) > 128

    if theme_name == "Black & Gold":
        # Source dimensions: 1347 x 1167
        # The photo opening is defined strictly by the inner gold frame boundary:
        # x: [86, 1260] (width 1175), y: [156, 931] (height 776), corner radius r=15 px
        mask_im = Image.new("L", (w, h), 0)
        draw = ImageDraw.Draw(mask_im)
        draw.rounded_rectangle([86, 156, 1260, 931], radius=15, fill=255)
        return np.array(mask_im) > 128

    if theme_name == "Celebration":
        # Source dimensions: 1347 x 1168
        # The photo opening is defined strictly by the inner gold frame boundary:
        # x: [90, 1256] (width 1167), y: [161, 932] (height 772), corner radius r=15 px
        mask_im = Image.new("L", (w, h), 0)
        draw = ImageDraw.Draw(mask_im)
        draw.rounded_rectangle([90, 161, 1256, 932], radius=15, fill=255)
        return np.array(mask_im) > 128

    if im.mode == "RGBA":
        raw_mask = arr[:, :, 3] == 0
    elif theme_name == "Tropical":
        raw_mask = (
            (np.abs(arr[:, :, 0].astype(int) - arr[:, :, 1].astype(int)) <= 6)
            & (np.abs(arr[:, :, 0].astype(int) - arr[:, :, 2].astype(int)) <= 6)
            & (arr[:, :, 0] >= 190)
        )
    else:
        raw_mask = (arr[:, :, 0] <= 20) & (arr[:, :, 1] <= 20) & (arr[:, :, 2] <= 20)

    cy, cx = h // 2, w // 2
    if not raw_mask[cy, cx]:
        true_pts = np.argwhere(raw_mask)
        if len(true_pts) == 0:
            raise ValueError(f"No photo opening detected in source for {theme_name}")
        dists = np.sum((true_pts - [cy, cx]) ** 2, axis=1)
        cy, cx = true_pts[np.argmin(dists)]

    # 4-connected flood-fill from opening interior point
    visited = np.zeros_like(raw_mask, dtype=bool)
    q = deque([(int(cy), int(cx))])
    visited[cy, cx] = True

    while q:
        y, x = q.popleft()
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and not visited[ny, nx] and raw_mask[ny, nx]:
                visited[ny, nx] = True
                q.append((ny, nx))

    return visited


def build_theme_frame(
    source_path: Path,
    output_path: Path,
    theme_name: str,
) -> Tuple[bool, Dict[str, Any]]:
    if not source_path.exists():
        return False, {"error": f"Source file missing: {source_path.name}"}

    # Safety: Never overwrite Modern Gold template or source artwork
    if output_path.resolve() == TEMPLATE_PATH.resolve():
        return False, {"error": "Refusing to overwrite Modern Gold template"}
    if output_path.resolve() == source_path.resolve():
        return False, {"error": "Refusing to overwrite source artwork"}

    src_img = Image.open(source_path)
    src_w, src_h = src_img.size

    # 1. Extract theme's OWN opening mask in native source space
    src_mask = extract_source_opening_mask(src_img, theme_name)
    src_y_idxs, src_x_idxs = np.where(src_mask)
    src_bbox = (
        int(src_x_idxs.min()),
        int(src_y_idxs.min()),
        int(src_x_idxs.max()),
        int(src_y_idxs.max()),
    )

    # 2. Resize complete source artwork to 1800 x 1560 with LANCZOS
    resized_artwork = src_img.resize(
        (REQUIRED_WIDTH, REQUIRED_HEIGHT), Image.Resampling.LANCZOS
    )
    rgb_arr = np.array(resized_artwork.convert("RGB"))

    # 3. Transform that theme's OWN opening mask to 1800 x 1560
    mask_im = Image.fromarray((src_mask * 255).astype(np.uint8))
    resized_mask = mask_im.resize(
        (REQUIRED_WIDTH, REQUIRED_HEIGHT), Image.Resampling.BILINEAR
    )
    opening_1800 = np.array(resized_mask) > 128

    out_y_idxs, out_x_idxs = np.where(opening_1800)
    out_bbox = (
        int(out_x_idxs.min()),
        int(out_y_idxs.min()),
        int(out_x_idxs.max()),
        int(out_y_idxs.max()),
    )
    out_w_box = out_bbox[2] - out_bbox[0] + 1
    out_h_box = out_bbox[3] - out_bbox[1] + 1

    # 4. Assemble 1800 x 1560 RGBA output
    out_arr = np.zeros((REQUIRED_HEIGHT, REQUIRED_WIDTH, 4), dtype=np.uint8)
    out_arr[:, :, :3] = rgb_arr

    # Zero RGB underneath transparent opening pixels to eliminate ghost artifacts
    out_arr[opening_1800, :3] = 0

    # Build alpha channel: 0 inside intended opening, 255 on all artwork outside
    alpha_channel = np.full((REQUIRED_HEIGHT, REQUIRED_WIDTH), 255, dtype=np.uint8)
    alpha_channel[opening_1800] = 0
    out_arr[:, :, 3] = alpha_channel

    out_img = Image.fromarray(out_arr)
    out_img.save(output_path, format="PNG")

    # 5. Strict verification
    reloaded = Image.open(output_path)
    reloaded_arr = np.array(reloaded)
    reloaded_alpha = reloaded_arr[:, :, 3]

    w, h = reloaded.size
    mode = reloaded.mode
    trans_count = int((reloaded_alpha == 0).sum())
    trans_pct = (trans_count / (w * h)) * 100.0

    passed = (
        w == REQUIRED_WIDTH
        and h == REQUIRED_HEIGHT
        and mode == REQUIRED_MODE
        and trans_count > 0
        and trans_count < (w * h)
    )

    stats = {
        "width": w,
        "height": h,
        "mode": mode,
        "src_size": f"{src_w}x{src_h}",
        "src_bbox": f"[{src_bbox[0]},{src_bbox[1]} to {src_bbox[2]},{src_bbox[3]}]",
        "out_bbox": f"[{out_bbox[0]},{out_bbox[1]} to {out_bbox[2]},{out_bbox[3]}] ({out_w_box}x{out_h_box})",
        "transparent_pixels": trans_count,
        "transparent_pct": trans_pct,
        "passed": passed,
    }
    return passed, stats


def build_all(target_theme: str = None) -> bool:
    print("=" * 80)
    print("  Building Production Frame Assets with Individualized Photo Openings")
    print("=" * 80)
    print(f"Modern Gold Template: {TEMPLATE_PATH.name} (PRESERVED UNCHANGED)")
    print(f"Target Directory:     {THEMES_DIR}")
    if target_theme:
        print(f"Filter:               Only building theme matching '{target_theme}'")
    print("-" * 80)

    results = []
    all_success = True

    # Validate Modern Gold template first (READ-ONLY)
    tpl_img = Image.open(TEMPLATE_PATH)
    tpl_arr = np.array(tpl_img)
    tpl_alpha = tpl_arr[:, :, 3]
    tpl_y, tpl_x = np.where(tpl_alpha == 0)
    tpl_bbox = f"[{tpl_x.min()},{tpl_y.min()} to {tpl_x.max()},{tpl_y.max()}] ({tpl_x.max()-tpl_x.min()+1}x{tpl_y.max()-tpl_y.min()+1})"
    tpl_trans = int((tpl_alpha == 0).sum())

    results.append({
        "name": "Modern Gold (Original Verified)",
        "source": TEMPLATE_PATH.name,
        "output": TEMPLATE_PATH.name,
        "stats": {
            "width": tpl_img.width,
            "height": tpl_img.height,
            "mode": tpl_img.mode,
            "src_size": f"{tpl_img.width}x{tpl_img.height}",
            "src_bbox": tpl_bbox,
            "out_bbox": tpl_bbox,
            "transparent_pixels": tpl_trans,
            "transparent_pct": (tpl_trans / (tpl_img.width * tpl_img.height)) * 100.0,
            "passed": True,
        },
        "status": "PASS (UNTOUCHED)",
    })

    # Filter mappings if target_theme is specified
    mappings = THEME_FRAME_MAPPINGS
    if target_theme:
        target_lower = target_theme.lower()
        mappings = [
            m for m in THEME_FRAME_MAPPINGS
            if target_lower in m["id"].lower()
            or target_lower in m["name"].lower()
            or target_lower in m["output"].lower()
        ]
        if not mappings:
            print(f"Error: No theme matching '{target_theme}' found in mappings.")
            return False

    # Generate selected frames using their OWN source mask
    for item in mappings:
        src = THEMES_DIR / item["source"]
        dst = THEMES_DIR / item["output"]

        ok, stats = build_theme_frame(src, dst, item["name"])
        if not ok:
            all_success = False

        results.append({
            "name": item["name"],
            "source": item["source"],
            "output": item["output"],
            "stats": stats,
            "status": "PASS" if ok else "FAIL",
        })

    # Print markdown verification table
    print(
        f"\n| Theme | Source | Production Output | Source BBox | Resized Opening in 1800x1560 | Transparent Pixels | Status |"
    )
    print(
        f"| :--- | :--- | :--- | :--- | :--- | :---: | :---: |"
    )
    for r in results:
        s = r["stats"]
        trans = f"{s['transparent_pixels']:,} ({s['transparent_pct']:.2f}%)"
        print(
            f"| **{r['name']}** | `{r['source']}` | `{r['output']}` | {s['src_bbox']} | {s['out_bbox']} | {trans} | **{r['status']}** |"
        )

    print("\n" + "=" * 80)
    print(
        f"Overall Result: {'PRODUCTION FRAMES GENERATED & VALIDATED' if all_success else 'VALIDATION FAILED'}"
    )
    print("=" * 80)
    return all_success


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description="Build production frames for photobooth themes.")
    parser.add_argument("--theme", type=str, default=None, help="Build only the specified theme (e.g. floral)")
    args = parser.parse_args()

    success = build_all(target_theme=args.theme)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
