import copy
import json
from decimal import Decimal
from pathlib import Path
import unittest

from pipeline.transform import ValidationError, transform

FIXTURE = json.loads((Path(__file__).parent / "fixtures/nine_holes.json").read_text())


class TransformTests(unittest.TestCase):
    def setUp(self):
        self.payload = copy.deepcopy(FIXTURE)

    def assert_invalid(self, code):
        with self.assertRaises(ValidationError) as error:
            transform(self.payload)
        self.assertEqual(error.exception.code, code)

    def test_units_and_scores(self):
        round_values, holes = transform(self.payload)
        self.assertEqual(round_values["course_name"], "Sample Links")
        self.assertEqual(round_values["created_at"].isoformat(), "2026-11-01T01:00:00+00:00")
        self.assertEqual(holes[0]["distance_m"], Decimal("365.7600"))
        self.assertEqual(holes[6]["approach_distance_m"], Decimal("100"))
        self.assertEqual(sum(h["strokes"] for h in holes), 41)
        self.assertEqual(sum(h["strokes"] - h["par"] for h in holes), 5)

    def test_zero_and_unknown_are_distinct(self):
        _, holes = transform(self.payload)
        self.assertEqual(holes[6]["putts"], 0)
        self.assertEqual(holes[6]["penalties"], 0)
        self.assertIsNone(holes[2]["putts"])
        self.assertIsNone(holes[2]["penalties"])
        self.assertIsNone(holes[2]["approach_outcome"])
        self.assertIsNone(holes[5]["approach_distance_m"])

    def test_par_three_shares_tee_shot(self):
        _, holes = transform(self.payload)
        self.assertEqual(holes[1]["approach_club"], "8 iron")
        self.assertEqual(holes[1]["approach_outcome"], "hit")
        self.assertEqual(holes[1]["approach_distance_m"], Decimal("138.0744"))
        self.payload["holes"][1]["approach_shot"] = {"outcome": "hit"}
        self.assert_invalid("duplicate_par_three_shot")

    def test_penalties_already_count_toward_strokes(self):
        self.payload["holes"][0].update(strokes=3, putts=2, penalties=2)
        self.assert_invalid("inconsistent_strokes")

    def test_partial_round_preserves_unplayed_holes(self):
        self.payload["status"] = "partial"
        self.payload["holes"][8]["strokes"] = None
        _, holes = transform(self.payload)
        self.assertIsNone(holes[8]["strokes"])
        self.payload["status"] = "completed"
        self.assert_invalid("incomplete_round")
        self.payload["status"] = "partial"
        self.payload["holes"][8]["putts"] = 0
        self.assert_invalid("unplayed_hole_has_stats")

    def test_holes_must_match_front_or_back_nine(self):
        self.payload["holes"][8]["number"] = 8
        self.assert_invalid("invalid_hole_numbers")
        self.payload = copy.deepcopy(FIXTURE)
        for hole in self.payload["holes"]:
            hole["number"] += 9
        self.assertEqual(transform(self.payload)[1][0]["number"], 10)

    def test_coordinates_and_untrusted_types(self):
        for coordinate in (True, float("nan"), float("inf"), -0.1, 1.1):
            with self.subTest(coordinate=coordinate):
                self.payload["holes"][0]["tee_shot"]["x"] = coordinate
                self.assert_invalid("invalid_tee_shot")
        self.payload = copy.deepcopy(FIXTURE)
        self.payload["holes"][0]["tee_shot"]["outcome"] = {}
        self.assert_invalid("invalid_tee_shot")
        self.payload = copy.deepcopy(FIXTURE)
        self.payload["holes"][0]["strokes"] = True
        self.assert_invalid("invalid_strokes")

    def test_empty_round_and_bad_date(self):
        self.payload["created_at"] = "2026-11-01T01:00:00"
        self.assert_invalid("invalid_created_at")
        self.payload = copy.deepcopy(FIXTURE)
        self.payload["played_on"] = "2026-02-30"
        self.assert_invalid("invalid_date")
        self.payload = copy.deepcopy(FIXTURE)
        self.payload["status"] = "partial"
        for hole in self.payload["holes"]:
            hole.update(strokes=None, putts=None, penalties=None, tee_shot=None, approach_shot=None)
        self.assert_invalid("empty_round")


if __name__ == "__main__":
    unittest.main()
