#!/usr/bin/env python3
"""
scripts/read-theme-config.py - Read-only live configuration inspector for Photobooth-App.

Reference: docs/photobooth-config-contract.md
Calls GET /api/config (no authentication, read-only).
Inspects and prints only verified theme-related fields.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
from typing import Any, Dict

DEFAULT_BASE_URL = "http://192.168.2.3:8000"


def fetch_config(base_url: str) -> Dict[str, Any]:
    """
    Fetch configuration from Photobooth-App via GET /api/config.
    Read-only, no authentication.
    """
    endpoint = f"{base_url.rstrip('/')}/api/config"
    req = urllib.request.Request(endpoint, headers={"Accept": "application/json"})

    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status != 200:
                sys.stderr.write(f"Error: Unexpected HTTP status {resp.status} from {endpoint}\n")
                sys.exit(1)
            raw_data = resp.read()
            return json.loads(raw_data.decode("utf-8"))
    except urllib.error.HTTPError as err:
        sys.stderr.write(f"Error: HTTP {err.code} {err.reason} from {endpoint}\n")
        sys.exit(1)
    except urllib.error.URLError as err:
        sys.stderr.write(f"Error: Failed to reach Photobooth-App at {endpoint}: {err.reason}\n")
        sys.exit(1)
    except TimeoutError:
        sys.stderr.write(f"Error: Connection timed out reaching {endpoint}\n")
        sys.exit(1)
    except json.JSONDecodeError as err:
        sys.stderr.write(f"Error: Invalid JSON received from {endpoint}: {err}\n")
        sys.exit(1)
    except Exception as err:
        sys.stderr.write(f"Error: Unexpected error querying {endpoint}: {err}\n")
        sys.exit(1)


def extract_verified_fields(config: Dict[str, Any]) -> Dict[str, Any]:
    """
    Extract only the verified theme-related fields documented in
    docs/photobooth-config-contract.md.
    Fails clearly if any verified field is missing.
    """
    try:
        actions = config["actions"]
    except KeyError:
        sys.stderr.write("Error: Missing required section 'actions'\n")
        sys.exit(1)

    try:
        images = actions["image"]
        if not isinstance(images, list) or len(images) == 0:
            sys.stderr.write("Error: Missing or empty list 'actions.image'\n")
            sys.exit(1)
        image_0 = images[0]
    except KeyError:
        sys.stderr.write("Error: Missing field 'actions.image'\n")
        sys.exit(1)

    try:
        image_processing = image_0["processing"]
    except KeyError:
        sys.stderr.write("Error: Missing field 'actions.image[0].processing'\n")
        sys.exit(1)

    if "img_frame_enable" not in image_processing:
        sys.stderr.write("Error: Missing verified field 'actions.image[0].processing.img_frame_enable'\n")
        sys.exit(1)
    img_frame_enable = image_processing["img_frame_enable"]

    if "img_frame_file" not in image_processing:
        sys.stderr.write("Error: Missing verified field 'actions.image[0].processing.img_frame_file'\n")
        sys.exit(1)
    img_frame_file = image_processing["img_frame_file"]

    try:
        collages = actions["collage"]
        if not isinstance(collages, list) or len(collages) == 0:
            sys.stderr.write("Error: Missing or empty list 'actions.collage'\n")
            sys.exit(1)
        collage_0 = collages[0]
    except KeyError:
        sys.stderr.write("Error: Missing field 'actions.collage'\n")
        sys.exit(1)

    try:
        collage_processing = collage_0["processing"]
    except KeyError:
        sys.stderr.write("Error: Missing field 'actions.collage[0].processing'\n")
        sys.exit(1)

    if "canvas_img_front_file" not in collage_processing:
        sys.stderr.write("Error: Missing verified field 'actions.collage[0].processing.canvas_img_front_file'\n")
        sys.exit(1)
    canvas_img_front_file = collage_processing["canvas_img_front_file"]

    try:
        uisettings = config["uisettings"]
    except KeyError:
        sys.stderr.write("Error: Missing required section 'uisettings'\n")
        sys.exit(1)

    if "enable_livestream_frameoverlay" not in uisettings:
        sys.stderr.write("Error: Missing verified field 'uisettings.enable_livestream_frameoverlay'\n")
        sys.exit(1)
    enable_livestream_frameoverlay = uisettings["enable_livestream_frameoverlay"]

    if "livestream_frameoverlay_image" not in uisettings:
        sys.stderr.write("Error: Missing verified field 'uisettings.livestream_frameoverlay_image'\n")
        sys.exit(1)
    livestream_frameoverlay_image = uisettings["livestream_frameoverlay_image"]

    return {
        "actions.image[0].processing.img_frame_enable": img_frame_enable,
        "actions.image[0].processing.img_frame_file": img_frame_file,
        "actions.collage[0].processing.canvas_img_front_file": canvas_img_front_file,
        "uisettings.enable_livestream_frameoverlay": enable_livestream_frameoverlay,
        "uisettings.livestream_frameoverlay_image": livestream_frameoverlay_image,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Read and verify live Photobooth-App theme configuration (GET /api/config)."
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_BASE_URL,
        help=f"Base URL of Photobooth-App (default: {DEFAULT_BASE_URL})",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print verified fields as JSON",
    )

    args = parser.parse_args()

    config = fetch_config(args.url)
    verified = extract_verified_fields(config)

    if args.json:
        print(json.dumps(verified, indent=2))
    else:
        for key, val in verified.items():
            print(f"{key}: {json.dumps(val)}")


if __name__ == "__main__":
    main()
