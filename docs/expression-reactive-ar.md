# Expression-Reactive AR: Milestone 1 Technical Record & Architecture

## Overview
This document records the architectural foundation, model provenance, runtime validation, and state machine design for **Milestone 1 of Expression-Reactive AR** in the Photobooth Kiosk Extension system.

The goal of this layer is to provide generic, real-time facial expression tracking (starting with mouth open/closed detection) that integrates seamlessly with the existing production AR pipeline (YuNet 5-point face tracking, multi-face management, frame-aware coordinate projection, and still-capture compositing).

---

## 1. Verified Model Provenance & Artifact Specification

| Property | Value |
| :--- | :--- |
| **Model Name** | MediaPipe Face Mesh (468 dense 3D landmarks) |
| **Artifact Filename** | `face_mesh_Nx3x192x192.onnx` (deployed locally as `models/face_mesh.onnx`) |
| **Upstream Repository** | [`yakhyo/mediapipe-face-mesh-onnx`](https://github.com/yakhyo/mediapipe-face-mesh-onnx) (Release tag: `weights`) |
| **Upstream Mirror** | [`yakhyo/uniface-weights`](https://huggingface.co/yakhyo/uniface-weights/resolve/main/face_mesh.onnx) |
| **ONNX Opset** | 17 |
| **Exact File Size** | 2,466,068 bytes (~2.4 MB) |
| **SHA-256 Checksum** | `3ca77cf59c18e4da0eccb46695bf604683fa564253e3385892981a5c274fb10f` |

### Critical Licensing & Tracking Rule
> [!IMPORTANT]
> The exact converted ONNX artifact's third-party redistribution rights have **not** been cleared for public packaging.
> - The model binary `models/face_mesh.onnx` **MUST REMAIN UNTRACKED**.
> - Do **NOT** run `git add models/` or commit the model artifact into the Git repository.

---

## 2. Tensor Contract & Verification

### Input Tensor
* **Layer Name**: `input`
* **Shape**: `[N, 3, 192, 192]` (Dynamic batch dimension $N \ge 1$)
* **Data Type**: `float32`
* **Color Order & Normalization**: RGB layout, pixel values scaled to $[0.0, 1.0]$ via:
  ```python
  cv2.dnn.blobFromImage(roi_bgr, scalefactor=1.0 / 255.0, size=(192, 192), swapRB=True, crop=False)
  ```

### Output Tensors
* **Landmarks**:
  * **Layer Name**: `landmarks`
  * **Shape**: `[N, 468, 3]` (468 3D points $\times 3 = 1404$ floats per face)
  * **Coordinates**: Expressed directly in 192-crop pixel space $(x \in [0, 192], y \in [0, 192], z)$
* **Score**:
  * **Layer Name**: `score`
  * **Shape**: `[N, 1]` (`float32` face presence logit)

### Raspberry Pi Runtime Compatibility
* **Verified Runtime**: Raspberry Pi 5 running Photobooth-App Python 3.13 venv with OpenCV 4.13 (`cv2.dnn`).
* **Result**: `cv2.dnn.readNetFromONNX("models/face_mesh.onnx")` loads cleanly, executes CPU inference, and matches the output tensor contract without missing operators or custom ops.

---

## 3. Geometric Expression Metric: Mouth Aspect Ratio (MAR)

Normalized inner-lip landmark separation is computed using 8 documented MediaPipe Face Mesh landmark indices:
* **Upper lip inner center**: `13`
* **Lower lip inner center**: `14`
* **Upper lip inner left mid**: `82`
* **Lower lip inner left mid**: `87`
* **Upper lip inner right mid**: `312`
* **Lower lip inner right mid**: `317`
* **Inner left mouth corner**: `78`
* **Inner right mouth corner**: `308`

$$\text{MAR} = \frac{\frac{d(87, 82) + 2 \cdot d(14, 13) + d(317, 312)}{4}}{d(308, 78)}$$

Because MAR is a dimensionless ratio of Euclidean distances within the same ROI crop, no coordinate un-warping or canvas scaling is required to evaluate expression state.

---

## 4. Multi-Face Temporal State Machine & Hysteresis

### Verified Experimental Configuration
* **OPEN threshold**: $\text{MAR} \ge 0.28$
* **CLOSE threshold**: $\text{MAR} \le 0.16$
* **EMA Smoothing ($\alpha$)**: $0.45$
  $$\text{smooth\_mar} = \alpha \cdot \text{raw\_mar} + (1 - \alpha) \cdot \text{smooth\_mar}$$
* **Hysteresis Debounce**: $2$ consecutive frames required before triggering state transition.

### Physical Raspberry Pi Validation Results
During live physical validation on the Raspberry Pi 5:
* Observed clearly **CLOSED** MAR: $\sim 0.01 - 0.10$
* Observed clearly **OPEN** MAR: $\sim 0.30 - 0.60$
* State sequence produced repeated and robust transitions:
  $$\text{CLOSED} \longrightarrow \text{EVENT: mouth\_opened} \longrightarrow \text{OPEN} \longrightarrow \text{EVENT: mouth\_closed} \longrightarrow \text{CLOSED}$$

### Transition-Only Event Emission Rule
* `mouth_opened`: Emitted **strictly once** when a face transitions from `CLOSED` to `OPEN`. Subsequent frames with mouth open remain in `OPEN` state with empty events (`[]`).
* `mouth_closed`: Emitted **strictly once** when a face transitions from `OPEN` to `CLOSED`. Subsequent frames with mouth closed remain in `CLOSED` state with empty events (`[]`).

---

## 5. Raspberry Pi Performance Benchmark

Measured end-to-end processing latency on Raspberry Pi 5 under live MJPEG acquisition:
* **Decode & Downscale**: $17.9\text{ ms}$
* **YuNet Face Detection**: $85.7\text{ ms}$
* **Face ROI Extraction**: $5.0\text{ ms}$
* **FaceMesh ONNX Inference**: $24.1\text{ ms}$
* **MAR & Tracker Calculation**: $0.3\text{ ms}$
* **Total Latency**: $\approx 109 - 133\text{ ms}$ ($\mathbf{7.5 - 9.1\text{ FPS}}$)

> [!NOTE]
> YuNet accounts for $> 65\%$ of overall processing time. FaceMesh inference accounts for only $\sim 18\%$. Optimization is intentionally deferred; current performance is sufficient for live UI feedback.

---

## 6. Architecture & Data Contract

### Module Layout
1. [`scripts/expression_engine.py`](file:///Users/hectorpacheco/Desktop/Projects/photobooth-kiosk-extensions/scripts/expression_engine.py):
   * Pure geometric landmark calculations (`compute_mouth_aspect_ratio`).
   * Multi-face tracking state machine (`MultiFaceExpressionTracker`, `FaceExpressionTrack`).
   * ONNX model loader and validator (`FaceMeshDetector`).
   * High-level coordinator (`ExpressionEngine`).
2. [`scripts/ar_engine.py`](file:///Users/hectorpacheco/Desktop/Projects/photobooth-kiosk-extensions/scripts/ar_engine.py):
   * Passes detected face bounding boxes to `ExpressionEngine`.
   * Augments normalized face dictionaries with expression contract.
3. [`scripts/theme-selector-server.py`](file:///Users/hectorpacheco/Desktop/Projects/photobooth-kiosk-extensions/scripts/theme-selector-server.py):
   * Initializes `ExpressionEngine` on demand.
   * Broadcasts augmented face data over SSE (`/api/ar/stream`).
4. [`ui/kiosk-ar-overlay.js`](file:///Users/hectorpacheco/Desktop/Projects/photobooth-kiosk-extensions/ui/kiosk-ar-overlay.js):
   * Stores `expression` and `expressionEvents` per tracked face.
   * Renders existing baseline AR effects unchanged.

### Per-Face SSE Data Contract
```json
{
  "center_eyes": [0.48512, 0.41203],
  "inter_eye_distance": 0.14205,
  "roll_angle_deg": -1.25,
  "confidence": 0.985,
  "anchors": {
    "eyes_center": [0.48512, 0.41203],
    "nose_anchor": [0.48421, 0.46102],
    "forehead_anchor": [0.48625, 0.30548],
    "mouth_anchor": [0.48398, 0.52840]
  },
  "expression": {
    "mouth_open": true,
    "mouth_ratio": 0.4215
  },
  "expression_events": ["mouth_opened"]
}
```

### Graceful Degradation
If `models/face_mesh.onnx` is missing, unreadable, or OpenCV DNN is unavailable:
* `ExpressionEngine.is_available()` returns `False`.
* `process_stream_frame` falls back seamlessly to the baseline YuNet pipeline.
* `output_faces` are returned without `expression` fields.
* Existing sunglasses, crown, and mustache tracking continue operating with zero disruption.

---

## 7. Known Hardening Debt
* **Track ID Churn**: Centroid-based tracking can experience ID handoffs (`Face 1` $\rightarrow$ `Face 2` $\rightarrow$ `Face 3`) under fast movement or occlusion. In multi-person environments, expression hysteresis state needs more robust temporal association (e.g., IoU + centroid Hungarian matching) to prevent state reset during brief tracking dropouts.

---

## 8. Gate 1 Production Physical Validation (2026-09-22)

Gate 1 (Generic Expression Layer Integration & Production SSE Delivery) was physically validated on the live Raspberry Pi production photo booth on **2026-09-22**.

### Verified Production Behaviors
1. **Live Production SSE Stream**: `/api/ar/stream` emitted live SSE face packets from the real Canon camera stream with `enabled = true` and `active_effect = "glasses"`.
2. **Expression Contract Fields Present**: Production face packets consistently included all required generic expression fields:
   * `expression.mouth_open`
   * `expression.mouth_ratio`
   * `expression_events`
3. **Closed-Mouth Baseline**: Closed-mouth state was reliably observed with stable low MAR values, including sample readings of approximately `0.0353` and `0.0360`.
4. **CLOSED $\rightarrow$ OPEN Transition**: Successfully detected at runtime when opening mouth:
   * `mouth_open = true`
   * `mouth_ratio = 0.5152`
   * `expression_events = ["mouth_opened"]`
5. **One-Shot Open Transition**: While the mouth remained open across subsequent frames:
   * `mouth_open` remained `true`
   * `expression_events` returned `[]`
   * This confirms the transition event fires strictly once at state transition rather than repeatedly each frame.
6. **OPEN $\rightarrow$ CLOSED Transition**: Successfully detected at runtime when closing mouth:
   * `mouth_open = false`
   * `mouth_ratio = 0.0988`
   * `expression_events = ["mouth_closed"]`
7. **One-Shot Close Transition**: While the mouth remained closed across subsequent frames:
   * `mouth_open` remained `false`
   * `expression_events` returned `[]`
   * This confirms the close event is also strictly one-shot.
8. **Repeatability**: A second complete open/close cycle was performed and observed with identical state and event transitions, confirming stability.
9. **Baseline AR Invariance**: Existing production AR remained fully operational throughout the live physical test:
   * `active_effect` remained `"glasses"`
   * `enabled` remained `true`
   * Existing face transform and anchor fields (`center_eyes`, `inter_eye_distance`, `roll_angle_deg`, `anchors`, `bbox_norm`) continued to be emitted without corruption or drift.
10. **Observed Sample Latency**: Production packets showed `total_process_ms` commonly in roughly the $50 - 85\text{ ms}$ range during the inspected transition frames. *(Note: Documented strictly as an observed sample range during testing, NOT as a guaranteed benchmark).*

### Gate 1 Conclusion
**Production expression delivery is VALIDATED.**

The live production pipeline has now been demonstrated end-to-end:
```
Canon Preview (MJPEG)
       ↓
YuNet Face Detection (OpenCV FaceDetectorYN)
       ↓
FaceMesh Dense Landmarks (OpenCV DNN)
       ↓
ExpressionEngine (MAR + EMA + Schmitt Trigger)
       ↓
Normalized Expression State & Events Contract
       ↓
/api/ar/stream (Server-Sent Events)
       ↓
Browser AR Consumer (kiosk-ar-overlay.js)
```

### Architectural & Product Requirements Going Forward
* **Generic Contract Consumption**: All future reactive visual effects must consume only the generic expression contract (`expression.mouth_open`, `expression.mouth_ratio`, `expression_events`) and **must not** depend directly on YuNet or FaceMesh implementation details.
* **Separation of Effects**: Static Glasses remains a completely independent, non-reactive AR effect. **Do NOT attach tongue behavior or expression reactions to Glasses.**
* **Dedicated Effect Selection**: The next reactive visual effect (e.g. dog ears/tongue) will be implemented as its own distinct, selectable effect within `AR_EFFECT_CONFIGS` utilizing the established generic expression/event contract.
