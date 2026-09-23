#!/usr/bin/env python3
"""
scripts/test-ar-expression.py - Experimental Standalone Prototype for Real-Time Mouth Expression Detection.

Architecture:
  Photobooth MJPEG Stream
            ↓
  YuNet Face Detection (Verified Baseline)
            ↓
  Face ROI Crop & Square Normalize (192x192)
            ↓
  MediaPipe Face Mesh ONNX Inference (OpenCV DNN)
            ↓
  Verified Inner Lip Landmark Extraction (Indices 13, 14, 78, 308, 82, 87, 312, 317)
            ↓
  Normalized Mouth Aspect Ratio (MAR) Calculation
            ↓
  Independent Per-Face Temporal Smoothing (EMA)
            ↓
  Dual-Threshold Hysteresis State Machine (OPEN / CLOSED)
            ↓
  Diagnostic Telemetry & Real-Time Performance Benchmarking

SAFETY GUARANTEES:
- Completely isolated from production pipeline (does NOT modify ar_engine.py or theme-selector-server.py).
- Zero effect-specific branching.
- Independent per-face tracking and hysteresis states.
- Explicit runtime validation of ONNX tensor outputs (fails loudly on shape mismatch).
"""

import argparse
from dataclasses import dataclass, field
import math
import os
from pathlib import Path
import sys
import time
from typing import Any, Dict, List, Optional, Tuple
import urllib.error
import urllib.request

try:
    import cv2
except ImportError:
    cv2 = None

try:
    import numpy as np
except ImportError:
    np = None

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

DEFAULT_YUNET_PATH = REPO_ROOT / "models" / "face_detection_yunet_2023mar.onnx"
DEFAULT_LANDMARK_PATH = REPO_ROOT / "models" / "face_mesh.onnx"
DEFAULT_STREAM_URL = "http://localhost:8000/api/aquisition/stream.mjpg"

from expression_engine import (
    INDEX_LIP_UPPER_CENTER,
    INDEX_LIP_LOWER_CENTER,
    INDEX_LIP_UPPER_LEFT_MID,
    INDEX_LIP_LOWER_LEFT_MID,
    INDEX_LIP_UPPER_RIGHT_MID,
    INDEX_LIP_LOWER_RIGHT_MID,
    INDEX_MOUTH_CORNER_LEFT,
    INDEX_MOUTH_CORNER_RIGHT,
    REQUIRED_MOUTH_INDICES,
    FaceExpressionTrack as FaceTrackState,
    MultiFaceExpressionTracker,
    compute_mouth_aspect_ratio,
    extract_face_roi,
    DEFAULT_FACEMESH_PATH,
    DEFAULT_OPEN_THRESHOLD,
    DEFAULT_CLOSE_THRESHOLD,
    DEFAULT_EMA_ALPHA,
    DEFAULT_HYSTERESIS_FRAMES,
)


def load_and_validate_face_mesh_model(model_path: Path) -> Tuple[Any, List[str]]:
    """
    Load Face Mesh ONNX model via OpenCV DNN and validate its output tensor contract.
    Fails loudly with actionable diagnostics if tensor shapes are invalid.
    """
    if not model_path.is_file():
        raise FileNotFoundError(
            f"Face Mesh model file not found at: {model_path}\n"
            f"Please verify model download and placement before running."
        )

    print(f"Loading Face Mesh model from: {model_path}")
    net = cv2.dnn.readNetFromONNX(str(model_path))

    # Enable CPU backend with standard default target
    net.setPreferableBackend(cv2.dnn.DNN_BACKEND_OPENCV)
    net.setPreferableTarget(cv2.dnn.DNN_TARGET_CPU)

    out_names = net.getUnconnectedOutLayersNames()
    print(f"  • Unconnected output layers: {out_names}")

    # Validate output contract by passing a synthetic 192x192 test blob
    dummy_blob = np.zeros((1, 3, 192, 192), dtype=np.float32)
    net.setInput(dummy_blob)
    outputs = net.forward(out_names)

    # Locate the landmark tensor
    landmark_tensor = None
    landmark_layer_name = None

    for name, out in zip(out_names, outputs):
        out_shape = out.shape
        flat_size = out.size
        # MediaPipe Face Mesh standard is 468 3D points = 1404 coordinates
        if flat_size in (1404, 1434):  # 468*3 = 1404, 478*3 = 1434 (with iris)
            landmark_tensor = out
            landmark_layer_name = name
            print(f"  • Found verified landmark tensor in layer '{name}' (shape: {out_shape}, size: {flat_size})")
            break

    if landmark_tensor is None:
        shapes_info = [f"layer '{n}': shape {o.shape}" for n, o in zip(out_names, outputs)]
        raise ValueError(
            f"Model output contract validation FAILED.\n"
            f"Expected landmark tensor with 1404 floats (468 3D landmarks).\n"
            f"Actual layers returned: {', '.join(shapes_info)}\n"
            f"Do not silently reinterpret unexpected tensors. Please verify the ONNX model artifact."
        )

    return net, out_names



def main():
    parser = argparse.ArgumentParser(
        description="Isolated Expression Detection Prototype (MediaPipe Face Mesh ONNX + OpenCV YuNet)"
    )
    parser.add_argument("--stream-url", default=DEFAULT_STREAM_URL, help="MJPEG stream URL")
    parser.add_argument("--yunet-model", default=str(DEFAULT_YUNET_PATH), help="Path to YuNet ONNX model")
    parser.add_argument("--landmark-model", default=str(DEFAULT_LANDMARK_PATH), help="Path to Face Mesh ONNX model")
    parser.add_argument("--open-thresh", type=float, default=0.28, help="MAR threshold to trigger mouth_opened")
    parser.add_argument("--close-thresh", type=float, default=0.16, help="MAR threshold to trigger mouth_closed")
    parser.add_argument("--ema-alpha", type=float, default=0.45, help="EMA temporal smoothing alpha (0.0 to 1.0)")
    parser.add_argument("--hysteresis-frames", type=int, default=2, help="Consecutive frames required for state change")
    parser.add_argument("--downscale", type=float, default=0.5, help="YuNet downscale factor (e.g. 0.5 for 528x352)")
    parser.add_argument("--crop-margin", type=float, default=0.25, help="Face ROI square crop expansion margin")
    parser.add_argument("--frames", type=int, default=0, help="Number of frames to process (0 = continuous)")
    parser.add_argument("--benchmark-interval", type=int, default=30, help="Print benchmark summary every N frames")
    args = parser.parse_args()

    if cv2 is None or np is None:
        print("Error: OpenCV (cv2) and NumPy are required to run this diagnostic script.", file=sys.stderr)
        sys.exit(1)

    print("==================================================")
    print("EXPRESSION-REACTIVE AR: MOUTH DETECTION PROTOTYPE")
    print("==================================================")
    print(f"Stream URL:          {args.stream_url}")
    print(f"YuNet Model:         {args.yunet_model}")
    print(f"Face Mesh Model:     {args.landmark_model}")
    print(f"Hysteresis Config:   OPEN >= {args.open_thresh} | CLOSE <= {args.close_thresh} | Frames: {args.hysteresis_frames}")
    print(f"EMA Smoothing Alpha: {args.ema_alpha}")
    print("==================================================\n")

    # 1. Initialize YuNet Face Detector
    yunet_path = Path(args.yunet_model)
    if not yunet_path.is_file():
        print(f"Error: YuNet model file not found at {yunet_path}", file=sys.stderr)
        sys.exit(1)

    print(f"Initializing YuNet detector: {yunet_path.name}")
    yunet_detector = cv2.FaceDetectorYN.create(
        model=str(yunet_path),
        config="",
        input_size=(528, 352),
        score_threshold=0.35,
        nms_threshold=0.3,
        top_k=5000,
    )

    # 2. Initialize and Validate Face Mesh Model
    mesh_path = Path(args.landmark_model)
    try:
        mesh_net, out_layer_names = load_and_validate_face_mesh_model(mesh_path)
    except Exception as err:
        print(f"\n[FATAL] Model loading or validation error:\n{err}", file=sys.stderr)
        print("\nPlease ensure the verified MediaPipe Face Mesh ONNX artifact is present.", file=sys.stderr)
        sys.exit(1)

    # 3. Initialize Multi-Face Expression Tracker
    tracker = MultiFaceExpressionTracker(
        open_threshold=args.open_thresh,
        close_threshold=args.close_thresh,
        ema_alpha=args.ema_alpha,
        hysteresis_frames=args.hysteresis_frames,
    )

    # Performance instrumentation lists
    dec_times: List[float] = []
    yunet_times: List[float] = []
    roi_times: List[float] = []
    mesh_times: List[float] = []
    calc_times: List[float] = []
    total_times: List[float] = []

    frames_processed = 0
    print(f"\nConnecting to MJPEG stream at: {args.stream_url} ...")

    try:
        req = urllib.request.Request(args.stream_url)
        with urllib.request.urlopen(req, timeout=10) as resp:
            print("Connected! Reading live frames...\n")
            buf = b""

            while args.frames == 0 or frames_processed < args.frames:
                chunk = resp.read(8192)
                if not chunk:
                    print("Stream ended or disconnected.")
                    break
                buf += chunk

                # Parse JPEG boundary
                if b"\xff\xd9" in buf:
                    end_idx = buf.rfind(b"\xff\xd9")
                    start_idx = buf.rfind(b"\xff\xd8", 0, end_idx)
                    if start_idx != -1 and end_idx > start_idx:
                        jpg_bytes = buf[start_idx : end_idx + 2]
                        buf = buf[end_idx + 2 :]

                        t_frame_start = time.perf_counter()

                        # Stage 1: Decode and downscale
                        t0 = time.perf_counter()
                        arr = np.frombuffer(jpg_bytes, dtype=np.uint8)
                        img_bgr = cv2.imdecode(arr, cv2.IMREAD_COLOR)
                        if img_bgr is None:
                            continue
                        orig_h, orig_w = img_bgr.shape[:2]

                        det_w = int(round(orig_w * args.downscale))
                        det_h = int(round(orig_h * args.downscale))
                        img_det = cv2.resize(img_bgr, (det_w, det_h), interpolation=cv2.INTER_LINEAR)
                        t_dec_ms = (time.perf_counter() - t0) * 1000.0

                        # Stage 2: YuNet Face Detection
                        t0 = time.perf_counter()
                        yunet_detector.setInputSize((det_w, det_h))
                        _, raw_faces = yunet_detector.detect(img_det)
                        t_yunet_ms = (time.perf_counter() - t0) * 1000.0

                        # Stage 3: Face ROI Processing & Dense Landmarks
                        frame_observations: List[Tuple[Tuple[float, float, float, float], float]] = []
                        t_roi_frame_ms = 0.0
                        t_mesh_frame_ms = 0.0
                        t_calc_frame_ms = 0.0

                        if raw_faces is not None and len(raw_faces) > 0:
                            scale_x = orig_w / float(det_w)
                            scale_y = orig_h / float(det_h)

                            for face_row in raw_faces:
                                # Scale bounding box back to original frame dimensions
                                bx = float(face_row[0]) * scale_x
                                by = float(face_row[1]) * scale_y
                                bw = float(face_row[2]) * scale_x
                                bh = float(face_row[3]) * scale_y
                                bbox = (bx, by, bw, bh)

                                # Crop and square-pad ROI
                                t_roi_0 = time.perf_counter()
                                roi_bgr, _, _ = extract_face_roi(img_bgr, bbox, crop_margin=args.crop_margin)
                                blob = cv2.dnn.blobFromImage(
                                    roi_bgr,
                                    scalefactor=1.0 / 255.0,
                                    size=(192, 192),
                                    swapRB=True,
                                    crop=False,
                                )
                                t_roi_frame_ms += (time.perf_counter() - t_roi_0) * 1000.0

                                # Run Face Mesh Inference
                                t_mesh_0 = time.perf_counter()
                                mesh_net.setInput(blob)
                                outputs = mesh_net.forward(out_layer_names)
                                t_mesh_frame_ms += (time.perf_counter() - t_mesh_0) * 1000.0

                                # Extract landmarks
                                t_calc_0 = time.perf_counter()
                                lmk_out = outputs[0] if outputs[0].size in (1404, 1434) else outputs[1]
                                lmk_pts = lmk_out.reshape(-1, 3)

                                # Compute normalized MAR
                                mar = compute_mouth_aspect_ratio(lmk_pts)
                                t_calc_frame_ms += (time.perf_counter() - t_calc_0) * 1000.0

                                frame_observations.append((bbox, mar))

                        # Stage 4: Multi-Face State Tracking
                        now = time.time()
                        t_calc_0 = time.perf_counter()
                        active_tracks = tracker.update(frame_observations, orig_w, orig_h, now)
                        t_calc_frame_ms += (time.perf_counter() - t_calc_0) * 1000.0

                        t_total_ms = (time.perf_counter() - t_frame_start) * 1000.0

                        # Record benchmarks
                        dec_times.append(t_dec_ms)
                        yunet_times.append(t_yunet_ms)
                        roi_times.append(t_roi_frame_ms)
                        mesh_times.append(t_mesh_frame_ms)
                        calc_times.append(t_calc_frame_ms)
                        total_times.append(t_total_ms)
                        frames_processed += 1

                        # Print real-time expression telemetry
                        if active_tracks:
                            for tr in active_tracks:
                                event_str = f" | EVENT {tr.active_event}" if tr.active_event else ""
                                print(
                                    f"Face {tr.face_id} | MAR raw={tr.raw_mar:.3f} | smooth={tr.smooth_mar:.3f} | {tr.mouth_state}{event_str}"
                                )
                        else:
                            if frames_processed % 30 == 0:
                                print(f"[Frame {frames_processed}] No faces in view.")

                        # Print rolling benchmark summary periodically
                        if frames_processed % args.benchmark_interval == 0:
                            n = args.benchmark_interval
                            avg_dec = np.mean(dec_times[-n:])
                            avg_yunet = np.mean(yunet_times[-n:])
                            avg_roi = np.mean(roi_times[-n:])
                            avg_mesh = np.mean(mesh_times[-n:])
                            avg_calc = np.mean(calc_times[-n:])
                            avg_tot = np.mean(total_times[-n:])
                            fps = 1000.0 / max(avg_tot, 1e-3)

                            print(
                                f"\n--- [BENCHMARK (last {n} frames)] "
                                f"Decode: {avg_dec:.1f}ms | YuNet: {avg_yunet:.1f}ms | "
                                f"ROI: {avg_roi:.1f}ms | Mesh: {avg_mesh:.1f}ms | "
                                f"Calc: {avg_calc:.1f}ms | Total: {avg_tot:.1f}ms ({fps:.1f} FPS) ---\n"
                            )

    except KeyboardInterrupt:
        print("\nBenchmark stopped by user.")
    except Exception as err:
        print(f"\nStream processing error: {err}", file=sys.stderr)


if __name__ == "__main__":
    main()
