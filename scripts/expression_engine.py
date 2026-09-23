#!/usr/bin/env python3
"""
scripts/expression_engine.py - Generic Facial Expression Detection & State Tracking Engine.

Architectural Guarantees:
- Generic & decoupled: Operates purely on facial geometry and landmark metrics.
  Zero effect-specific branching (no 'if effect == dog' or 'show_tongue()').
- Independent per-face state: Multi-face temporal tracking with dedicated EMA
  smoothing, dual-threshold Schmitt trigger hysteresis, and transition event dispatch.
- Single-event emission: Transition events ('mouth_opened', 'mouth_closed') are emitted
  strictly once at state transition boundaries, never repeated continuously across frames.
- Graceful degradation: If OpenCV DNN or the FaceMesh ONNX model is unavailable,
  the engine safely reports unavailable and avoids impacting the primary YuNet AR pipeline.
- Standard libraries: Built with NumPy and OpenCV (pre-installed in the Pi runtime environment).
"""

from dataclasses import dataclass, field
import math
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

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FACEMESH_PATH = REPO_ROOT / "models" / "face_mesh.onnx"

# MediaPipe Face Mesh landmark indices for mouth geometry
INDEX_LIP_UPPER_CENTER = 13
INDEX_LIP_LOWER_CENTER = 14
INDEX_LIP_UPPER_LEFT_MID = 82
INDEX_LIP_LOWER_LEFT_MID = 87
INDEX_LIP_UPPER_RIGHT_MID = 312
INDEX_LIP_LOWER_RIGHT_MID = 317
INDEX_MOUTH_CORNER_LEFT = 78
INDEX_MOUTH_CORNER_RIGHT = 308

REQUIRED_MOUTH_INDICES = [
    INDEX_LIP_UPPER_CENTER,
    INDEX_LIP_LOWER_CENTER,
    INDEX_LIP_UPPER_LEFT_MID,
    INDEX_LIP_LOWER_LEFT_MID,
    INDEX_LIP_UPPER_RIGHT_MID,
    INDEX_LIP_LOWER_RIGHT_MID,
    INDEX_MOUTH_CORNER_LEFT,
    INDEX_MOUTH_CORNER_RIGHT,
]

# Experimental thresholds verified on Raspberry Pi 5
DEFAULT_OPEN_THRESHOLD = 0.28
DEFAULT_CLOSE_THRESHOLD = 0.16
DEFAULT_EMA_ALPHA = 0.45
DEFAULT_HYSTERESIS_FRAMES = 2


def compute_mouth_aspect_ratio(landmarks: Any) -> float:
    """
    Calculate normalized Mouth Aspect Ratio (MAR) using MediaPipe inner-lip geometry.

    Landmarks array shape: (N, 3) where columns are (x, y, z).
    Indices:
      13: Upper lip inner center
      14: Lower lip inner center
      82: Upper lip inner left mid
      87: Lower lip inner left mid
      312: Upper lip inner right mid
      317: Lower lip inner right mid
      78: Inner left mouth corner
      308: Inner right mouth corner

    Returns:
      Dimensionless ratio of vertical inner lip separation to horizontal mouth width.
    """
    if landmarks is None or len(landmarks) <= max(REQUIRED_MOUTH_INDICES):
        return 0.0

    p13 = landmarks[INDEX_LIP_UPPER_CENTER][:2]
    p14 = landmarks[INDEX_LIP_LOWER_CENTER][:2]
    p82 = landmarks[INDEX_LIP_UPPER_LEFT_MID][:2]
    p87 = landmarks[INDEX_LIP_LOWER_LEFT_MID][:2]
    p312 = landmarks[INDEX_LIP_UPPER_RIGHT_MID][:2]
    p317 = landmarks[INDEX_LIP_LOWER_RIGHT_MID][:2]
    p78 = landmarks[INDEX_MOUTH_CORNER_LEFT][:2]
    p308 = landmarks[INDEX_MOUTH_CORNER_RIGHT][:2]

    # Euclidean distances
    if np is not None and isinstance(landmarks, np.ndarray):
        d_center = float(np.linalg.norm(p14 - p13))
        d_left_mid = float(np.linalg.norm(p87 - p82))
        d_right_mid = float(np.linalg.norm(p317 - p312))
        w_mouth = float(np.linalg.norm(p308 - p78))
    else:
        d_center = math.hypot(p14[0] - p13[0], p14[1] - p13[1])
        d_left_mid = math.hypot(p87[0] - p82[0], p87[1] - p82[1])
        d_right_mid = math.hypot(p317[0] - p312[0], p317[1] - p312[1])
        w_mouth = math.hypot(p308[0] - p78[0], p308[1] - p78[1])

    if w_mouth < 1e-4:
        return 0.0

    # Weighted inner vertical lip separation
    h_inner = (d_left_mid + 2.0 * d_center + d_right_mid) / 4.0

    return float(h_inner / w_mouth)


def extract_face_roi(
    img_bgr: Any,
    bbox: Tuple[float, float, float, float],
    crop_margin: float = 0.25,
) -> Tuple[Any, float, float]:
    """
    Crop an expanded square ROI around the face bounding box and zero-pad if out of bounds.

    Args:
      img_bgr: Source image numpy array (H, W, 3).
      bbox: Bounding box tuple (x, y, w, h) in pixels.
      crop_margin: Expansion margin fraction (0.25 yields 1.5x bounding box width).

    Returns:
      (roi_bgr_square, side_length, side_length)
    """
    if img_bgr is None or np is None:
        return None, 0.0, 0.0

    h, w = img_bgr.shape[:2]
    bx, by, bw, bh = bbox

    cx = bx + bw / 2.0
    cy = by + bh / 2.0
    side = max(bw, bh) * (1.0 + crop_margin)

    x0 = int(round(cx - side / 2.0))
    y0 = int(round(cy - side / 2.0))
    x1 = int(round(x0 + side))
    y1 = int(round(y0 + side))

    src_x0 = max(0, x0)
    src_y0 = max(0, y0)
    src_x1 = min(w, x1)
    src_y1 = min(h, y1)

    roi_side = max(1, int(round(side)))
    roi = np.zeros((roi_side, roi_side, 3), dtype=img_bgr.dtype)

    if src_x1 > src_x0 and src_y1 > src_y0:
        dst_x0 = src_x0 - x0
        dst_y0 = src_y0 - y0
        dst_x1 = dst_x0 + (src_x1 - src_x0)
        dst_y1 = dst_y0 + (src_y1 - src_y0)
        roi[dst_y0:dst_y1, dst_x0:dst_x1] = img_bgr[src_y0:src_y1, src_x0:src_x1]

    return roi, side, side


@dataclass
class FaceExpressionTrack:
    """Independent temporal tracking and expression state for a single face."""
    face_id: int
    centroid: Tuple[float, float]
    bbox: Tuple[float, float, float, float]  # (x, y, w, h)
    raw_mar: float = 0.0
    smooth_mar: float = 0.0
    mouth_state: str = "CLOSED"              # "CLOSED" or "OPEN"
    consecutive_open_frames: int = 0
    consecutive_close_frames: int = 0
    last_seen: float = 0.0
    active_event: Optional[str] = None       # Set strictly on state transition ("mouth_opened" / "mouth_closed")

    def to_contract_dict(self) -> Dict[str, Any]:
        """Format as generic expression state contract."""
        return {
            "expression": {
                "mouth_open": bool(self.mouth_state == "OPEN"),
                "mouth_ratio": float(round(float(self.smooth_mar), 4)),
            },
            "expression_events": [str(self.active_event)] if self.active_event else [],
        }


class MultiFaceExpressionTracker:
    """
    Manages independent temporal tracking, EMA filtering, and Schmitt trigger hysteresis
    for multiple faces across frames.
    """

    def __init__(
        self,
        open_threshold: float = DEFAULT_OPEN_THRESHOLD,
        close_threshold: float = DEFAULT_CLOSE_THRESHOLD,
        ema_alpha: float = DEFAULT_EMA_ALPHA,
        hysteresis_frames: int = DEFAULT_HYSTERESIS_FRAMES,
        max_track_distance: float = 0.18,
        track_timeout: float = 1.0,
    ):
        self.open_threshold = open_threshold
        self.close_threshold = close_threshold
        self.ema_alpha = ema_alpha
        self.hysteresis_frames = hysteresis_frames
        self.max_track_distance = max_track_distance
        self.track_timeout = track_timeout
        self._tracks: Dict[int, FaceExpressionTrack] = {}
        self._next_id: int = 1

    def update(
        self,
        observations: List[Tuple[Tuple[float, float, float, float], float]],
        frame_w: int,
        frame_h: int,
        now: float,
    ) -> List[FaceExpressionTrack]:
        """
        Match detected face observations (bbox, raw_mar) to tracks and evaluate expression state.
        Returns list of updated tracks observed in this frame, in the order of input observations.
        """
        matched_track_ids = set()
        active_results: List[FaceExpressionTrack] = []

        norm_scale = max(float(frame_w), 1.0)

        for bbox, raw_mar in observations:
            cx = (bbox[0] + bbox[2] / 2.0) / norm_scale
            cy = (bbox[1] + bbox[3] / 2.0) / norm_scale

            # Find nearest existing track by normalized Euclidean centroid distance
            best_dist = self.max_track_distance
            best_track: Optional[FaceExpressionTrack] = None

            for t_id, track in self._tracks.items():
                if t_id in matched_track_ids:
                    continue
                dx = track.centroid[0] - cx
                dy = track.centroid[1] - cy
                dist = math.hypot(dx, dy)
                if dist < best_dist:
                    best_dist = dist
                    best_track = track

            if best_track is None:
                # Create new track
                t_id = self._next_id
                self._next_id += 1
                best_track = FaceExpressionTrack(
                    face_id=t_id,
                    centroid=(cx, cy),
                    bbox=bbox,
                    raw_mar=raw_mar,
                    smooth_mar=raw_mar,  # Seed EMA with initial value
                    mouth_state="CLOSED",
                    last_seen=now,
                )
                self._tracks[t_id] = best_track

            matched_track_ids.add(best_track.face_id)
            best_track.centroid = (cx, cy)
            best_track.bbox = bbox
            best_track.last_seen = now
            best_track.raw_mar = raw_mar
            best_track.active_event = None  # Reset per-frame transition event

            # 1. Temporal smoothing (EMA)
            best_track.smooth_mar = (self.ema_alpha * raw_mar) + (
                (1.0 - self.ema_alpha) * best_track.smooth_mar
            )

            # 2. Dual-threshold Schmitt trigger hysteresis
            if best_track.mouth_state == "CLOSED":
                best_track.consecutive_close_frames = 0
                if best_track.smooth_mar >= self.open_threshold:
                    best_track.consecutive_open_frames += 1
                    if best_track.consecutive_open_frames >= self.hysteresis_frames:
                        best_track.mouth_state = "OPEN"
                        best_track.active_event = "mouth_opened"
                else:
                    best_track.consecutive_open_frames = 0
            elif best_track.mouth_state == "OPEN":
                best_track.consecutive_open_frames = 0
                if best_track.smooth_mar <= self.close_threshold:
                    best_track.consecutive_close_frames += 1
                    if best_track.consecutive_close_frames >= self.hysteresis_frames:
                        best_track.mouth_state = "CLOSED"
                        best_track.active_event = "mouth_closed"
                else:
                    best_track.consecutive_close_frames = 0

            active_results.append(best_track)

        # Clean up expired tracks
        expired = [t_id for t_id, tr in self._tracks.items() if now - tr.last_seen > self.track_timeout]
        for t_id in expired:
            del self._tracks[t_id]

        return active_results


class FaceMeshDetector:
    """
    OpenCV DNN wrapper for MediaPipe Face Mesh ONNX model.
    Validates tensor output contract upon initialization.
    """

    def __init__(self, model_path: Optional[Path] = None):
        self.model_path = Path(model_path or DEFAULT_FACEMESH_PATH)
        self._net: Optional[Any] = None
        self._out_layer_names: List[str] = []
        self._landmark_layer_index: int = 0
        self.is_ready: bool = False
        self.init_error: Optional[str] = None

        self._initialize()

    def _initialize(self) -> None:
        if cv2 is None or np is None:
            self.init_error = "OpenCV (cv2) or NumPy is not available in this Python environment."
            return

        if not self.model_path.is_file():
            self.init_error = f"Face Mesh model file not found at: {self.model_path}"
            return

        try:
            net = cv2.dnn.readNetFromONNX(str(self.model_path))
            net.setPreferableBackend(cv2.dnn.DNN_BACKEND_OPENCV)
            net.setPreferableTarget(cv2.dnn.DNN_TARGET_CPU)

            out_names = net.getUnconnectedOutLayersNames()

            # Contract verification: forward pass with synthetic 192x192 blob
            dummy_blob = np.zeros((1, 3, 192, 192), dtype=np.float32)
            net.setInput(dummy_blob)
            outputs = net.forward(out_names)

            # Locate landmark layer (468 3D points = 1404 floats, or 478 points = 1434 floats)
            lmk_idx = None
            for idx, out in enumerate(outputs):
                if out.size in (1404, 1434):
                    lmk_idx = idx
                    break

            if lmk_idx is None:
                shapes_str = ", ".join(f"{n}: {o.shape}" for n, o in zip(out_names, outputs))
                self.init_error = f"Model contract mismatch. Expected tensor size 1404, got: {shapes_str}"
                return

            self._net = net
            self._out_layer_names = out_names
            self._landmark_layer_index = lmk_idx
            self.is_ready = True
        except Exception as err:
            self.init_error = f"Failed to initialize Face Mesh ONNX: {err}"

    def detect_landmarks(self, roi_bgr: Any) -> Optional[Any]:
        """
        Run FaceMesh inference on a square face ROI.
        Returns:
          Numpy array of shape (N, 3) representing 3D landmarks in crop space, or None on failure.
        """
        if not self.is_ready or self._net is None or cv2 is None or np is None or roi_bgr is None:
            return None

        try:
            blob = cv2.dnn.blobFromImage(
                roi_bgr,
                scalefactor=1.0 / 255.0,
                size=(192, 192),
                swapRB=True,
                crop=False,
            )
            self._net.setInput(blob)
            outputs = self._net.forward(self._out_layer_names)
            lmk_out = outputs[self._landmark_layer_index]
            return lmk_out.reshape(-1, 3)
        except Exception as err:
            sys.stderr.write(f"[FaceMeshDetector] Inference warning: {err}\n")
            return None


class ExpressionEngine:
    """
    High-level generic coordinator combining FaceMesh landmark detection
    with multi-face expression state tracking.
    """

    def __init__(
        self,
        model_path: Optional[Path] = None,
        open_threshold: float = DEFAULT_OPEN_THRESHOLD,
        close_threshold: float = DEFAULT_CLOSE_THRESHOLD,
        ema_alpha: float = DEFAULT_EMA_ALPHA,
        hysteresis_frames: int = DEFAULT_HYSTERESIS_FRAMES,
    ):
        self.detector = FaceMeshDetector(model_path=model_path)
        self.tracker = MultiFaceExpressionTracker(
            open_threshold=open_threshold,
            close_threshold=close_threshold,
            ema_alpha=ema_alpha,
            hysteresis_frames=hysteresis_frames,
        )

    def is_available(self) -> bool:
        """Returns True if the underlying landmark model initialized successfully."""
        return self.detector.is_ready

    def process_faces(
        self,
        img_bgr: Any,
        face_bboxes: List[Tuple[float, float, float, float]],
        frame_w: int,
        frame_h: int,
        now: Optional[float] = None,
    ) -> List[Dict[str, Any]]:
        """
        Process a list of face bounding boxes against the current image frame.
        Extracts face ROIs, runs landmark inference, computes MAR, and updates state.

        Args:
          img_bgr: Decoded full-resolution BGR camera frame.
          face_bboxes: List of (bx, by, bw, bh) face bounding boxes in frame coordinates.
          frame_w: Full frame width.
          frame_h: Full frame height.
          now: Optional timestamp baseline (defaults to time.time()).

        Returns:
          List of dictionaries matching the generic expression contract:
          [
            {
              "expression": {
                "mouth_open": bool,
                "mouth_ratio": float,
              },
              "expression_events": List[str]  # e.g. ["mouth_opened"]
            }, ...
          ]
        """
        if not self.is_available() or not face_bboxes:
            return []

        timestamp = now if now is not None else time.time()
        observations: List[Tuple[Tuple[float, float, float, float], float]] = []

        for bbox in face_bboxes:
            roi_bgr, _, _ = extract_face_roi(img_bgr, bbox, crop_margin=0.25)
            landmarks = self.detector.detect_landmarks(roi_bgr)
            if landmarks is not None:
                mar = compute_mouth_aspect_ratio(landmarks)
            else:
                mar = 0.0
            observations.append((bbox, mar))

        tracks = self.tracker.update(observations, frame_w, frame_h, timestamp)
        return [track.to_contract_dict() for track in tracks]
