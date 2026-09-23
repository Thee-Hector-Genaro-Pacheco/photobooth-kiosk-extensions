#!/usr/bin/env python3
"""
tests/test_ar_engine.py - Unit tests for AR engine geometry transforms and Playful Pup configuration.
"""

import math
from pathlib import Path
import sys
import unittest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from ar_engine import (
    FaceLandmarks,
    FaceTransform,
    compute_face_transform,
    AR_EFFECT_CONFIGS,
)


class TestAREngineGeometry(unittest.TestCase):
    def test_compute_face_transform_mouth_width(self):
        # Create a synthetic face: eyes at (80, 100) and (120, 100) -> inter_eye_dist = 40
        # Mouth at (85, 150) and (115, 150) -> mouth_width = 30
        face = FaceLandmarks(
            bbox=(60.0, 70.0, 80.0, 100.0),
            right_eye=(80.0, 100.0),
            left_eye=(120.0, 100.0),
            nose=(100.0, 125.0),
            right_mouth=(85.0, 150.0),
            left_mouth=(115.0, 150.0),
            confidence=0.95,
        )

        tr = compute_face_transform(face, img_w=200, img_h=200)

        self.assertAlmostEqual(tr.inter_eye_distance, 40.0, places=3)
        self.assertAlmostEqual(tr.mouth_width, 30.0, places=3)
        self.assertEqual(tr.mouth_anchor, (100.0, 150.0))

        # Check normalized dict
        norm_dict = tr.to_normalized_dict(img_w=200, img_h=200)
        self.assertIn("mouth_width", norm_dict)
        self.assertAlmostEqual(norm_dict["mouth_width"], 30.0 / 200.0, places=4)
        self.assertAlmostEqual(norm_dict["inter_eye_distance"], 40.0 / 200.0, places=4)

    def test_playful_pup_layering_and_config(self):
        self.assertIn("playful_pup", AR_EFFECT_CONFIGS)
        pup = AR_EFFECT_CONFIGS["playful_pup"]
        elements = pup["elements"]
        self.assertEqual(len(elements), 3)

        # 1. Effective paint order: ears -> tongue -> muzzle (muzzle occludes tongue root)
        self.assertIn("dog-ears.png", elements[0]["asset"])
        self.assertIn("dog-tongue.png", elements[1]["asset"])
        self.assertIn("dog-muzzle.png", elements[2]["asset"])

        # 2. Ears and muzzle have NO visible_when (static)
        self.assertNotIn("visible_when", elements[0])
        self.assertNotIn("visible_when", elements[2])

        # 3. Tongue has visible_when and reactive_height
        tongue = elements[1]
        self.assertIn("visible_when", tongue)
        self.assertEqual(tongue["visible_when"]["expression"], "mouth_open")
        self.assertEqual(tongue["visible_when"]["equals"], True)

        # 4. Tongue uses mouth_width scale_reference
        self.assertEqual(tongue.get("scale_reference"), "mouth_width")

        # 5. Reactive height configuration
        self.assertIn("reactive_height", tongue)
        rh = tongue["reactive_height"]
        self.assertEqual(rh["expression"], "mouth_ratio")
        self.assertGreater(rh["input_max"], rh["input_min"])
        self.assertGreater(rh["max_scale"], rh["min_scale"])

    def test_baseline_effects_untouched(self):
        # Verify glasses, crown, mustache exist with expected anchors
        self.assertIn("glasses", AR_EFFECT_CONFIGS)
        self.assertEqual(AR_EFFECT_CONFIGS["glasses"]["elements"][0]["anchor"], "eyes_center")

        self.assertIn("crown", AR_EFFECT_CONFIGS)
        self.assertEqual(AR_EFFECT_CONFIGS["crown"]["elements"][0]["anchor"], "forehead_anchor")

        self.assertIn("mustache", AR_EFFECT_CONFIGS)
        self.assertEqual(AR_EFFECT_CONFIGS["mustache"]["elements"][0]["anchor"], "nose_anchor")


if __name__ == "__main__":
    unittest.main()
