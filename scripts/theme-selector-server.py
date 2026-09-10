#!/usr/bin/env python3
"""
scripts/theme-selector-server.py - Lightweight local web server for the touchscreen Theme Selector UI.

Features:
- Serves the touch-friendly UI from ui/
- Reuses verified theme definitions and patch builders from scripts/apply-theme.py
- Read-only inspection of active theme from Photobooth-App (GET /api/config)
- Safe preview mode: handles theme selection without issuing live PATCH requests (per Phase 1 requirements)
- Standard library only (zero external dependencies)
"""

import argparse
import http.server
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict

# Dynamically import apply-theme module
SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
UI_DIR = REPO_ROOT / "ui"

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

try:
    apply_theme_module = __import__("apply-theme")
    THEME_CONFIGS = apply_theme_module.THEME_CONFIGS
    build_config_patch = apply_theme_module.build_config_patch
    apply_theme_live = getattr(apply_theme_module, "apply_theme_live", None)
except Exception as err:
    sys.stderr.write(f"Error importing apply-theme.py: {err}\n")
    sys.exit(1)

DEFAULT_PORT = 8080
DEFAULT_BASE_URL = "http://localhost:8000"

# In-memory selection state for preview mode
_state = {
    "current_theme": "modern-gold",
    "base_url": DEFAULT_BASE_URL,
    "apply_live": False,
}


def check_live_theme(base_url: str) -> str:
    """
    Query GET /api/config in read-only mode to determine the active theme.
    Falls back gracefully if the Pi is unreachable.
    """
    endpoint = f"{base_url.rstrip('/')}/api/config"
    req = urllib.request.Request(endpoint, headers={"Accept": "application/json"})

    try:
        with urllib.request.urlopen(req, timeout=2) as resp:
            if resp.status == 200:
                config = json.loads(resp.read().decode("utf-8"))
                img_frame_enable = config.get("actions", {}).get("image", [{}])[0].get("processing", {}).get("img_frame_enable", False)
                img_frame_file = config.get("actions", {}).get("image", [{}])[0].get("processing", {}).get("img_frame_file", None)

                if not img_frame_enable:
                    return "none"
                for theme_id, info in THEME_CONFIGS.items():
                    if info.get("img_frame_enable") and info.get("img_frame_file") == img_frame_file:
                        return theme_id
    except Exception:
        pass

    return _state["current_theme"]


class ThemeSelectorHandler(http.server.SimpleHTTPRequestHandler):
    """
    HTTP Request Handler serving UI assets and JSON API endpoints.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(UI_DIR), **kwargs)

    def log_message(self, format: str, *args: Any) -> None:
        # Standard clean logging
        sys.stderr.write(f"[theme-server] {self.address_string()} - {format % args}\n")

    def _send_json_response(self, data: Any, status: int = 200) -> None:
        payload = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        if self.path == "/api/themes":
            themes_list = [
                {
                    "id": theme_id,
                    "name": info["name"],
                    "description": info["description"],
                    "preview_asset": info["preview_asset"],
                    "production_frame": info["production_frame"],
                    "frame": info["img_frame_file"],
                }
                for theme_id, info in THEME_CONFIGS.items()
            ]
            self._send_json_response({"themes": themes_list})
            return

        if self.path == "/api/current-theme":
            active_theme = check_live_theme(_state["base_url"])
            _state["current_theme"] = active_theme
            self._send_json_response({
                "theme": active_theme,
                "preview_mode": not _state.get("apply_live", False),
                "target_url": _state["base_url"],
            })
            return

        # Serve static UI files from ui/
        super().do_GET()

    def do_POST(self) -> None:
        if self.path == "/api/select-theme":
            content_length = int(self.headers.get("Content-Length", 0))
            raw_body = self.rfile.read(content_length)

            try:
                data = json.loads(raw_body.decode("utf-8"))
            except Exception:
                self._send_json_response({"error": "Invalid JSON body"}, 400)
                return

            theme_id = data.get("theme")
            if theme_id not in THEME_CONFIGS:
                self._send_json_response(
                    {"error": f"Invalid theme '{theme_id}'. Must be one of: {list(THEME_CONFIGS.keys())}"},
                    400,
                )
                return

            # Build config patch using proven logic from apply-theme.py
            patch = build_config_patch(theme_id)
            _state["current_theme"] = theme_id

            # Live Apply Mode: Safely apply theme and return redirect URL only after backend confirms success
            if _state.get("apply_live", False):
                if apply_theme_live is None:
                    self._send_json_response({
                        "status": "error",
                        "error": "apply_theme_live function unavailable",
                        "preview_mode": False,
                    }, 500)
                    return

                try:
                    apply_theme_live(theme_id, _state["base_url"])
                    self._send_json_response({
                        "status": "success",
                        "theme": theme_id,
                        "patch": patch,
                        "preview_mode": False,
                        "redirect_url": f"{_state['base_url'].rstrip('/')}/",
                        "message": f"Theme '{theme_id}' applied successfully.",
                    })
                except (Exception, SystemExit) as err:
                    self._send_json_response({
                        "status": "error",
                        "theme": theme_id,
                        "preview_mode": False,
                        "error": f"Failed to apply theme live: {err}",
                    }, 500)
                return

            # Safe preview response (no live changes applied, zero redirect)
            self._send_json_response({
                "status": "success",
                "theme": theme_id,
                "patch": patch,
                "preview_mode": True,
                "message": f"Theme '{theme_id}' selected in preview mode. No live changes applied.",
            })
            return

        self._send_json_response({"error": "Not Found"}, 404)


def run_server(port: int = DEFAULT_PORT, base_url: str = DEFAULT_BASE_URL, apply_live: bool = False) -> None:
    _state["base_url"] = base_url
    _state["apply_live"] = apply_live
    server_address = ("", port)
    httpd = http.server.HTTPServer(server_address, ThemeSelectorHandler)

    mode_str = "Live Apply Mode (Live PATCH to booth enabled)" if apply_live else "Preview Mode (Safe, no live PATCH requests)"
    print(f"=====================================================")
    print(f"  Photobooth Theme Selector UI Server Running")
    print(f"  URL: http://localhost:{port}/")
    print(f"  Target Kiosk Base URL: {base_url}")
    print(f"  Mode: {mode_str}")
    print(f"=====================================================")
    print(f"Press Ctrl+C to stop.")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping server...")
        httpd.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run local web server for Photobooth Touchscreen Theme Selector UI."
    )
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"Port to bind web server (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--url",
        default="http://localhost:8000",
        help="Base URL of target Photobooth-App (default: http://localhost:8000)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply themes live to Photobooth-App instance instead of preview mode",
    )

    args = parser.parse_args()
    run_server(port=args.port, base_url=args.url, apply_live=args.apply)


if __name__ == "__main__":
    main()
