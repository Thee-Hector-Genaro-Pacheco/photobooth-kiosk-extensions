#!/usr/bin/env python3
"""
scripts/apply-theme.py - Theme applicator for Photobooth-App kiosk.

Sources of truth:
- docs/photobooth-config-contract.md
- docs/photobooth-auth-contract.md
- docs/config-patch-semantics.md

Features:
- Offline patch preview: generates Photobooth-App JSON config patches for 'modern-gold' and 'none'.
- Live apply (--apply): safely authenticates via OAuth2, performs a read-modify-write cycle
  updating only verified fields, and validates resulting configuration.
"""

import argparse
import getpass
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Tuple

DEFAULT_BASE_URL = "http://192.168.2.3:8000"

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


def get_credentials() -> Tuple[str, str]:
    """
    Retrieve admin credentials from environment variables or interactive prompt.
    Never echoes password on interactive input.
    """
    username = os.environ.get("PHOTOBOOTH_ADMIN_USERNAME", "").strip()
    password = os.environ.get("PHOTOBOOTH_ADMIN_PASSWORD", "").strip()

    if not username:
        try:
            username = input("Enter admin username: ").strip()
        except (EOFError, KeyboardInterrupt):
            sys.stderr.write("Error: Username prompt interrupted or unavailable.\n")
            sys.exit(1)

    if not password:
        try:
            password = getpass.getpass("Enter admin password: ").strip()
        except (EOFError, KeyboardInterrupt):
            sys.stderr.write("Error: Password prompt interrupted or unavailable.\n")
            sys.exit(1)

    if not username or not password:
        sys.stderr.write("Error: Both username and password are required.\n")
        sys.exit(1)

    return username, password


def authenticate(base_url: str, username: str, password: str) -> str:
    """
    Authenticate against POST /api/admin/auth/token using application/x-www-form-urlencoded.
    Returns access_token. Never prints or persists password or raw token.
    """
    token_url = f"{base_url.rstrip('/')}/api/admin/auth/token"
    form_data = urllib.parse.urlencode({"username": username, "password": password}).encode("utf-8")

    req = urllib.request.Request(
        token_url,
        data=form_data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status != 200:
                sys.stderr.write(f"Error: Unexpected HTTP status {resp.status} from {token_url}\n")
                sys.exit(1)
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        if err.code == 401:
            sys.stderr.write("Error: Authentication failed (HTTP 401). Incorrect username or password.\n")
        else:
            sys.stderr.write(f"Error: HTTP {err.code} {err.reason} from {token_url}\n")
        sys.exit(1)
    except urllib.error.URLError as err:
        sys.stderr.write(f"Error: Failed to reach Photobooth-App at {token_url}: {err.reason}\n")
        sys.exit(1)
    except TimeoutError:
        sys.stderr.write(f"Error: Connection timed out reaching {token_url}\n")
        sys.exit(1)
    except json.JSONDecodeError as err:
        sys.stderr.write(f"Error: Invalid JSON response from {token_url}: {err}\n")
        sys.exit(1)

    access_token = payload.get("access_token")
    if not access_token:
        sys.stderr.write("Error: Missing 'access_token' in authentication response.\n")
        sys.exit(1)

    return access_token


def fetch_full_config(base_url: str) -> Dict[str, Any]:
    """
    Fetch complete current configuration from GET /api/config.
    """
    config_url = f"{base_url.rstrip('/')}/api/config"
    req = urllib.request.Request(config_url, headers={"Accept": "application/json"})

    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status != 200:
                sys.stderr.write(f"Error: Unexpected HTTP status {resp.status} from {config_url}\n")
                sys.exit(1)
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        sys.stderr.write(f"Error: HTTP {err.code} {err.reason} fetching config from {config_url}\n")
        sys.exit(1)
    except urllib.error.URLError as err:
        sys.stderr.write(f"Error: Failed to reach Photobooth-App at {config_url}: {err.reason}\n")
        sys.exit(1)
    except TimeoutError:
        sys.stderr.write(f"Error: Connection timed out reaching {config_url}\n")
        sys.exit(1)
    except json.JSONDecodeError as err:
        sys.stderr.write(f"Error: Invalid JSON received from {config_url}: {err}\n")
        sys.exit(1)


def patch_full_config(base_url: str, access_token: str, full_config: Dict[str, Any]) -> None:
    """
    Submit full updated configuration to PATCH /api/admin/config/app?reload=false.
    """
    patch_url = f"{base_url.rstrip('/')}/api/admin/config/app?reload=false"
    body_bytes = json.dumps(full_config).encode("utf-8")

    req = urllib.request.Request(
        patch_url,
        data=body_bytes,
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="PATCH",
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status != 200:
                sys.stderr.write(f"Error: Unexpected HTTP status {resp.status} from {patch_url}\n")
                sys.exit(1)
    except urllib.error.HTTPError as err:
        err_body = ""
        try:
            err_body = err.read().decode("utf-8")
        except Exception:
            pass
        sys.stderr.write(f"Error: HTTP {err.code} {err.reason} from {patch_url}\n")
        if err_body:
            sys.stderr.write(f"Response: {err_body}\n")
        sys.exit(1)
    except urllib.error.URLError as err:
        sys.stderr.write(f"Error: Failed to reach Photobooth-App at {patch_url}: {err.reason}\n")
        sys.exit(1)
    except TimeoutError:
        sys.stderr.write(f"Error: Connection timed out during PATCH at {patch_url}\n")
        sys.exit(1)


def extract_verified_values(config: Dict[str, Any]) -> Dict[str, Any]:
    """
    Extract and return the five verified theme fields from a configuration dictionary.
    """
    try:
        img_frame_enable = config["actions"]["image"][0]["processing"]["img_frame_enable"]
        img_frame_file = config["actions"]["image"][0]["processing"]["img_frame_file"]
        canvas_img_front_file = config["actions"]["collage"][0]["processing"]["canvas_img_front_file"]
        enable_livestream_frameoverlay = config["uisettings"]["enable_livestream_frameoverlay"]
        livestream_frameoverlay_image = config["uisettings"]["livestream_frameoverlay_image"]
    except (KeyError, IndexError, TypeError) as err:
        sys.stderr.write(f"Error: Configuration missing verified field structure: {err}\n")
        sys.exit(1)

    return {
        "actions.image[0].processing.img_frame_enable": img_frame_enable,
        "actions.image[0].processing.img_frame_file": img_frame_file,
        "actions.collage[0].processing.canvas_img_front_file": canvas_img_front_file,
        "uisettings.enable_livestream_frameoverlay": enable_livestream_frameoverlay,
        "uisettings.livestream_frameoverlay_image": livestream_frameoverlay_image,
    }


def apply_theme_live(theme_name: str, base_url: str) -> None:
    """
    Safely apply theme to live Photobooth-App using Read-Modify-Write strategy.
    """
    theme_info = THEME_CONFIGS[theme_name]

    # 1. Authenticate
    username, password = get_credentials()
    access_token = authenticate(base_url, username, password)

    # 2. GET complete current configuration
    full_config = fetch_full_config(base_url)

    # 3. Modify ONLY verified theme fields in the full config object
    try:
        full_config["actions"]["image"][0]["processing"]["img_frame_enable"] = theme_info["img_frame_enable"]
        full_config["actions"]["image"][0]["processing"]["img_frame_file"] = theme_info["img_frame_file"]
        full_config["actions"]["collage"][0]["processing"]["canvas_img_front_file"] = theme_info["canvas_img_front_file"]
        full_config["uisettings"]["enable_livestream_frameoverlay"] = theme_info["enable_livestream_frameoverlay"]
        full_config["uisettings"]["livestream_frameoverlay_image"] = theme_info["livestream_frameoverlay_image"]

        # Prevent masked password from GET /api/config from overwriting real admin password
        if "common" in full_config and isinstance(full_config["common"], dict):
            full_config["common"]["admin_password"] = password
        else:
            full_config["common"] = {"admin_password": password}
    except (KeyError, IndexError, TypeError) as err:
        sys.stderr.write(f"Error: Current config missing expected structure for modification: {err}\n")
        sys.exit(1)

    # 4. PATCH full modified configuration
    patch_full_config(base_url, access_token, full_config)

    # 5. Verify by re-reading config from server
    verified_config = fetch_full_config(base_url)
    verified_values = extract_verified_values(verified_config)

    # 6. Compare actual vs expected
    expected_values = {
        "actions.image[0].processing.img_frame_enable": theme_info["img_frame_enable"],
        "actions.image[0].processing.img_frame_file": theme_info["img_frame_file"],
        "actions.collage[0].processing.canvas_img_front_file": theme_info["canvas_img_front_file"],
        "uisettings.enable_livestream_frameoverlay": theme_info["enable_livestream_frameoverlay"],
        "uisettings.livestream_frameoverlay_image": theme_info["livestream_frameoverlay_image"],
    }

    mismatches: List[str] = []
    for field_key, expected_val in expected_values.items():
        actual_val = verified_values.get(field_key)
        if actual_val != expected_val:
            mismatches.append(
                f"{field_key}: expected {json.dumps(expected_val)}, got {json.dumps(actual_val)}"
            )

    # 7. Print results
    print(f"Requested theme: {theme_name}")
    print("HTTP success: 200 OK (PATCH /api/admin/config/app?reload=false)")
    print("Verified resulting values:")
    for field_key, actual_val in verified_values.items():
        print(f"  {field_key}: {json.dumps(actual_val)}")

    if mismatches:
        sys.stderr.write("Error: Verification failed! Field mismatches detected:\n")
        for mismatch in mismatches:
            sys.stderr.write(f"  - {mismatch}\n")
        sys.exit(1)

    print("Theme verification PASSED")


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
        help="Print the Photobooth-App config patch as JSON (offline)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply theme to live Photobooth-App instance",
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_BASE_URL,
        help=f"Base URL of Photobooth-App instance (default: {DEFAULT_BASE_URL})",
    )

    args = parser.parse_args()

    if args.apply:
        apply_theme_live(args.theme, args.url)
    else:
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
