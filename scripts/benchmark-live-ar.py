#!/usr/bin/env python3
"""
scripts/benchmark-live-ar.py - Measure live AR detection pipeline performance on Raspberry Pi 5.

Measures:
1. Frame grab and JPEG decode latency (ms)
2. Local YuNet inference latency at 528x352 (ms)
3. Geometric transform & normalization latency (ms)
4. Total pipeline latency per frame (ms)
5. Effective camera stream input FPS
6. Maximum potential inference FPS capacity
7. CPU utilization of the inference thread / system
"""

import argparse
import os
from pathlib import Path
import sys
import time
import urllib.request
import cv2
import numpy as np

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from ar_engine import DEFAULT_MODEL_PATH, FaceDetector, process_stream_frame


def get_cpu_times():
    """Read cumulative CPU ticks from /proc/stat if available."""
    try:
        with open("/proc/stat", "r") as f:
            line = f.readline()
            fields = [float(x) for x in line.strip().split()[1:]]
            idle = fields[3] + fields[4]
            total = sum(fields)
            return idle, total
    except Exception:
        return 0.0, 0.0


def main():
    parser = argparse.ArgumentParser(description="Benchmark live AR pipeline on Raspberry Pi 5.")
    parser.add_argument(
        "--stream-url",
        default="http://127.0.0.1:8000/api/aquisition/stream.mjpg",
        help="Live MJPEG stream URL",
    )
    parser.add_argument(
        "--frames",
        type=int,
        default=45,
        help="Number of frames to benchmark (default: 45, ~3s of 15fps stream)",
    )
    parser.add_argument(
        "--downscale",
        type=float,
        default=0.5,
        help="Downscale factor for inference (default: 0.5)",
    )
    args = parser.parse_args()

    print("=====================================================================")
    print("  LIVE AR PREVIEW RUNTIME BENCHMARK (Raspberry Pi 5)")
    print(f"  Stream URL: {args.stream_url}")
    print(f"  Frames to measure: {args.frames}")
    print(f"  Downscale factor: {args.downscale}")
    print(f"  Model ONNX path: {DEFAULT_MODEL_PATH}")
    print("=====================================================================")

    detector = FaceDetector(model_path=DEFAULT_MODEL_PATH, score_threshold=0.35)

    print("Connecting to live MJPEG stream...")
    req = urllib.request.Request(args.stream_url)

    decode_times = []
    inference_times = []
    total_frame_times = []
    frame_timestamps = []
    detected_face_counts = []

    start_idle, start_total = get_cpu_times()
    start_wall = time.perf_counter()

    with urllib.request.urlopen(req, timeout=10) as resp:
        buf = b""
        frames_collected = 0

        # Warm up 3 frames
        warmup = 0
        while warmup < 3:
            chunk = resp.read(8192)
            if not chunk:
                break
            buf += chunk
            if b"\xff\xd9" in buf:
                end_idx = buf.rfind(b"\xff\xd9")
                start_idx = buf.rfind(b"\xff\xd8", 0, end_idx)
                if start_idx != -1 and end_idx > start_idx:
                    jpg = buf[start_idx : end_idx + 2]
                    buf = buf[end_idx + 2 :]
                    process_stream_frame(detector, jpg, downscale_factor=args.downscale)
                    warmup += 1

        print("Warmup complete. Benchmarking live stream frames...")
        buf = b""

        while frames_collected < args.frames:
            chunk = resp.read(8192)
            if not chunk:
                break
            buf += chunk

            if b"\xff\xd9" in buf:
                end_idx = buf.rfind(b"\xff\xd9")
                start_idx = buf.rfind(b"\xff\xd8", 0, end_idx)
                if start_idx != -1 and end_idx > start_idx:
                    jpg_bytes = buf[start_idx : end_idx + 2]
                    buf = buf[end_idx + 2 :]

                    t_frame_start = time.perf_counter()

                    # 1. Decode & downscale
                    t_dec_start = time.perf_counter()
                    arr = np.frombuffer(jpg_bytes, dtype=np.uint8)
                    img_bgr = cv2.imdecode(arr, cv2.IMREAD_COLOR)
                    orig_h, orig_w = img_bgr.shape[:2]
                    det_w = int(round(orig_w * args.downscale))
                    det_h = int(round(orig_h * args.downscale))
                    img_det = cv2.resize(img_bgr, (det_w, det_h), interpolation=cv2.INTER_LINEAR)
                    dec_ms = (time.perf_counter() - t_dec_start) * 1000.0

                    # 2. Inference
                    faces, inf_ms = detector.detect(img_det)

                    # 3. Transform
                    from ar_engine import compute_face_transform
                    for f in faces:
                        tr = compute_face_transform(f, det_w, det_h)
                        _ = tr.to_normalized_dict(det_w, det_h)

                    t_frame_total = (time.perf_counter() - t_frame_start) * 1000.0

                    decode_times.append(dec_ms)
                    inference_times.append(inf_ms)
                    total_frame_times.append(t_frame_total)
                    frame_timestamps.append(t_frame_start)
                    detected_face_counts.append(len(faces))

                    frames_collected += 1
                    if frames_collected % 15 == 0 or frames_collected == args.frames:
                        print(f"  Processed frame {frames_collected}/{args.frames}: inf={inf_ms:.1f}ms, total={t_frame_total:.1f}ms, faces={len(faces)}")

    end_wall = time.perf_counter()
    end_idle, end_total = get_cpu_times()

    # Calculate metrics
    wall_duration = end_wall - start_wall
    avg_dec_ms = np.mean(decode_times)
    avg_inf_ms = np.mean(inference_times)
    avg_total_ms = np.mean(total_frame_times)
    p95_inf_ms = np.percentile(inference_times, 95)
    max_inf_fps = 1000.0 / avg_inf_ms if avg_inf_ms > 0 else 0
    max_pipeline_fps = 1000.0 / avg_total_ms if avg_total_ms > 0 else 0

    # Stream arrival FPS
    inter_frame_intervals = np.diff(frame_timestamps)
    avg_stream_interval = np.mean(inter_frame_intervals) if len(inter_frame_intervals) > 0 else 0.066
    stream_delivery_fps = 1.0 / avg_stream_interval if avg_stream_interval > 0 else 0.0

    # CPU utilization across the measured period
    cpu_pct = 0.0
    if end_total > start_total:
        idle_delta = end_idle - start_idle
        total_delta = end_total - start_total
        cpu_pct = 100.0 * (1.0 - (idle_delta / total_delta))

    print("\n=====================================================================")
    print("  MEASURED RESULTS ON THIS RASPBERRY PI 5")
    print("=====================================================================")
    print(f"  Input Resolution (Canon DSLR):     {orig_w}x{orig_h}")
    print(f"  Inference Resolution (0.5x):       {det_w}x{det_h}")
    print(f"  Canon Stream Delivery Rate:        {stream_delivery_fps:.2f} FPS ({avg_stream_interval*1000:.1f} ms interval)")
    print("---------------------------------------------------------------------")
    print(f"  JPEG Decode + Resize Latency:      {avg_dec_ms:.2f} ms")
    print(f"  YuNet Detector Inference Latency:  {avg_inf_ms:.2f} ms (p95: {p95_inf_ms:.2f} ms)")
    print(f"  Total Frame Processing Latency:    {avg_total_ms:.2f} ms")
    print("---------------------------------------------------------------------")
    print(f"  Detector Capacity (Inference only):{max_inf_fps:.1f} FPS")
    print(f"  Full Pipeline Capacity:            {max_pipeline_fps:.1f} FPS")
    print(f"  Total System CPU Load:             {cpu_pct:.1f}%")
    print(f"  Detected Faces in Field:           {max(detected_face_counts)} max, {min(detected_face_counts)} min")
    print("=====================================================================")


if __name__ == "__main__":
    main()
