#!/usr/bin/env python3
"""
tests/test_expression_engine.py - Unit tests for generic facial expression detection & state machine.

Tests pure logic independently of OpenCV camera streams or GPU/hardware backends:
1. Normalized MAR calculation accuracy for open and closed mouth landmark geometry.
2. Degenerate mouth geometry handling (zero width, division-by-zero protection).
3. Exponential Moving Average (EMA) temporal smoothing formula.
4. Dual-threshold Schmitt trigger hysteresis:
   - CLOSED -> OPEN transition fires strictly on threshold crossing after debounce frames.
   - OPEN state does not repeatedly fire 'mouth_opened' on subsequent frames.
   - OPEN -> CLOSED transition fires strictly on threshold crossing after debounce frames.
   - CLOSED state does not repeatedly fire 'mouth_closed' on subsequent frames.
5. Independent multi-face tracking and expression states.
6. Graceful degradation when FaceMesh model or OpenCV is unavailable.
"""

from pathlib import Path
import sys
import unittest

import numpy as np

# Ensure scripts directory is on sys.path
SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from expression_engine import (
    compute_mouth_aspect_ratio,
    FaceExpressionTrack,
    MultiFaceExpressionTracker,
    FaceMeshDetector,
    ExpressionEngine,
    INDEX_LIP_UPPER_CENTER,
    INDEX_LIP_LOWER_CENTER,
    INDEX_LIP_UPPER_LEFT_MID,
    INDEX_LIP_LOWER_LEFT_MID,
    INDEX_LIP_UPPER_RIGHT_MID,
    INDEX_LIP_LOWER_RIGHT_MID,
    INDEX_MOUTH_CORNER_LEFT,
    INDEX_MOUTH_CORNER_RIGHT,
)


def create_synthetic_landmarks(
    mouth_width: float = 60.0,
    vertical_opening: float = 2.0,
    center_x: float = 96.0,
    center_y: float = 120.0,
) -> np.ndarray:
    """Generate synthetic 468x3 landmark array with parameterized mouth geometry."""
    landmarks = np.zeros((468, 3), dtype=np.float32)

    half_w = mouth_width / 2.0
    half_h = vertical_opening / 2.0

    # Horizontal mouth corners
    landmarks[INDEX_MOUTH_CORNER_LEFT] = [center_x - half_w, center_y, 0.0]
    landmarks[INDEX_MOUTH_CORNER_RIGHT] = [center_x + half_w, center_y, 0.0]

    # Center inner lips
    landmarks[INDEX_LIP_UPPER_CENTER] = [center_x, center_y - half_h, 0.0]
    landmarks[INDEX_LIP_LOWER_CENTER] = [center_x, center_y + half_h, 0.0]

    # Left mid inner lips
    landmarks[INDEX_LIP_UPPER_LEFT_MID] = [center_x - half_w * 0.5, center_y - half_h * 0.8, 0.0]
    landmarks[INDEX_LIP_LOWER_LEFT_MID] = [center_x - half_w * 0.5, center_y + half_h * 0.8, 0.0]

    # Right mid inner lips
    landmarks[INDEX_LIP_UPPER_RIGHT_MID] = [center_x + half_w * 0.5, center_y - half_h * 0.8, 0.0]
    landmarks[INDEX_LIP_LOWER_RIGHT_MID] = [center_x + half_w * 0.5, center_y + half_h * 0.8, 0.0]

    return landmarks


class TestExpressionLogic(unittest.TestCase):

    def test_mar_closed_mouth(self):
        """Closed mouth (vertical opening 2.0px, width 60.0px) should yield MAR < 0.10."""
        lmks = create_synthetic_landmarks(mouth_width=60.0, vertical_opening=2.0)
        mar = compute_mouth_aspect_ratio(lmks)
        self.assertGreater(mar, 0.0)
        self.assertLess(mar, 0.10)

    def test_mar_open_mouth(self):
        """Open mouth (vertical opening 30.0px, width 60.0px) should yield MAR ~ 0.45."""
        lmks = create_synthetic_landmarks(mouth_width=60.0, vertical_opening=30.0)
        mar = compute_mouth_aspect_ratio(lmks)
        self.assertGreater(mar, 0.35)
        self.assertLess(mar, 0.55)

    def test_mar_zero_width_safe(self):
        """Degenerate zero-width mouth handles division safely and returns 0.0."""
        lmks = create_synthetic_landmarks(mouth_width=0.0, vertical_opening=10.0)
        mar = compute_mouth_aspect_ratio(lmks)
        self.assertEqual(mar, 0.0)

    def test_ema_smoothing(self):
        """EMA updates according to alpha * raw + (1 - alpha) * smooth."""
        tracker = MultiFaceExpressionTracker(ema_alpha=0.5, open_threshold=0.28, close_threshold=0.16)
        bbox = (100.0, 100.0, 50.0, 50.0)

        # Frame 1: initial observation seeds smooth_mar
        t1 = tracker.update([(bbox, 0.10)], 500, 500, now=1.0)
        self.assertAlmostEqual(t1[0].smooth_mar, 0.10, places=4)

        # Frame 2: raw = 0.20 -> smooth = 0.5 * 0.20 + 0.5 * 0.10 = 0.15
        t2 = tracker.update([(bbox, 0.20)], 500, 500, now=1.1)
        self.assertAlmostEqual(t2[0].smooth_mar, 0.15, places=4)

    def test_closed_to_open_transition_and_no_repeat(self):
        """
        When mouth opens:
        - Debounces until hysteresis_frames reached.
        - Fires 'mouth_opened' exactly once on transition.
        - Subsequent open frames stay in OPEN state with active_event=None.
        """
        tracker = MultiFaceExpressionTracker(
            open_threshold=0.28,
            close_threshold=0.16,
            ema_alpha=1.0,  # Disable EMA smoothing for direct threshold verification
            hysteresis_frames=2,
        )
        bbox = (100.0, 100.0, 50.0, 50.0)

        # Frame 1: Initial closed
        res = tracker.update([(bbox, 0.05)], 500, 500, now=1.0)
        self.assertEqual(res[0].mouth_state, "CLOSED")
        self.assertIsNone(res[0].active_event)

        # Frame 2: First open frame (consecutive_open_frames = 1 < 2) -> still CLOSED, no event
        res = tracker.update([(bbox, 0.40)], 500, 500, now=1.1)
        self.assertEqual(res[0].mouth_state, "CLOSED")
        self.assertIsNone(res[0].active_event)

        # Frame 3: Second open frame (consecutive_open_frames = 2 == 2) -> TRANSITION to OPEN!
        res = tracker.update([(bbox, 0.42)], 500, 500, now=1.2)
        self.assertEqual(res[0].mouth_state, "OPEN")
        self.assertEqual(res[0].active_event, "mouth_opened")
        contract = res[0].to_contract_dict()
        self.assertTrue(contract["expression"]["mouth_open"])
        self.assertEqual(contract["expression_events"], ["mouth_opened"])

        # Frame 4: Mouth remains open -> state is OPEN, but active_event must be None (no duplicate event)
        res = tracker.update([(bbox, 0.45)], 500, 500, now=1.3)
        self.assertEqual(res[0].mouth_state, "OPEN")
        self.assertIsNone(res[0].active_event)
        self.assertEqual(res[0].to_contract_dict()["expression_events"], [])

        # Frame 5: Mouth still open -> still no duplicate event
        res = tracker.update([(bbox, 0.40)], 500, 500, now=1.4)
        self.assertEqual(res[0].mouth_state, "OPEN")
        self.assertIsNone(res[0].active_event)

    def test_open_to_closed_transition_and_no_repeat(self):
        """
        When mouth closes:
        - Debounces until hysteresis_frames reached.
        - Fires 'mouth_closed' exactly once on transition.
        - Subsequent closed frames stay in CLOSED state with active_event=None.
        """
        tracker = MultiFaceExpressionTracker(
            open_threshold=0.28,
            close_threshold=0.16,
            ema_alpha=1.0,
            hysteresis_frames=2,
        )
        bbox = (100.0, 100.0, 50.0, 50.0)

        # Start by putting face in OPEN state
        tracker.update([(bbox, 0.40)], 500, 500, now=1.0)
        res = tracker.update([(bbox, 0.40)], 500, 500, now=1.1)
        self.assertEqual(res[0].mouth_state, "OPEN")

        # Frame 1 closing: MAR drops to 0.05 (consecutive_close_frames = 1 < 2) -> still OPEN
        res = tracker.update([(bbox, 0.05)], 500, 500, now=1.2)
        self.assertEqual(res[0].mouth_state, "OPEN")
        self.assertIsNone(res[0].active_event)

        # Frame 2 closing: MAR drops to 0.04 (consecutive_close_frames = 2 == 2) -> TRANSITION to CLOSED!
        res = tracker.update([(bbox, 0.04)], 500, 500, now=1.3)
        self.assertEqual(res[0].mouth_state, "CLOSED")
        self.assertEqual(res[0].active_event, "mouth_closed")
        self.assertEqual(res[0].to_contract_dict()["expression_events"], ["mouth_closed"])

        # Frame 3: Mouth remains closed -> stays CLOSED, active_event must be None (no duplicate event)
        res = tracker.update([(bbox, 0.05)], 500, 500, now=1.4)
        self.assertEqual(res[0].mouth_state, "CLOSED")
        self.assertIsNone(res[0].active_event)
        self.assertEqual(res[0].to_contract_dict()["expression_events"], [])

    def test_independent_multi_face_states(self):
        """Face 1 and Face 2 maintain completely independent expression states."""
        tracker = MultiFaceExpressionTracker(
            open_threshold=0.28,
            close_threshold=0.16,
            ema_alpha=1.0,
            hysteresis_frames=2,
        )
        face1_bbox = (50.0, 100.0, 60.0, 60.0)    # Left face
        face2_bbox = (300.0, 100.0, 60.0, 60.0)   # Right face

        # Frame 1: Face 1 is open (0.45), Face 2 is closed (0.05)
        tracker.update([(face1_bbox, 0.45), (face2_bbox, 0.05)], 500, 500, now=1.0)

        # Frame 2: Face 1 completes debounce to OPEN, Face 2 stays CLOSED
        res = tracker.update([(face1_bbox, 0.45), (face2_bbox, 0.05)], 500, 500, now=1.1)
        self.assertEqual(len(res), 2)
        f1, f2 = res[0], res[1]

        self.assertEqual(f1.mouth_state, "OPEN")
        self.assertEqual(f1.active_event, "mouth_opened")

        self.assertEqual(f2.mouth_state, "CLOSED")
        self.assertIsNone(f2.active_event)

    def test_graceful_model_unavailable_behavior(self):
        """When model file is nonexistent, ExpressionEngine is_available() is False and fails safely."""
        engine = ExpressionEngine(model_path=Path("/nonexistent/model.onnx"))
        self.assertFalse(engine.is_available())
        # process_faces returns empty list without raising exceptions
        result = engine.process_faces(
            img_bgr=None,
            face_bboxes=[(10.0, 10.0, 50.0, 50.0)],
            frame_w=500,
            frame_h=500,
        )
        self.assertEqual(result, [])

    def test_contract_json_serializable(self):
        """Contract dictionary must be strictly JSON serializable with standard json module."""
        import json
        track = FaceExpressionTrack(
            face_id=1,
            centroid=(0.5, 0.5),
            bbox=(100.0, 100.0, 50.0, 50.0),
            raw_mar=np.float32(0.4215),
            smooth_mar=np.float64(0.4215),
            mouth_state="OPEN",
            active_event="mouth_opened",
        )
        contract = track.to_contract_dict()
        serialized = json.dumps(contract)
        deserialized = json.loads(serialized)
        self.assertTrue(deserialized["expression"]["mouth_open"])
        self.assertEqual(deserialized["expression"]["mouth_ratio"], 0.4215)
        self.assertEqual(deserialized["expression_events"], ["mouth_opened"])


if __name__ == "__main__":
    unittest.main()
