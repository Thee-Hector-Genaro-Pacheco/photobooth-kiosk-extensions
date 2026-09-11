#!/usr/bin/env python3
"""
scripts/test-ar-prototype.py - AR Landmark Detection & Glasses Placement Prototype Validation.

Executes Phase A, Phase B, and Phase C acceptance tests on the live Raspberry Pi 5.
"""

import argparse
import json
import os
from pathlib import Path
import sys
import time
import urllib.request
import cv2
import numpy as np
from PIL import Image

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from ar_engine import AR_EFFECT_CONFIGS, ARRenderer, FaceDetector, compute_face_transform


def grab_stream_frame(stream_url: str) -> np.ndarray:
    """Grab exactly one fresh JPEG frame from the live acquisition stream."""
    req = urllib.request.Request(stream_url)
    with urllib.request.urlopen(req, timeout=5) as resp:
        data = b""
        while b"\xff\xd9" not in data:
            data += resp.read(4096)
        start = data.find(b"\xff\xd8")
        end = data.find(b"\xff\xd9") + 2
        jpg_bytes = data[start:end]

    arr = np.frombuffer(jpg_bytes, dtype=np.uint8)
    img_bgr = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    return img_bgr


def main():
    parser = argparse.ArgumentParser(description="Test and validate AR Glasses Prototype on Pi 5.")
    parser.add_argument(
        "--stream-url",
        default="http://127.0.0.1:8000/api/aquisition/stream.mjpg",
        help="Live acquisition stream URL",
    )
    parser.add_argument(
        "--image",
        default=None,
        help="Optional static image file for testing",
    )
    parser.add_argument(
        "--output",
        default=str(REPO_ROOT / "scratch" / "ar_prototype_glasses.jpg"),
        help="Output path for prototype image",
    )
    args = parser.parse_args()

    os.makedirs(Path(args.output).parent, exist_ok=True)
    model_path = REPO_ROOT / "models" / "face_detection_yunet_2023mar.onnx"

    print("=====================================================================")
    print("  PHASE A — MODEL VALIDATION (Measured on this Raspberry Pi 5)")
    print("=====================================================================")

    # Initialize local detector
    detector = FaceDetector(model_path=model_path, score_threshold=0.35)

    # 1. Obtain frame
    img_source_desc = ""
    if args.image and os.path.isfile(args.image):
        img_bgr = cv2.imread(args.image)
        img_source_desc = f"Static image: {args.image}"
    else:
        try:
            img_bgr = grab_stream_frame(args.stream_url)
            img_source_desc = f"Live stream: {args.stream_url}"
        except Exception as err:
            fallback = REPO_ROOT / "ui" / "assets" / "sample-photo.jpg"
            print(f"Warning: Live stream unreachable ({err}). Falling back to {fallback}")
            img_bgr = cv2.imread(str(fallback))
            img_source_desc = f"Fallback sample: {fallback}"

    h, w, _ = img_bgr.shape
    print(f"Source: {img_source_desc}")
    print(f"Frame Resolution: {w} x {h}")

    # 2. Run detection and measure inference time
    faces, dt_ms = detector.detect(img_bgr)

    print(f"\n[PHASE A RESULTS]")
    print(f"  • Model: OpenCV YuNet ONNX (face_detection_yunet_2023mar.onnx)")
    print(f"  • Model License: Apache 2.0 (OpenCV Zoo)")
    print(f"  • Inference Time: {dt_ms:.2f} ms (Measured on this hardware)")
    print(f"  • Number of Faces Detected: {len(faces)}")

    if not faces:
        print("\nNote: No face detected in this particular frame (camera empty).")
        print("Testing multi-face detection on sample-photo.jpg to demonstrate landmark geometry...")
        sample_path = REPO_ROOT / "ui" / "assets" / "sample-photo.jpg"
        img_bgr = cv2.imread(str(sample_path))
        h, w, _ = img_bgr.shape
        faces, dt_ms = detector.detect(img_bgr)
        print(f"  • Sample Photo Resolution: {w} x {h}")
        print(f"  • Sample Inference Time: {dt_ms:.2f} ms")
        print(f"  • Number of Faces Detected: {len(faces)}")

    for idx, face in enumerate(faces):
        print(f"\n  --- Face #{idx + 1} ---")
        print(f"  Confidence:          {face.confidence * 100:.1f}%")
        print(f"  Bounding Box:        x={face.bbox[0]:.1f}, y={face.bbox[1]:.1f}, w={face.bbox[2]:.1f}, h={face.bbox[3]:.1f}")
        print(f"  Left Eye (pixel):    ({face.left_eye[0]:.1f}, {face.left_eye[1]:.1f})")
        print(f"  Right Eye (pixel):   ({face.right_eye[0]:.1f}, {face.right_eye[1]:.1f})")
        print(f"  Nose Tip (pixel):    ({face.nose[0]:.1f}, {face.nose[1]:.1f})")
        print(f"  Mouth Right Corner:  ({face.right_mouth[0]:.1f}, {face.right_mouth[1]:.1f})")
        print(f"  Mouth Left Corner:   ({face.left_mouth[0]:.1f}, {face.left_mouth[1]:.1f})")

    print("\n=====================================================================")
    print("  PHASE B — GENERIC TRANSFORM VALIDATION")
    print("=====================================================================")

    transforms = []
    for idx, face in enumerate(faces):
        xf = compute_face_transform(face, w, h)
        transforms.append(xf)
        norm = face.to_normalized(w, h)
        print(f"\n  --- Transform #{idx + 1} ---")
        print(f"  Normalized Left Eye:     ({norm['left_eye'][0]:.4f}, {norm['left_eye'][1]:.4f})")
        print(f"  Normalized Right Eye:    ({norm['right_eye'][0]:.4f}, {norm['right_eye'][1]:.4f})")
        print(f"  Normalized Nose:         ({norm['nose'][0]:.4f}, {norm['nose'][1]:.4f})")
        print(f"  Eye Center Position:     ({xf.center_eyes[0]:.1f}, {xf.center_eyes[1]:.1f})")
        print(f"  Inter-Eye Distance:      {xf.inter_eye_distance:.1f} px")
        print(f"  Face Scale Factor:       {xf.face_scale:.4f} (relative to image width)")
        print(f"  Head Roll Angle:         {xf.roll_angle_deg:.2f}°")
        print(f"  Forehead Anchor:         ({xf.forehead_anchor[0]:.1f}, {xf.forehead_anchor[1]:.1f})")
        print(f"  Nose Anchor:             ({xf.nose_anchor[0]:.1f}, {xf.nose_anchor[1]:.1f})")

    print("\n=====================================================================")
    print("  PHASE C — GLASSES PROTOTYPE RENDERING (Data-Driven)")
    print("=====================================================================")

    renderer = ARRenderer(asset_base_dir=REPO_ROOT)
    img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
    pil_base = Image.fromarray(img_rgb)

    t0 = time.perf_counter()
    result_image = renderer.render_effect(pil_base, "glasses", faces)
    render_ms = (time.perf_counter() - t0) * 1000.0

    # Save prototype image
    result_rgb = result_image.convert("RGB")
    result_rgb.save(args.output, "JPEG", quality=95)
    print(f"Render time for {len(faces)} face(s): {render_ms:.2f} ms")
    print(f"Generated prototype image saved to: {args.output}")
    print(f"Output dimensions: {result_rgb.size[0]} x {result_rgb.size[1]}")
    print("=====================================================================")


if __name__ == "__main__":
    main()
