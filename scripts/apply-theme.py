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
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_BASE_URL = "http://192.168.2.3:8000"

THEME_CONFIGS: Dict[str, Dict[str, Any]] = {
    "modern-gold": {
        "name": "Modern Gold",
        "description": "Modern Gold frame and collage theme",
        "preview_asset": "assets/themes/modern-gold-frame-v2.png",
        "production_frame": "userdata/modern-gold-frame-v2.png",
        "img_frame_enable": True,
        "img_frame_file": "userdata/modern-gold-frame-v2.png",
        "canvas_img_front_enable": True,
        "canvas_img_front_file": "userdata/modern-gold-collage.png",
        "enable_livestream_frameoverlay": True,
        "livestream_frameoverlay_image": "userdata/modern-gold-frame-v2.png",
    },
    "tropical": {
        "name": "Tropical",
        "description": "Tropical palm and floral theme",
        "preview_asset": "assets/themes/tropical-frame-v1.png",
        "production_frame": "userdata/tropical-frame-v1.png",
        "img_frame_enable": True,
        "img_frame_file": "userdata/tropical-frame-v1.png",
        "canvas_img_front_enable": False,
        "canvas_img_front_file": None,
        "enable_livestream_frameoverlay": True,
        "livestream_frameoverlay_image": "userdata/tropical-frame-v1.png",
    },
    "black-gold": {
        "name": "Black & Gold",
        "description": "Black & Gold elegant celebration theme",
        "preview_asset": "assets/themes/black-and-gold-frame-v1.png",
        "production_frame": "userdata/black-and-gold-frame-v1.png",
        "img_frame_enable": True,
        "img_frame_file": "userdata/black-and-gold-frame-v1.png",
        "canvas_img_front_enable": False,
        "canvas_img_front_file": None,
        "enable_livestream_frameoverlay": True,
        "livestream_frameoverlay_image": "userdata/black-and-gold-frame-v1.png",
    },
    "floral": {
        "name": "Elegant Floral",
        "description": "Elegant Floral gold accent theme",
        "preview_asset": "assets/themes/floral-frame-v1.png",
        "production_frame": "userdata/floral-frame-v1.png",
        "img_frame_enable": True,
        "img_frame_file": "userdata/floral-frame-v1.png",
        "canvas_img_front_enable": False,
        "canvas_img_front_file": None,
        "enable_livestream_frameoverlay": True,
        "livestream_frameoverlay_image": "userdata/floral-frame-v1.png",
    },
    "celebration": {
        "name": "Celebration",
        "description": "Festive balloons and confetti celebration theme",
        "preview_asset": "assets/themes/confetti-frame-v1.png",
        "production_frame": "userdata/confetti-frame-v1.png",
        "img_frame_enable": True,
        "img_frame_file": "userdata/confetti-frame-v1.png",
        "canvas_img_front_enable": False,
        "canvas_img_front_file": None,
        "enable_livestream_frameoverlay": True,
        "livestream_frameoverlay_image": "userdata/confetti-frame-v1.png",
    },
    "halloween": {
        "name": "Halloween",
        "description": "Spooky Halloween festive theme",
        "preview_asset": "assets/themes/halloween-frame-v1.png",
        "production_frame": "userdata/halloween-frame-v1.png",
        "img_frame_enable": True,
        "img_frame_file": "userdata/halloween-frame-v1.png",
        "canvas_img_front_enable": False,
        "canvas_img_front_file": None,
        "enable_livestream_frameoverlay": True,
        "livestream_frameoverlay_image": "userdata/halloween-frame-v1.png",
    },
    "thanksgiving": {
        "name": "Thanksgiving",
        "description": "Rustic Thanksgiving harvest theme",
        "preview_asset": "assets/themes/thanksgiving-frame-v1.png",
        "production_frame": "userdata/thanksgiving-frame-v1.png",
        "img_frame_enable": True,
        "img_frame_file": "userdata/thanksgiving-frame-v1.png",
        "canvas_img_front_enable": False,
        "canvas_img_front_file": None,
        "enable_livestream_frameoverlay": True,
        "livestream_frameoverlay_image": "userdata/thanksgiving-frame-v1.png",
    },
    "christmas": {
        "name": "Christmas",
        "description": "Merry Christmas snowy festive theme",
        "preview_asset": "assets/themes/christmas-frame-v1.png",
        "production_frame": "userdata/christmas-frame-v1.png",
        "img_frame_enable": True,
        "img_frame_file": "userdata/christmas-frame-v1.png",
        "canvas_img_front_enable": False,
        "canvas_img_front_file": None,
        "enable_livestream_frameoverlay": True,
        "livestream_frameoverlay_image": "userdata/christmas-frame-v1.png",
    },
    "new-year": {
        "name": "New Year",
        "description": "Glamorous Black & Gold New Year theme",
        "preview_asset": "assets/themes/new-year-frame-v1.png",
        "production_frame": "userdata/new-year-frame-v1.png",
        "img_frame_enable": True,
        "img_frame_file": "userdata/new-year-frame-v1.png",
        "canvas_img_front_enable": False,
        "canvas_img_front_file": None,
        "enable_livestream_frameoverlay": True,
        "livestream_frameoverlay_image": "userdata/new-year-frame-v1.png",
    },
    "none": {
        "name": "No Border",
        "description": "No theme overlays (clean/default)",
        "preview_asset": None,
        "production_frame": None,
        "img_frame_enable": False,
        "img_frame_file": None,
        "canvas_img_front_enable": False,
        "canvas_img_front_file": None,
        "enable_livestream_frameoverlay": False,
        "livestream_frameoverlay_image": None,
    },
}

# Data-driven generic filter configurations mapping
# Maps generic user-facing filter ID to display attributes and verified Photobooth-App enum value
FILTER_CONFIGS: Dict[str, Dict[str, Any]] = {
    "original": {
        "name": "Original",
        "description": "Natural colors (no filter)",
        "backend_value": "original",
        "css_filter": "none",
    },
    "black-and-white": {
        "name": "Black & White",
        "description": "Classic high-contrast monochrome (Inkwell)",
        "backend_value": "FilterPilgram2.inkwell",
        "css_filter": "grayscale(100%) contrast(110%)",
    },
    "vintage": {
        "name": "Vintage",
        "description": "Warm retro 1977 look (_1977)",
        "backend_value": "FilterPilgram2._1977",
        "css_filter": "sepia(40%) contrast(105%) brightness(105%)",
    },
    "warm": {
        "name": "Warm",
        "description": "Soft warm pastel tone (Aden)",
        "backend_value": "FilterPilgram2.aden",
        "css_filter": "sepia(20%) saturate(120%) brightness(105%)",
    },
    "vibrant": {
        "name": "Vibrant",
        "description": "Vivid saturated tones (Clarendon)",
        "backend_value": "FilterPilgram2.clarendon",
        "css_filter": "contrast(115%) saturate(125%)",
    },
    "film": {
        "name": "Film",
        "description": "Moody desaturated film look (Moon)",
        "backend_value": "FilterPilgram2.moon",
        "css_filter": "grayscale(90%) contrast(105%) brightness(95%)",
    },
}


def resolve_filter_key(filter_name: str) -> str:
    """
    Resolve and normalize user-provided filter name or alias to canonical FILTER_CONFIGS key.
    """
    if not filter_name:
        return "original"
    normalized = filter_name.strip().lower()
    if normalized in ("inkwell", "bw", "b&w"):
        return "black-and-white"
    if normalized in FILTER_CONFIGS:
        return normalized
    for key, info in FILTER_CONFIGS.items():
        if info.get("backend_value", "").lower() == normalized:
            return key
    return normalized


def build_filter_patch(filter_name: str) -> Dict[str, Any]:
    """
    Build the Photobooth-App configuration patch dictionary for the specified filter.

    Targeting verified Photobooth-App config schema field:
    - actions.image[0].processing.image_filter
    """
    resolved_key = resolve_filter_key(filter_name)
    if resolved_key not in FILTER_CONFIGS:
        raise ValueError(
            f"Unsupported filter: '{filter_name}'. Supported filters: {', '.join(FILTER_CONFIGS.keys())}"
        )

    filter_info = FILTER_CONFIGS[resolved_key]
    return {
        "actions": {
            "image": [
                {
                    "processing": {
                        "image_filter": filter_info["backend_value"],
                    }
                }
            ]
        }
    }


def build_config_patch(theme_name: str) -> Dict[str, Any]:
    """
    Build the Photobooth-App configuration patch dictionary for the specified theme.

    Targeting verified Photobooth-App config schema fields:
    - actions.image[0].processing.img_frame_enable
    - actions.image[0].processing.img_frame_file
    - actions.collage[0].processing.canvas_img_front_enable
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
                        "canvas_img_front_enable": theme_info["canvas_img_front_enable"],
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


def get_credentials(interactive: bool = True) -> Tuple[str, str]:
    """
    Retrieve admin credentials from environment variables or interactive prompt.
    Never echoes password on interactive input.
    If interactive is False, never prompts; raises RuntimeError if credentials missing.
    """
    username = os.environ.get("PHOTOBOOTH_ADMIN_USERNAME", "").strip() or "admin"
    password = os.environ.get("PHOTOBOOTH_ADMIN_PASSWORD", "").strip()

    if not password and not interactive:
        raise RuntimeError(
            "PHOTOBOOTH_ADMIN_PASSWORD environment variable is not set. "
            "Cannot prompt interactively during HTTP request."
        )

    if not username:
        try:
            username = input("Enter admin username: ").strip()
        except (EOFError, KeyboardInterrupt):
            raise RuntimeError("Username prompt interrupted or unavailable.")

    if not password:
        try:
            password = getpass.getpass("Enter admin password: ").strip()
        except (EOFError, KeyboardInterrupt):
            raise RuntimeError("Password prompt interrupted or unavailable.")

    if not username or not password:
        raise RuntimeError("Both username and password are required.")

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
                raise RuntimeError(f"Unexpected HTTP status {resp.status} from {token_url}")
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        if err.code == 401:
            raise RuntimeError("Authentication failed (HTTP 401). Incorrect username or password.")
        raise RuntimeError(f"HTTP {err.code} {err.reason} from {token_url}")
    except urllib.error.URLError as err:
        raise RuntimeError(f"Failed to reach Photobooth-App at {token_url}: {err.reason}")
    except TimeoutError:
        raise RuntimeError(f"Connection timed out reaching {token_url}")
    except json.JSONDecodeError as err:
        raise RuntimeError(f"Invalid JSON response from {token_url}: {err}")

    access_token = payload.get("access_token")
    if not access_token:
        raise RuntimeError("Missing 'access_token' in authentication response.")

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
                raise RuntimeError(f"Unexpected HTTP status {resp.status} from {config_url}")
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        raise RuntimeError(f"HTTP {err.code} {err.reason} fetching config from {config_url}")
    except urllib.error.URLError as err:
        raise RuntimeError(f"Failed to reach Photobooth-App at {config_url}: {err.reason}")
    except TimeoutError:
        raise RuntimeError(f"Connection timed out reaching {config_url}")
    except json.JSONDecodeError as err:
        raise RuntimeError(f"Invalid JSON received from {config_url}: {err}")


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
                raise RuntimeError(f"Unexpected HTTP status {resp.status} from {patch_url}")
    except urllib.error.HTTPError as err:
        err_body = ""
        try:
            err_body = err.read().decode("utf-8")
        except Exception:
            pass
        msg = f"HTTP {err.code} {err.reason} from {patch_url}"
        if err_body:
            msg += f" - Response: {err_body}"
        raise RuntimeError(msg)
    except urllib.error.URLError as err:
        raise RuntimeError(f"Failed to reach Photobooth-App at {patch_url}: {err.reason}")
    except TimeoutError:
        raise RuntimeError(f"Connection timed out during PATCH at {patch_url}")


def extract_verified_values(config: Dict[str, Any]) -> Dict[str, Any]:
    """
    Extract and return the verified theme fields from a configuration dictionary.
    """
    try:
        img_frame_enable = config["actions"]["image"][0]["processing"]["img_frame_enable"]
        img_frame_file = config["actions"]["image"][0]["processing"]["img_frame_file"]
        canvas_img_front_enable = config["actions"]["collage"][0]["processing"]["canvas_img_front_enable"]
        canvas_img_front_file = config["actions"]["collage"][0]["processing"]["canvas_img_front_file"]
        enable_livestream_frameoverlay = config["uisettings"]["enable_livestream_frameoverlay"]
        livestream_frameoverlay_image = config["uisettings"]["livestream_frameoverlay_image"]
    except (KeyError, IndexError, TypeError) as err:
        sys.stderr.write(f"Error: Configuration missing verified field structure: {err}\n")
        sys.exit(1)

    return {
        "actions.image[0].processing.img_frame_enable": img_frame_enable,
        "actions.image[0].processing.img_frame_file": img_frame_file,
        "actions.collage[0].processing.canvas_img_front_enable": canvas_img_front_enable,
        "actions.collage[0].processing.canvas_img_front_file": canvas_img_front_file,
        "uisettings.enable_livestream_frameoverlay": enable_livestream_frameoverlay,
        "uisettings.livestream_frameoverlay_image": livestream_frameoverlay_image,
    }


def apply_config_live(
    theme_name: Optional[str] = None,
    filter_name: Optional[str] = None,
    base_url: str = DEFAULT_BASE_URL,
    interactive: bool = True,
) -> Dict[str, Any]:
    """
    Safely apply theme and/or photo filter to live Photobooth-App using Read-Modify-Write strategy.

    Guarantees:
    - Theme changes NEVER reset or overwrite the selected photo filter
    - Filter changes NEVER reset or overwrite the selected theme
    - Preserves all collage settings (completely untouched)
    - Preserves real admin password
    - Always performs full-config PATCH with reload=false
    - Verifies all modified fields against server state after PATCH
    """
    if not theme_name and not filter_name:
        raise ValueError("At least one of theme_name or filter_name must be provided.")

    theme_info = None
    if theme_name:
        if theme_name not in THEME_CONFIGS:
            raise ValueError(
                f"Unsupported theme: '{theme_name}'. Supported themes: {', '.join(THEME_CONFIGS.keys())}"
            )
        theme_info = THEME_CONFIGS[theme_name]

    filter_info = None
    target_filter_value = None
    if filter_name:
        resolved_filter = resolve_filter_key(filter_name)
        if resolved_filter not in FILTER_CONFIGS:
            raise ValueError(
                f"Unsupported filter: '{filter_name}'. Supported filters: {', '.join(FILTER_CONFIGS.keys())}"
            )
        filter_info = FILTER_CONFIGS[resolved_filter]
        target_filter_value = filter_info["backend_value"]

    # 1. Authenticate
    username, password = get_credentials(interactive=interactive)
    access_token = authenticate(base_url, username, password)

    # 2. GET complete current configuration
    full_config = fetch_full_config(base_url)

    # 3. Modify verified theme and/or filter fields in the full config object
    try:
        if theme_info:
            full_config["actions"]["image"][0]["processing"]["img_frame_enable"] = theme_info["img_frame_enable"]
            full_config["actions"]["image"][0]["processing"]["img_frame_file"] = theme_info["img_frame_file"]
            full_config["actions"]["collage"][0]["processing"]["canvas_img_front_enable"] = theme_info["canvas_img_front_enable"]
            full_config["actions"]["collage"][0]["processing"]["canvas_img_front_file"] = theme_info["canvas_img_front_file"]
            full_config["uisettings"]["enable_livestream_frameoverlay"] = theme_info["enable_livestream_frameoverlay"]
            full_config["uisettings"]["livestream_frameoverlay_image"] = theme_info["livestream_frameoverlay_image"]

        if target_filter_value is not None:
            full_config["actions"]["image"][0]["processing"]["image_filter"] = target_filter_value

        # Prevent masked password from GET /api/config from overwriting real admin password
        if "common" in full_config and isinstance(full_config["common"], dict):
            full_config["common"]["admin_password"] = password
        else:
            full_config["common"] = {"admin_password": password}
    except (KeyError, IndexError, TypeError) as err:
        raise RuntimeError(f"Current config missing expected structure for modification: {err}")

    # 4. PATCH full modified configuration
    patch_full_config(base_url, access_token, full_config)

    # 5. Verify by re-reading config from server
    verified_config = fetch_full_config(base_url)
    mismatches: List[str] = []
    verified_summary: Dict[str, Any] = {}

    if theme_info:
        theme_values = extract_verified_values(verified_config)
        expected_theme_values = {
            "actions.image[0].processing.img_frame_enable": theme_info["img_frame_enable"],
            "actions.image[0].processing.img_frame_file": theme_info["img_frame_file"],
            "actions.collage[0].processing.canvas_img_front_enable": theme_info["canvas_img_front_enable"],
            "actions.collage[0].processing.canvas_img_front_file": theme_info["canvas_img_front_file"],
            "uisettings.enable_livestream_frameoverlay": theme_info["enable_livestream_frameoverlay"],
            "uisettings.livestream_frameoverlay_image": theme_info["livestream_frameoverlay_image"],
        }
        for k, exp in expected_theme_values.items():
            act = theme_values.get(k)
            verified_summary[k] = act
            if act != exp:
                mismatches.append(f"{k}: expected {json.dumps(exp)}, got {json.dumps(act)}")

    if target_filter_value is not None:
        try:
            actual_filter = verified_config["actions"]["image"][0]["processing"]["image_filter"]
            verified_summary["actions.image[0].processing.image_filter"] = actual_filter
            if actual_filter != target_filter_value:
                mismatches.append(
                    f"actions.image[0].processing.image_filter: expected {json.dumps(target_filter_value)}, got {json.dumps(actual_filter)}"
                )
        except (KeyError, IndexError, TypeError) as err:
            mismatches.append(f"actions.image[0].processing.image_filter missing from verified config: {err}")

    if mismatches:
        err_detail = "\n".join(f"  - {m}" for m in mismatches)
        raise RuntimeError(f"Configuration verification failed! Field mismatches detected:\n{err_detail}")

    print("HTTP success: 200 OK (PATCH /api/admin/config/app?reload=false)")
    if theme_name:
        print(f"Verified theme '{theme_name}'")
    if filter_info:
        print(f"Verified filter '{filter_info['name']}' -> backend: {target_filter_value}")
    print("Configuration verification PASSED")
    return verified_summary


def apply_theme_live(
    theme_name: str,
    base_url: str,
    interactive: bool = True,
    current_filter: Optional[str] = None,
) -> None:
    """
    Safely apply theme to live Photobooth-App, preserving the active filter.
    """
    apply_config_live(
        theme_name=theme_name,
        filter_name=current_filter,
        base_url=base_url,
        interactive=interactive,
    )


def apply_filter_live(
    filter_name: str,
    base_url: str,
    interactive: bool = True,
    current_theme: Optional[str] = None,
) -> None:
    """
    Safely apply image filter to live Photobooth-App, preserving the active theme.
    """
    apply_config_live(
        theme_name=current_theme,
        filter_name=filter_name,
        base_url=base_url,
        interactive=interactive,
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build and apply Photobooth-App theme and filter configuration patches."
    )
    parser.add_argument(
        "theme",
        nargs="?",
        default=None,
        choices=list(THEME_CONFIGS.keys()),
        help=f"Theme to apply ({', '.join(THEME_CONFIGS.keys())})",
    )
    parser.add_argument(
        "--filter",
        default=None,
        help=f"Filter to apply ({', '.join(FILTER_CONFIGS.keys())} or Pilgram2 name)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print the Photobooth-App config patch as JSON (offline)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply theme/filter to live Photobooth-App instance",
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_BASE_URL,
        help=f"Base URL of Photobooth-App instance (default: {DEFAULT_BASE_URL})",
    )

    args = parser.parse_args()

    if not args.theme and not args.filter:
        parser.print_help()
        sys.exit(1)

    if args.apply:
        try:
            apply_config_live(
                theme_name=args.theme,
                filter_name=args.filter,
                base_url=args.url,
                interactive=True,
            )
        except Exception as err:
            sys.stderr.write(f"Error applying configuration: {err}\n")
            sys.exit(1)
    else:
        patches = {}
        if args.theme:
            patches["theme"] = build_config_patch(args.theme)
        if args.filter:
            patches["filter"] = build_filter_patch(args.filter)

        if args.json:
            print(json.dumps(patches, indent=2))
        else:
            if args.theme:
                print(f"Selected theme: {args.theme}")
                print("Photobooth-App Theme Patch:")
                print(json.dumps(patches["theme"], indent=2))
            if args.filter:
                resolved = resolve_filter_key(args.filter)
                print(f"Selected filter: {resolved}")
                print("Photobooth-App Filter Patch:")
                print(json.dumps(patches["filter"], indent=2))


if __name__ == "__main__":
    main()
