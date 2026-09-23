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
import mimetypes
import os
import queue
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

# Dynamically import apply-theme module
SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
UI_DIR = REPO_ROOT / "ui"
ASSETS_DIR = REPO_ROOT / "assets"

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

try:
    apply_theme_module = __import__("apply-theme")
    THEME_CONFIGS = apply_theme_module.THEME_CONFIGS
    FILTER_CONFIGS = getattr(apply_theme_module, "FILTER_CONFIGS", {})
    build_config_patch = apply_theme_module.build_config_patch
    build_filter_patch = getattr(apply_theme_module, "build_filter_patch", None)
    apply_theme_live = getattr(apply_theme_module, "apply_theme_live", None)
    apply_filter_live = getattr(apply_theme_module, "apply_filter_live", None)
    apply_config_live = getattr(apply_theme_module, "apply_config_live", None)
    resolve_filter_key = getattr(apply_theme_module, "resolve_filter_key", lambda x: x)
except Exception as err:
    sys.stderr.write(f"Error importing apply-theme.py: {err}\n")
    sys.exit(1)

# Dynamically import ar_engine module
try:
    import ar_engine
    FaceDetector = ar_engine.FaceDetector
    process_stream_frame = ar_engine.process_stream_frame
    AR_EFFECT_CONFIGS = ar_engine.AR_EFFECT_CONFIGS
    DEFAULT_MODEL_PATH = ar_engine.DEFAULT_MODEL_PATH
    DEFAULT_FACEMESH_PATH = getattr(ar_engine, "DEFAULT_FACEMESH_PATH", REPO_ROOT / "models" / "face_mesh.onnx")
    ExpressionEngine = getattr(ar_engine, "ExpressionEngine", None)
    save_ar_state = getattr(ar_engine, "save_ar_state", None)
    get_ar_state = getattr(ar_engine, "get_ar_state", None)
except Exception as err:
    sys.stderr.write(f"Warning: could not import ar_engine: {err}\n")
    FaceDetector = None
    process_stream_frame = None
    AR_EFFECT_CONFIGS = {}
    DEFAULT_MODEL_PATH = REPO_ROOT / "models" / "face_detection_yunet_2023mar.onnx"
    DEFAULT_FACEMESH_PATH = REPO_ROOT / "models" / "face_mesh.onnx"
    ExpressionEngine = None
    save_ar_state = None
    get_ar_state = None

DEFAULT_PORT = 8080
DEFAULT_BASE_URL = os.environ.get(
    "PHOTOBOOTH_URL",
    getattr(apply_theme_module, "DEFAULT_BASE_URL", "http://localhost:8000"),
)
BOOTH_HOME_URL = "http://localhost:8000/#/"

# In-memory selection state for preview mode
_state = {
    "current_theme": "modern-gold",
    "current_filter": "original",
    "base_url": DEFAULT_BASE_URL,
    "apply_live": False,
}


class ARStreamManager:
    """
    Manages background MJPEG acquisition, downscaled YuNet inference,
    optional generic facial expression evaluation, and Server-Sent Events (SSE)
    distribution to connected browser clients.
    Thread-safe and strictly on-demand: only runs when active subscribers exist.
    """

    def __init__(self, base_url: str, model_path: Path):
        self.base_url = base_url
        self.model_path = model_path
        self._lock = threading.Lock()
        self._subscribers: List[queue.Queue] = []
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._detector: Optional[Any] = None
        self._expression_engine: Optional[Any] = None
        if ExpressionEngine is not None and DEFAULT_FACEMESH_PATH.is_file():
            try:
                engine = ExpressionEngine(model_path=DEFAULT_FACEMESH_PATH)
                if engine.is_available():
                    self._expression_engine = engine
                else:
                    sys.stderr.write(f"[ARStreamManager] ExpressionEngine unavailable: {engine.detector.init_error}\n")
            except Exception as err:
                sys.stderr.write(f"[ARStreamManager] ExpressionEngine init notice: {err}\n")
        init_state = get_ar_state() if get_ar_state is not None else {}
        self.enabled = bool(init_state.get("enabled", True))
        self.active_effect = str(init_state.get("active_effect", "glasses"))

    @property
    def stream_url(self) -> str:
        return f"{self.base_url.rstrip('/')}/api/aquisition/stream.mjpg"

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=3)
        with self._lock:
            self._subscribers.append(q)
            if not self._running and self.enabled:
                self._start_worker()
        return q

    def unsubscribe(self, q: queue.Queue) -> None:
        with self._lock:
            if q in self._subscribers:
                self._subscribers.remove(q)
            if len(self._subscribers) == 0 and self._running:
                self._stop_worker()

    def set_enabled(self, enabled: bool) -> None:
        with self._lock:
            self.enabled = enabled
            if not self.enabled and self._running:
                self._stop_worker()
            elif self.enabled and not self._running and len(self._subscribers) > 0:
                self._start_worker()

    def _start_worker(self) -> None:
        self._running = True
        self._thread = threading.Thread(target=self._worker_loop, daemon=True, name="ARStreamWorker")
        self._thread.start()

    def _stop_worker(self) -> None:
        self._running = False

    def _worker_loop(self) -> None:
        if FaceDetector is None or process_stream_frame is None:
            sys.stderr.write("[ARStreamWorker] ar_engine not available, worker aborting\n")
            self._running = False
            return

        if self._detector is None:
            try:
                self._detector = FaceDetector(model_path=self.model_path, score_threshold=0.35)
            except Exception as err:
                sys.stderr.write(f"[ARStreamWorker] FaceDetector init error: {err}\n")
                self._running = False
                return

        while self._running:
            try:
                req = urllib.request.Request(self.stream_url)
                with urllib.request.urlopen(req, timeout=5) as resp:
                    buf = b""
                    while self._running:
                        chunk = resp.read(8192)
                        if not chunk:
                            break
                        buf += chunk

                        # Check for JPEG end-of-image marker
                        if b"\xff\xd9" in buf:
                            # Low-latency strategy: process latest complete frame, drop stale buffer
                            end_idx = buf.rfind(b"\xff\xd9")
                            start_idx = buf.rfind(b"\xff\xd8", 0, end_idx)
                            if start_idx != -1 and end_idx > start_idx:
                                jpg_bytes = buf[start_idx : end_idx + 2]
                                buf = buf[end_idx + 2 :]

                                t0 = time.perf_counter()
                                faces, inf_ms, orig_w, orig_h = process_stream_frame(
                                    self._detector,
                                    jpg_bytes,
                                    downscale_factor=0.5,
                                    expression_engine=self._expression_engine,
                                )
                                total_proc_ms = (time.perf_counter() - t0) * 1000.0

                                packet = {
                                    "timestamp": time.time(),
                                    "stream_w": orig_w,
                                    "stream_h": orig_h,
                                    "faces": faces,
                                    "inference_ms": round(inf_ms, 2),
                                    "total_process_ms": round(total_proc_ms, 2),
                                    "active_effect": self.active_effect,
                                    "enabled": self.enabled,
                                }
                                self._broadcast(packet)
                            else:
                                if len(buf) > 400000:
                                    buf = buf[-100000:]
            except Exception as err:
                if self._running:
                    sys.stderr.write(f"[ARStreamWorker] Stream connection notice: {err}. Reconnecting in 0.5s...\n")
                    time.sleep(0.5)

    def _broadcast(self, data: Dict[str, Any]) -> None:
        payload = f"data: {json.dumps(data)}\n\n".encode("utf-8")
        with self._lock:
            for q in list(self._subscribers):
                try:
                    q.put_nowait(payload)
                except queue.Full:
                    # Discard older packet to preserve zero-latency real-time preview
                    try:
                        q.get_nowait()
                        q.put_nowait(payload)
                    except Exception:
                        pass


# Global singleton AR stream manager
_ar_manager: Optional[ARStreamManager] = None


def get_ar_manager(base_url: str) -> ARStreamManager:
    global _ar_manager
    if _ar_manager is None:
        _ar_manager = ARStreamManager(base_url=base_url, model_path=DEFAULT_MODEL_PATH)
    else:
        _ar_manager.base_url = base_url
    return _ar_manager


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


def check_live_filter(base_url: str) -> str:
    """
    Query GET /api/config in read-only mode to determine the active filter.
    Falls back gracefully if the Pi is unreachable.
    """
    endpoint = f"{base_url.rstrip('/')}/api/config"
    req = urllib.request.Request(endpoint, headers={"Accept": "application/json"})

    try:
        with urllib.request.urlopen(req, timeout=2) as resp:
            if resp.status == 200:
                config = json.loads(resp.read().decode("utf-8"))
                raw_filter = config.get("actions", {}).get("image", [{}])[0].get("processing", {}).get("image_filter", "original")
                for filter_id, info in FILTER_CONFIGS.items():
                    if info.get("backend_value") == raw_filter:
                        return filter_id
                return "original"
    except Exception:
        pass

    return _state.get("current_filter", "original")


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
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_HEAD(self) -> None:
        if self.path.startswith("/assets/"):
            rel_path = self.path.lstrip("/")[len("assets/") :]
            target_file = (ASSETS_DIR / rel_path).resolve()
            if target_file.is_file() and str(target_file).startswith(str(ASSETS_DIR)):
                content_type, _ = mimetypes.guess_type(str(target_file))
                self.send_response(200)
                self.send_header("Content-Type", content_type or "application/octet-stream")
                self.send_header("Content-Length", str(target_file.stat().st_size))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Cache-Control", "public, max-age=3600")
                self.end_headers()
                return
        if self.path in ("/kiosk-ar-overlay.js", "/kiosk-theme-button.js"):
            js_name = self.path.lstrip("/")
            target_js = UI_DIR / js_name
            if target_js.is_file():
                self.send_response(200)
                self.send_header("Content-Type", "application/javascript")
                self.send_header("Content-Length", str(target_js.stat().st_size))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Cache-Control", "no-cache, must-revalidate")
                self.end_headers()
                return
        super().do_HEAD()

    def do_GET(self) -> None:
        if self.path == "/api/ar/config":
            ar_mgr = get_ar_manager(_state["base_url"])
            self._send_json_response({
                "enabled": ar_mgr.enabled,
                "active_effect": ar_mgr.active_effect,
                "effects": AR_EFFECT_CONFIGS,
            })
            return

        if self.path == "/api/ar/stream":
            ar_mgr = get_ar_manager(_state["base_url"])
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache, no-transform")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            q = ar_mgr.subscribe()
            try:
                while True:
                    try:
                        chunk = q.get(timeout=2.0)
                        self.wfile.write(chunk)
                        self.wfile.flush()
                    except queue.Empty:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                ar_mgr.unsubscribe(q)
            return

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

        if self.path == "/api/filters":
            filters_list = [
                {
                    "id": filter_id,
                    "name": info["name"],
                    "description": info["description"],
                    "backend_value": info["backend_value"],
                    "css_filter": info.get("css_filter", "none"),
                }
                for filter_id, info in FILTER_CONFIGS.items()
            ]
            self._send_json_response({"filters": filters_list})
            return

        if self.path == "/api/current-theme":
            active_theme = check_live_theme(_state["base_url"])
            active_filter = check_live_filter(_state["base_url"])
            _state["current_theme"] = active_theme
            _state["current_filter"] = active_filter
            ar_mgr = get_ar_manager(_state["base_url"])
            self._send_json_response({
                "theme": active_theme,
                "filter": active_filter,
                "ar_enabled": ar_mgr.enabled,
                "active_ar_effect": ar_mgr.active_effect,
                "preview_mode": not _state.get("apply_live", False),
                "target_url": BOOTH_HOME_URL,
            })
            return

        if self.path == "/api/current-filter":
            active_filter = check_live_filter(_state["base_url"])
            _state["current_filter"] = active_filter
            filter_info = FILTER_CONFIGS.get(active_filter, {"name": active_filter, "backend_value": "original"})
            self._send_json_response({
                "filter": active_filter,
                "name": filter_info["name"],
                "backend_value": filter_info["backend_value"],
                "preview_mode": not _state.get("apply_live", False),
            })
            return

        # Serve static assets from assets/ directory with CORS
        if self.path.startswith("/assets/"):
            rel_path = self.path.lstrip("/")[len("assets/") :]
            target_file = (ASSETS_DIR / rel_path).resolve()
            if target_file.is_file() and str(target_file).startswith(str(ASSETS_DIR)):
                content_type, _ = mimetypes.guess_type(str(target_file))
                content = target_file.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", content_type or "application/octet-stream")
                self.send_header("Content-Length", str(len(content)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Cache-Control", "public, max-age=3600")
                self.end_headers()
                self.wfile.write(content)
                return
            else:
                self._send_json_response({"error": "Asset not found"}, 404)
                return

        # Direct serving of extension JS files with CORS
        if self.path in ("/kiosk-ar-overlay.js", "/kiosk-theme-button.js"):
            js_name = self.path.lstrip("/")
            target_js = UI_DIR / js_name
            if target_js.is_file():
                content = target_js.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "application/javascript")
                self.send_header("Content-Length", str(len(content)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Cache-Control", "no-cache, must-revalidate")
                self.end_headers()
                self.wfile.write(content)
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
            if data.get("filter"):
                _state["current_filter"] = resolve_filter_key(data.get("filter"))

            # Live Apply Mode: Safely apply theme while preserving active filter
            if _state.get("apply_live", False):
                if apply_config_live is None and apply_theme_live is None:
                    self._send_json_response({
                        "status": "error",
                        "error": "apply_theme_live function unavailable",
                        "preview_mode": False,
                    }, 500)
                    return

                # Non-interactive credential validation: never block on getpass during HTTP requests
                if not os.environ.get("PHOTOBOOTH_ADMIN_PASSWORD", "").strip():
                    self._send_json_response({
                        "status": "error",
                        "theme": theme_id,
                        "preview_mode": False,
                        "error": "Server error: PHOTOBOOTH_ADMIN_PASSWORD environment variable is not set. Cannot authenticate in live mode without credentials.",
                    }, 401)
                    return

                try:
                    if apply_config_live:
                        apply_config_live(
                            theme_name=theme_id,
                            filter_name=_state.get("current_filter"),
                            base_url=_state["base_url"],
                            interactive=False,
                        )
                    else:
                        apply_theme_live(theme_id, _state["base_url"], interactive=False)
                    self._send_json_response({
                        "status": "success",
                        "theme": theme_id,
                        "filter": _state.get("current_filter", "original"),
                        "patch": patch,
                        "preview_mode": False,
                        "redirect_url": BOOTH_HOME_URL,
                        "message": f"Theme '{theme_id}' applied successfully.",
                    })
                except Exception as err:
                    err_msg = str(err)
                    status_code = 401 if "401" in err_msg or "Authentication" in err_msg else (422 if "422" in err_msg else 500)
                    self._send_json_response({
                        "status": "error",
                        "theme": theme_id,
                        "preview_mode": False,
                        "error": f"Failed to apply theme live: {err_msg}",
                    }, status_code)
                return

            # Safe preview response (no live changes applied, zero redirect)
            self._send_json_response({
                "status": "success",
                "theme": theme_id,
                "filter": _state.get("current_filter", "original"),
                "patch": patch,
                "preview_mode": True,
                "message": f"Theme '{theme_id}' selected in preview mode. No live changes applied.",
            })
            return

        if self.path == "/api/select-filter":
            content_length = int(self.headers.get("Content-Length", 0))
            raw_body = self.rfile.read(content_length)

            try:
                data = json.loads(raw_body.decode("utf-8"))
            except Exception:
                self._send_json_response({"error": "Invalid JSON body"}, 400)
                return

            raw_filter = data.get("filter")
            filter_id = resolve_filter_key(raw_filter) if raw_filter else None
            if not filter_id or filter_id not in FILTER_CONFIGS:
                self._send_json_response(
                    {"error": f"Invalid filter '{raw_filter}'. Must be one of: {list(FILTER_CONFIGS.keys())}"},
                    400,
                )
                return

            filter_info = FILTER_CONFIGS[filter_id]
            patch = build_filter_patch(filter_id) if build_filter_patch else {
                "actions": {"image": [{"processing": {"image_filter": filter_info["backend_value"]}}]}
            }
            _state["current_filter"] = filter_id
            if data.get("theme") and data.get("theme") in THEME_CONFIGS:
                _state["current_theme"] = data.get("theme")

            # Live Apply Mode: Safely apply filter while preserving active theme
            if _state.get("apply_live", False):
                if apply_config_live is None and apply_filter_live is None:
                    self._send_json_response({
                        "status": "error",
                        "error": "apply_filter_live function unavailable",
                        "preview_mode": False,
                    }, 500)
                    return

                if not os.environ.get("PHOTOBOOTH_ADMIN_PASSWORD", "").strip():
                    self._send_json_response({
                        "status": "error",
                        "filter": filter_id,
                        "preview_mode": False,
                        "error": "Server error: PHOTOBOOTH_ADMIN_PASSWORD environment variable is not set. Cannot authenticate in live mode without credentials.",
                    }, 401)
                    return

                try:
                    if apply_config_live:
                        apply_config_live(
                            theme_name=_state.get("current_theme"),
                            filter_name=filter_id,
                            base_url=_state["base_url"],
                            interactive=False,
                        )
                    else:
                        apply_filter_live(filter_id, _state["base_url"], interactive=False)
                    self._send_json_response({
                        "status": "success",
                        "filter": filter_id,
                        "theme": _state.get("current_theme"),
                        "name": filter_info["name"],
                        "backend_value": filter_info["backend_value"],
                        "patch": patch,
                        "preview_mode": False,
                        "redirect_url": BOOTH_HOME_URL,
                        "message": f"Filter '{filter_info['name']}' applied successfully.",
                    })
                except Exception as err:
                    err_msg = str(err)
                    status_code = 401 if "401" in err_msg or "Authentication" in err_msg else (422 if "422" in err_msg else 500)
                    self._send_json_response({
                        "status": "error",
                        "filter": filter_id,
                        "preview_mode": False,
                        "error": f"Failed to apply filter live: {err_msg}",
                    }, status_code)
                return

            # Safe preview response (no live changes applied)
            self._send_json_response({
                "status": "success",
                "filter": filter_id,
                "theme": _state.get("current_theme"),
                "name": filter_info["name"],
                "backend_value": filter_info["backend_value"],
                "patch": patch,
                "preview_mode": True,
                "message": f"Filter '{filter_info['name']}' selected in preview mode. No live changes applied.",
            })
            return

        if self.path == "/api/ar/toggle":
            content_length = int(self.headers.get("Content-Length", 0))
            raw_body = self.rfile.read(content_length) if content_length > 0 else b"{}"
            try:
                data = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except Exception:
                data = {}

            ar_mgr = get_ar_manager(_state["base_url"])
            if "enabled" in data:
                new_state = bool(data["enabled"])
            else:
                new_state = not ar_mgr.enabled

            ar_mgr.set_enabled(new_state)
            if save_ar_state is not None:
                save_ar_state(ar_mgr.enabled, ar_mgr.active_effect)
            self._send_json_response({
                "status": "success",
                "enabled": ar_mgr.enabled,
                "active_effect": ar_mgr.active_effect,
            })
            return

        if self.path == "/api/ar/select-effect":
            content_length = int(self.headers.get("Content-Length", 0))
            raw_body = self.rfile.read(content_length) if content_length > 0 else b"{}"
            try:
                data = json.loads(raw_body.decode("utf-8"))
            except Exception:
                self._send_json_response({"error": "Invalid JSON body"}, 400)
                return

            effect_name = data.get("effect")
            if effect_name == "none":
                ar_mgr = get_ar_manager(_state["base_url"])
                ar_mgr.set_enabled(False)
                if save_ar_state is not None:
                    save_ar_state(False, ar_mgr.active_effect)
                self._send_json_response({
                    "status": "success",
                    "enabled": False,
                    "active_effect": "none",
                })
                return

            if effect_name not in AR_EFFECT_CONFIGS:
                self._send_json_response(
                    {"error": f"Unknown effect '{effect_name}'. Available: {list(AR_EFFECT_CONFIGS.keys())}"},
                    400,
                )
                return

            ar_mgr = get_ar_manager(_state["base_url"])
            ar_mgr.active_effect = effect_name
            if not ar_mgr.enabled:
                ar_mgr.set_enabled(True)
            if save_ar_state is not None:
                save_ar_state(ar_mgr.enabled, ar_mgr.active_effect)
            self._send_json_response({
                "status": "success",
                "enabled": ar_mgr.enabled,
                "active_effect": effect_name,
                "config": AR_EFFECT_CONFIGS[effect_name],
            })
            return

        self._send_json_response({"error": "Not Found"}, 404)


def run_server(port: int = DEFAULT_PORT, base_url: str = DEFAULT_BASE_URL, apply_live: bool = False) -> None:
    _state["base_url"] = base_url
    _state["apply_live"] = apply_live
    server_address = ("", port)
    # ThreadingHTTPServer enables concurrent, non-blocking SSE streaming and API requests
    httpd = http.server.ThreadingHTTPServer(server_address, ThemeSelectorHandler)

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
        default=DEFAULT_BASE_URL,
        help=f"Base URL of target Photobooth-App (default: {DEFAULT_BASE_URL})",
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
