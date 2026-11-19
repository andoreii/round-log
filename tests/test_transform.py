import copy
import json
from decimal import Decimal
from pathlib import Path
import unittest

from pipeline.transform import ValidationError, transform

FIXTURE = json.loads((Path(__file__).parent / "fixtures/nine_holes.json").read_text())
COURSE_EIGHTEEN = json.loads((Path(__file__).parent / "fixtures/course_eighteen_holes.json").read_text())


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
        self.assertEqual(round_values["transform_version"], 2)
        self.assertEqual(round_values["tee_id"], FIXTURE["tee"]["id"])
        self.assertEqual(round_values["course_rating"], Decimal("35.9"))
        self.assertEqual(round_values["slope_rating"], 125)
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
        self.assertEqual(holes[1]["approach_club"], "8i")
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
        self.payload["course"]["hole_count"] = 18
        for hole in self.payload["holes"]:
            hole["number"] += 9
        self.assertEqual(transform(self.payload)[1][0]["number"], 10)

    def test_ratings_match_selected_holes_without_full_rating_fallback(self):
        self.payload["course"]["hole_count"] = 18
        self.payload["tee"]["ratings"] = copy.deepcopy(COURSE_EIGHTEEN["tees"][0]["ratings"])
        self.assertEqual(transform(self.payload)[0]["course_rating"], Decimal("35.8"))
        for hole in self.payload["holes"]:
            hole["number"] += 9
        self.assertEqual(transform(self.payload)[0]["course_rating"], Decimal("36.3"))
        del self.payload["tee"]["ratings"]["back_nine"]
        self.assertIsNone(transform(self.payload)[0]["course_rating"])
        front = copy.deepcopy(FIXTURE["holes"])
        self.payload["holes"] = front + [dict(h, stroke_index=h["stroke_index"] + 9) for h in self.payload["holes"]]
        self.payload["planned_holes"] = 18
        values, holes = transform(self.payload)
        self.assertEqual(values["course_rating"], Decimal("72.1"))
        self.assertEqual(values["slope_rating"], 128)
        self.assertEqual(len(holes), 18)

    def test_rating_validation_includes_unused_scopes(self):
        self.payload["tee"]["ratings"]["front_nine"] = None
        self.assert_invalid("invalid_ratings")
        self.payload["course"]["hole_count"] = 18
        for pair, code in (({"course_rating": 0}, "invalid_course_rating"),
                           ({"course_rating": 35.91}, "invalid_course_rating"),
                           ({"course_rating": "35.9"}, "invalid_course_rating"),
                           ({"slope_rating": True}, "invalid_slope_rating"),
                           ({"slope_rating": 54}, "invalid_slope_rating")):
            with self.subTest(pair=pair):
                self.payload["tee"]["ratings"]["back_nine"] = pair
                self.assert_invalid(code)
        self.payload["tee"]["ratings"] = {"front_nine": {"slope_rating": 155}}
        values, _ = transform(self.payload)
        self.assertIsNone(values["course_rating"])
        self.assertEqual(values["slope_rating"], 155)
        self.payload["tee"]["ratings"] = {"front_nine": None}
        self.assertIsNone(transform(self.payload)[0]["slope_rating"])

    def test_course_hole_count_and_tee_identity_are_required(self):
        self.payload["tee"]["id"] = None
        self.assert_invalid("invalid_tee_id")
        self.payload = copy.deepcopy(FIXTURE)
        del self.payload["course"]["hole_count"]
        self.assert_invalid("invalid_course_hole_count")
        self.payload = copy.deepcopy(FIXTURE)
        for hole in self.payload["holes"]:
            hole["number"] += 9
        self.assert_invalid("invalid_hole_numbers")

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

    def test_coordinate_pairs_and_outcome_without_coordinates(self):
        shot = self.payload["holes"][0]["tee_shot"]
        shot["x"] = None
        self.assert_invalid("invalid_tee_shot")
        shot["x"], shot["y"] = 0.5, None
        self.assert_invalid("invalid_tee_shot")
        shot["x"] = None
        _, holes = transform(self.payload)
        self.assertEqual(holes[0]["tee_outcome"], "hit")
        self.assertIsNone(holes[0]["tee_x"])
        self.assertIsNone(holes[0]["tee_y"])

    def test_club_aliases_are_canonical_and_unknown_labels_rejected(self):
        for original, expected in (("Driver", "driver"), (" 3-wood ", "3w"), ("5 Hybrid", "5h"),
                                   ("8 iron", "8i"), ("PW", "pw"), ("Gap wedge", "gw")):
            with self.subTest(original=original):
                self.payload["holes"][0]["tee_shot"]["club"] = original
                self.assertEqual(transform(self.payload)[1][0]["tee_club"], expected)
        self.payload["holes"][0]["tee_shot"]["club"] = "unknown club"
        self.assert_invalid("invalid_tee_shot")

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

    def test_creation_timestamp_precision_and_shape(self):
        for invalid in ("2026-11-01T01:00Z", "2026-11-01T01:00:00.1234567Z",
                        "2026-11-01 01:00:00Z", "0001-01-01T00:00:00+01:00"):
            with self.subTest(invalid=invalid):
                self.payload["created_at"] = invalid
                self.assert_invalid("invalid_created_at")
        self.payload["created_at"] = "2026-11-01T10:00:00.123456+09:00"
        self.assertEqual(transform(self.payload)[0]["created_at"].isoformat(), "2026-11-01T01:00:00.123456+00:00")
        self.payload["created_at"] = "2026-11-01T01:00:00.1Z"
        self.assertEqual(transform(self.payload)[0]["created_at"].microsecond, 100000)


if __name__ == "__main__":
    unittest.main()
