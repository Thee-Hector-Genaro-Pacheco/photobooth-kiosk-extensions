#!/usr/bin/env python3
"""
scripts/ar_engine.py - Generic AR Face Landmark Transform & Rendering Engine.

Architectural Guarantees:
- Fully local: Uses OpenCV FaceDetectorYN with local YuNet ONNX model (zero cloud/CDN).
- Multi-face support: Operates over lists of detected faces natively.
- Data-driven: AR effects defined via AR_EFFECT_CONFIGS mapping (no hardcoded 'if effect == ...').
- Generic transform: Decouples landmark geometry (inter-eye distance, roll angle, anchors)
  from effect rendering.
- Standard libraries: OpenCV and Pillow (both pre-installed on Pi).
"""

from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import sys
import time
from typing import Any, Dict, List, Optional, Tuple
try:
    import cv2
except ImportError:
    cv2 = None

try:
    import numpy as np
except ImportError:
    np = None

from PIL import Image

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MODEL_PATH = REPO_ROOT / "models" / "face_detection_yunet_2023mar.onnx"
AR_STATE_FILE = REPO_ROOT / "ar_state.json"


@dataclass
class FaceLandmarks:
    """Raw detected face bounding box and key facial landmarks."""
    bbox: Tuple[float, float, float, float]  # (x, y, w, h)
    right_eye: Tuple[float, float]          # Subject's right eye (left side in image)
    left_eye: Tuple[float, float]           # Subject's left eye (right side in image)
    nose: Tuple[float, float]               # Nose tip
    right_mouth: Tuple[float, float]        # Subject's right mouth corner
    left_mouth: Tuple[float, float]         # Subject's left mouth corner
    confidence: float

    def to_normalized(self, img_w: int, img_h: int) -> Dict[str, Any]:
        """Convert pixel coordinates to normalized [0.0, 1.0] coordinates."""
        return {
            "bbox": (
                self.bbox[0] / img_w,
                self.bbox[1] / img_h,
                self.bbox[2] / img_w,
                self.bbox[3] / img_h,
            ),
            "right_eye": (self.right_eye[0] / img_w, self.right_eye[1] / img_h),
            "left_eye": (self.left_eye[0] / img_w, self.left_eye[1] / img_h),
            "nose": (self.nose[0] / img_w, self.nose[1] / img_h),
            "right_mouth": (self.right_mouth[0] / img_w, self.right_mouth[1] / img_h),
            "left_mouth": (self.left_mouth[0] / img_w, self.left_mouth[1] / img_h),
            "confidence": self.confidence,
        }


@dataclass
class FaceTransform:
    """
    Generic face geometry and anchor transform calculated from landmarks.
    Completely decoupled from any specific AR asset.
    """
    center_eyes: Tuple[float, float]       # Midpoint between eye centers
    inter_eye_distance: float              # Scale baseline in pixels
    roll_angle_rad: float                  # Head tilt angle in radians
    roll_angle_deg: float                  # Head tilt angle in degrees (-180 to 180)
    face_scale: float                      # Normalized scale relative to image width
    nose_anchor: Tuple[float, float]       # Nose bridge / tip anchor
    forehead_anchor: Tuple[float, float]   # Forehead top anchor (projected along head-up vector)
    mouth_anchor: Tuple[float, float]      # Mouth center anchor
    unit_vec_eyes: Tuple[float, float]     # Unit vector pointing right along eye line
    unit_vec_up: Tuple[float, float]       # Unit vector pointing up towards top of head

    def to_normalized_dict(self, img_w: int, img_h: int) -> Dict[str, Any]:
        """Convert all coordinates and anchors to normalized [0.0, 1.0] viewport space."""
        w = max(float(img_w), 1.0)
        h = max(float(img_h), 1.0)
        return {
            "center_eyes": [round(self.center_eyes[0] / w, 5), round(self.center_eyes[1] / h, 5)],
            "inter_eye_distance": round(self.inter_eye_distance / w, 5),
            "roll_angle_rad": round(self.roll_angle_rad, 4),
            "roll_angle_deg": round(self.roll_angle_deg, 2),
            "face_scale": round(self.face_scale, 5),
            "anchors": {
                "eyes_center": [round(self.center_eyes[0] / w, 5), round(self.center_eyes[1] / h, 5)],
                "nose_anchor": [round(self.nose_anchor[0] / w, 5), round(self.nose_anchor[1] / h, 5)],
                "forehead_anchor": [round(self.forehead_anchor[0] / w, 5), round(self.forehead_anchor[1] / h, 5)],
                "mouth_anchor": [round(self.mouth_anchor[0] / w, 5), round(self.mouth_anchor[1] / h, 5)],
            },
            "unit_vec_eyes": [round(self.unit_vec_eyes[0], 4), round(self.unit_vec_eyes[1], 4)],
            "unit_vec_up": [round(self.unit_vec_up[0], 4), round(self.unit_vec_up[1], 4)],
        }


def compute_face_transform(face: FaceLandmarks, img_w: int, img_h: int) -> FaceTransform:
    """
    Compute reusable geometric transformation parameters for any detected face.
    """
    rx, ry = face.right_eye
    lx, ly = face.left_eye

    # Inter-eye distance
    dx = lx - rx
    dy = ly - ry
    inter_eye_dist = math.hypot(dx, dy)
    if inter_eye_dist < 1e-3:
        inter_eye_dist = 1.0

    # Roll angle (rotation around Z-axis)
    roll_rad = math.atan2(dy, dx)
    roll_deg = math.degrees(roll_rad)

    # Eye center
    center_x = (rx + lx) / 2.0
    center_y = (ry + ly) / 2.0

    # Orthogonal unit vectors for head coordinate frame
    u_eyes_x = dx / inter_eye_dist
    u_eyes_y = dy / inter_eye_dist

    # Perpendicular unit vector pointing UP towards top of skull
    u_up_x = u_eyes_y
    u_up_y = -u_eyes_x

    # Projected anchors
    # Forehead top: projected up along face normal by 0.75 * inter_eye_distance
    forehead_x = center_x + u_up_x * (inter_eye_dist * 0.75)
    forehead_y = center_y + u_up_y * (inter_eye_dist * 0.75)

    # Mouth center
    mx = (face.right_mouth[0] + face.left_mouth[0]) / 2.0
    my = (face.right_mouth[1] + face.left_mouth[1]) / 2.0

    return FaceTransform(
        center_eyes=(center_x, center_y),
        inter_eye_distance=inter_eye_dist,
        roll_angle_rad=roll_rad,
        roll_angle_deg=roll_deg,
        face_scale=inter_eye_dist / max(img_w, 1),
        nose_anchor=face.nose,
        forehead_anchor=(forehead_x, forehead_y),
        mouth_anchor=(mx, my),
        unit_vec_eyes=(u_eyes_x, u_eyes_y),
        unit_vec_up=(u_up_x, u_up_y),
    )


def process_stream_frame(
    detector: "FaceDetector",
    jpeg_bytes: bytes,
    downscale_factor: float = 0.5,
) -> Tuple[List[Dict[str, Any]], float, int, int]:
    """
    Decode, downscale, and detect faces in a live MJPEG stream frame.
    Returns:
      (list_of_normalized_face_transforms, inference_time_ms, orig_w, orig_h)
    """
    arr = np.frombuffer(jpeg_bytes, dtype=np.uint8)
    img_bgr = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if img_bgr is None:
        return [], 0.0, 0, 0

    orig_h, orig_w = img_bgr.shape[:2]

    if 0.0 < downscale_factor < 1.0:
        det_w = int(round(orig_w * downscale_factor))
        det_h = int(round(orig_h * downscale_factor))
        img_det = cv2.resize(img_bgr, (det_w, det_h), interpolation=cv2.INTER_LINEAR)
    else:
        det_w, det_h = orig_w, orig_h
        img_det = img_bgr

    faces, inf_ms = detector.detect(img_det)

    output_faces: List[Dict[str, Any]] = []
    for face in faces:
        transform = compute_face_transform(face, det_w, det_h)
        face_dict = transform.to_normalized_dict(det_w, det_h)
        face_dict["confidence"] = round(face.confidence, 4)
        face_dict["bbox_norm"] = [
            round(face.bbox[0] / det_w, 5),
            round(face.bbox[1] / det_h, 5),
            round(face.bbox[2] / det_w, 5),
            round(face.bbox[3] / det_h, 5),
        ]
        output_faces.append(face_dict)

    return output_faces, inf_ms, orig_w, orig_h


# Generic, data-driven AR effect configurations mapping
AR_EFFECT_CONFIGS: Dict[str, Dict[str, Any]] = {
    "glasses": {
        "name": "Classic Sunglasses",
        "description": "Dark sunglasses anchored to eye centers and nose bridge",
        "elements": [
            {
                "asset": "assets/ar/glasses.png",
                "anchor": "eyes_center",            # 'eyes_center', 'nose_anchor', 'forehead_anchor', 'mouth_anchor'
                "asset_anchor_x": 0.50,             # Horizontal midpoint of the bridge
                "asset_anchor_y": 0.38,             # Optical axis of lenses and bridge
                "scale_reference": "inter_eye_distance",
                "scale_factor": 2.05,               # Calibrated so lens optical spacing (49.26% of asset) matches inter-eye distance
                "offset_along_eyes": 0.0,           # Fine-tune along eye line (fractions of element width)
                "offset_along_up": 0.0,             # Fine-tune along skull-up vector (fractions of element height)
            }
        ],
    },
    "crown": {
        "name": "Golden Crown",
        "description": "Regal gold crown anchored to the forehead",
        "elements": [
            {
                "asset": "assets/ar/crown.png",
                "anchor": "forehead_anchor",        # Anchored at top of forehead / hairline
                "asset_anchor_x": 0.50,             # Horizontal center of crown
                "asset_anchor_y": 1.00,             # Base of the crown headband rests on forehead
                "scale_reference": "inter_eye_distance",
                "scale_factor": 2.40,               # Crown spans across the temples
                "offset_along_eyes": 0.0,
                "offset_along_up": 0.0,
            }
        ],
    },
    "mustache": {
        "name": "Dapper Mustache",
        "description": "Classic handlebar mustache anchored beneath the nose",
        "elements": [
            {
                "asset": "assets/ar/mustache.png",
                "anchor": "nose_anchor",            # Anchored at the nose tip
                "asset_anchor_x": 0.50,             # Horizontal midpoint of the mustache
                "asset_anchor_y": 0.15,             # Top center notch aligns right below the nose tip
                "scale_reference": "inter_eye_distance",
                "scale_factor": 1.35,               # Natural mustache width extending past mouth corners
                "offset_along_eyes": 0.0,
                "offset_along_up": 0.0,
            }
        ],
    },
}


class FaceDetector:
    """Local OpenCV YuNet Face & 5-point Landmark Detector."""

    def __init__(self, model_path: Optional[Path] = None, score_threshold: float = 0.5):
        self.model_path = Path(model_path or DEFAULT_MODEL_PATH)
        if not self.model_path.is_file():
            raise FileNotFoundError(f"Model file not found at {self.model_path}")

        self.score_threshold = score_threshold
        self._detector: Optional[Any] = None
        self._last_input_size: Optional[Tuple[int, int]] = None

    def _get_detector(self, width: int, height: int) -> Any:
        if self._detector is None or self._last_input_size != (width, height):
            if cv2 is None:
                raise RuntimeError("OpenCV (cv2) is not installed in this Python environment.")
            self._detector = cv2.FaceDetectorYN.create(
                str(self.model_path),
                "",
                (width, height),
                score_threshold=self.score_threshold,
                nms_threshold=0.3,
                top_k=10,
            )
            self._last_input_size = (width, height)
        return self._detector

    def detect(self, img_bgr: Any) -> Tuple[List[FaceLandmarks], float]:
        """
        Detect all faces and 5 key landmarks in the input image.
        Returns (list_of_faces, inference_time_ms).
        """
        h, w, _ = img_bgr.shape
        detector = self._get_detector(w, h)

        t0 = time.perf_counter()
        _, raw_faces = detector.detect(img_bgr)
        dt_ms = (time.perf_counter() - t0) * 1000.0

        faces: List[FaceLandmarks] = []
        if raw_faces is not None and len(raw_faces) > 0:
            for f in raw_faces:
                bbox = (float(f[0]), float(f[1]), float(f[2]), float(f[3]))
                r_eye = (float(f[4]), float(f[5]))
                l_eye = (float(f[6]), float(f[7]))
                nose = (float(f[8]), float(f[9]))
                r_mouth = (float(f[10]), float(f[11]))
                l_mouth = (float(f[12]), float(f[13]))
                conf = float(f[14])

                faces.append(
                    FaceLandmarks(
                        bbox=bbox,
                        right_eye=r_eye,
                        left_eye=l_eye,
                        nose=nose,
                        right_mouth=r_mouth,
                        left_mouth=l_mouth,
                        confidence=conf,
                    )
                )

        return faces, dt_ms


class ARRenderer:
    """Generic, data-driven AR Overlay Renderer."""

    def __init__(self, asset_base_dir: Optional[Path] = None):
        self.asset_base_dir = Path(asset_base_dir or REPO_ROOT)
        self._asset_cache: Dict[str, Image.Image] = {}

    def _load_asset(self, rel_path: str) -> Image.Image:
        if rel_path not in self._asset_cache:
            full_path = self.asset_base_dir / rel_path
            if not full_path.is_file():
                raise FileNotFoundError(f"AR asset not found: {full_path}")
            self._asset_cache[rel_path] = Image.open(full_path).convert("RGBA")
        return self._asset_cache[rel_path]

    def render_effect(
        self,
        base_image: Image.Image,
        effect_name: str,
        faces: List[FaceLandmarks],
    ) -> Image.Image:
        """
        Apply data-driven AR effect to all detected faces in the image.
        Zero hardcoded effect branches.
        """
        if effect_name not in AR_EFFECT_CONFIGS:
            raise ValueError(
                f"Unknown AR effect '{effect_name}'. Available: {list(AR_EFFECT_CONFIGS.keys())}"
            )

        effect_config = AR_EFFECT_CONFIGS[effect_name]
        canvas = base_image.convert("RGBA")
        img_w, img_h = canvas.size

        # Multi-face iteration
        for face in faces:
            transform = compute_face_transform(face, img_w, img_h)

            for element in effect_config["elements"]:
                asset = self._load_asset(element["asset"])

                # Resolve anchor position
                anchor_name = element.get("anchor", "eyes_center")
                if anchor_name == "eyes_center":
                    anchor_pt = transform.center_eyes
                elif anchor_name == "nose_anchor":
                    anchor_pt = transform.nose_anchor
                elif anchor_name == "forehead_anchor":
                    anchor_pt = transform.forehead_anchor
                elif anchor_name == "mouth_anchor":
                    anchor_pt = transform.mouth_anchor
                else:
                    anchor_pt = transform.center_eyes

                # Compute target width based on scale reference
                scale_ref = element.get("scale_reference", "inter_eye_distance")
                if scale_ref == "inter_eye_distance":
                    target_w = int(round(transform.inter_eye_distance * element.get("scale_factor", 1.0)))
                else:
                    target_w = int(round(transform.inter_eye_distance * 2.0))

                target_w = max(10, target_w)
                aspect = asset.height / max(1, asset.width)
                target_h = max(5, int(round(target_w * aspect)))

                # Normalized asset anatomical anchor (defaults to geometric center [0.5, 0.5])
                asset_anchor_x = float(element.get("asset_anchor_x", 0.5))
                asset_anchor_y = float(element.get("asset_anchor_y", 0.5))

                # Fine-tune offsets along head coordinate frame
                off_eyes = element.get("offset_along_eyes", 0.0) * target_w
                off_up = element.get("offset_along_up", 0.0) * target_h

                target_face_x = anchor_pt[0] + (transform.unit_vec_eyes[0] * off_eyes) + (transform.unit_vec_up[0] * off_up)
                target_face_y = anchor_pt[1] + (transform.unit_vec_eyes[1] * off_eyes) + (transform.unit_vec_up[1] * off_up)

                # Compute asset geometric center C in canvas space such that rotating around C
                # pins the anatomical anchor (asset_anchor_x, asset_anchor_y) exactly at target_face
                center_x = target_face_x + (transform.unit_vec_eyes[0] * (0.5 - asset_anchor_x) * target_w) - (transform.unit_vec_up[0] * (0.5 - asset_anchor_y) * target_h)
                center_y = target_face_y + (transform.unit_vec_eyes[1] * (0.5 - asset_anchor_x) * target_w) - (transform.unit_vec_up[1] * (0.5 - asset_anchor_y) * target_h)

                # Scale asset
                resized = asset.resize((target_w, target_h), Image.Resampling.BILINEAR)

                # Rotate asset around its geometric center by roll angle (Pillow CCW requires -angle)
                rotated = resized.rotate(-transform.roll_angle_deg, resample=Image.Resampling.BILINEAR, expand=True)

                # Calculate top-left paste position
                paste_x = int(round(center_x - rotated.width / 2.0))
                paste_y = int(round(center_y - rotated.height / 2.0))

                # Alpha blend onto canvas
                canvas.alpha_composite(rotated, dest=(paste_x, paste_y))

        return canvas


# Global cached detector and renderer for still captures
_still_detector: Optional[FaceDetector] = None
_still_renderer: Optional[ARRenderer] = None


def get_ar_state() -> Dict[str, Any]:
    """
    Retrieve active AR state (enabled, active_effect).
    Cached via ar_state.json on disk for low latency (<0.1ms) across processes.
    """
    if AR_STATE_FILE.is_file():
        try:
            with open(AR_STATE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    return data
        except Exception:
            pass
    return {"enabled": True, "active_effect": "glasses"}


def save_ar_state(enabled: bool, active_effect: str) -> None:
    """
    Atomically persist active AR state to disk for cross-process synchronization.
    """
    state = {"enabled": enabled, "active_effect": active_effect}
    try:
        tmp_file = AR_STATE_FILE.with_suffix(".tmp")
        with open(tmp_file, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)
        tmp_file.replace(AR_STATE_FILE)
    except Exception as err:
        sys.stderr.write(f"[ar_engine] Warning: Could not save AR state: {err}\n")


def apply_ar_to_still(
    image: Image.Image,
    state_override: Optional[Dict[str, Any]] = None,
    score_threshold: float = 0.40,
) -> Image.Image:
    """
    Apply currently selected AR effect to a newly captured still image.

    Guarantees:
    1. Reads active AR state (enabled, active_effect).
    2. If disabled or effect is 'none', returns image immediately (0ms).
    3. Runs fresh face detection on the actual captured still (never uses stale preview coords).
    4. Filters out low-confidence detections (score_threshold).
    5. Supports multi-face natively.
    6. Decoupled and data-driven (anchors, rotation, scaling, offsets).
    7. Fails gracefully: returns original image if any error occurs.
    """
    global _still_detector, _still_renderer

    state = state_override or get_ar_state()
    if not state.get("enabled", True):
        return image

    active_effect = state.get("active_effect", "glasses")
    if not active_effect or active_effect == "none" or active_effect not in AR_EFFECT_CONFIGS:
        return image

    try:
        # Convert PIL image to BGR numpy array for OpenCV YuNet detection
        img_rgb = image.convert("RGB")
        img_np = np.array(img_rgb)
        img_bgr = cv2.cvtColor(img_np, cv2.COLOR_RGB2BGR)

        if _still_detector is None:
            _still_detector = FaceDetector(model_path=DEFAULT_MODEL_PATH, score_threshold=score_threshold)
        else:
            _still_detector.score_threshold = score_threshold

        faces, _ = _still_detector.detect(img_bgr)
        valid_faces = [f for f in faces if f.confidence >= score_threshold]

        if not valid_faces:
            return image

        if _still_renderer is None:
            _still_renderer = ARRenderer(asset_base_dir=REPO_ROOT)

        composited = _still_renderer.render_effect(image, active_effect, valid_faces)
        if image.mode == "RGB":
            return composited.convert("RGB")
        return composited
    except Exception as err:
        sys.stderr.write(f"[ar_engine] Warning: Failed to apply AR effect to captured still: {err}\n")
        return image
