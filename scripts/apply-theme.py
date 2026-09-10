#!/usr/bin/env python3
"""
scripts/apply-theme.py - Theme applicator for Photobooth-App kiosk.

Phase 1 implementation:
- Builds Photobooth-App configuration patches for supported themes ('modern-gold', 'none').
- Prints the patch as JSON.
- Offline only: no network/API calls, no local file modifications, standard library only.
"""

import argparse
import json
import sys
from typing import Any, Dict

THEME_CONFIGS: Dict[str, Dict[str, Any]] = {
    "modern-gold": {
        "description": "Modern Gold frame and collage theme",
        "img_frame_enable": True,
        "img_frame_file": "userdata/modern-gold-frame-v2.png",
        "canvas_img_front_file": "userdata/modern-gold-collage.png",
        "enable_livestream_frameoverlay": True,
        "livestream_frameoverlay_image": "userdata/modern-gold-frame-v2.png",
    },
    "none": {
        "description": "No theme overlays (clean/default)",
        "img_frame_enable": False,
        "img_frame_file": None,
        "canvas_img_front_file": None,
        "enable_livestream_frameoverlay": False,
        "livestream_frameoverlay_image": None,
    },
}


def build_config_patch(theme_name: str) -> Dict[str, Any]:
    """
    Build the Photobooth-App configuration patch dictionary for the specified theme.

    Targeting verified Photobooth-App config schema fields:
    - actions.image[0].processing.img_frame_enable
    - actions.image[0].processing.img_frame_file
    - actions.collage[0].processing.canvas_img_front_file
    - uisettings.enable_livestream_frameoverlay
    - uisettings.livestream_frameoverlay_image
    """
    if theme_name not in THEME_CONFIGS:
        raise ValueError(
            f"Unsupported theme: '{theme_name}'. Supported themes: {', '.join(THEME_CONFIGS.keys())}"
        )

    theme_info = THEME_CONFIGS[theme_name]

    return {
        "actions": {
            "image": [
                {
                    "processing": {
                        "img_frame_enable": theme_info["img_frame_enable"],
                        "img_frame_file": theme_info["img_frame_file"],
                    }
                }
            ],
            "collage": [
                {
                    "processing": {
                        "canvas_img_front_file": theme_info["canvas_img_front_file"],
                    }
                }
            ],
        },
        "uisettings": {
            "enable_livestream_frameoverlay": theme_info["enable_livestream_frameoverlay"],
            "livestream_frameoverlay_image": theme_info["livestream_frameoverlay_image"],
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build and apply Photobooth-App theme configuration patches."
    )
    parser.add_argument(
        "theme",
        choices=list(THEME_CONFIGS.keys()),
        help=f"Theme to apply ({', '.join(THEME_CONFIGS.keys())})",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print the Photobooth-App config patch as JSON",
    )

    args = parser.parse_args()

    try:
        patch = build_config_patch(args.theme)
    except ValueError as err:
        sys.stderr.write(f"Error: {err}\n")
        sys.exit(1)

    if args.json:
        print(json.dumps(patch, indent=2))
    else:
        print(f"Selected theme: {args.theme}")
        print("Photobooth-App Config Patch (Phase 1 Preview):")
        print(json.dumps(patch, indent=2))


if __name__ == "__main__":
    main()
