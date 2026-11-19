"""Validate submitted rounds and produce typed database values."""

from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
import re
from uuid import UUID

TRANSFORM_VERSION = 2
OUTCOMES = {"hit", "left", "right", "short", "long", "short_left", "short_right", "long_left", "long_right"}
CLUB_ALIASES = {
    "d": "driver", "1w": "driver", "1wood": "driver", "driver": "driver",
    "p": "pw", "pw": "pw", "pitchingwedge": "pw",
    "a": "gw", "aw": "gw", "gw": "gw", "approachwedge": "gw", "attackwedge": "gw", "gapwedge": "gw",
    "sw": "sw", "sandwedge": "sw", "lw": "lw", "lobwedge": "lw",
    "pt": "putter", "putter": "putter",
}


class ValidationError(ValueError):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(condition, code):
    if not condition:
        raise ValidationError(code)


def integer(value, code, minimum=0, maximum=2147483647, nullable=False):
    if value is None and nullable:
        return None
    require(type(value) is int and minimum <= value <= maximum, code)
    return value


def number(value, code, minimum=0, maximum=None, nullable=False):
    if value is None and nullable:
        return None
    require(type(value) in (int, float, Decimal), code)
    try:
        result = Decimal(str(value))
    except InvalidOperation:
        raise ValidationError(code) from None
    require(result.is_finite() and result >= minimum, code)
    require(maximum is None or result <= maximum, code)
    return result


def text(value, code, limit, nullable=False):
    if value is None and nullable:
        return None
    require(isinstance(value, str) and len(value) <= limit, code)
    value = value.strip()
    require(nullable or bool(value), code)
    return value or None


def identifier(value, code):
    require(isinstance(value, str), code)
    try:
        return str(UUID(value))
    except ValueError:
        raise ValidationError(code) from None


def metres(value, unit, code, nullable=False):
    value = number(value, code, nullable=nullable)
    if value is None:
        require(unit is None, code)
        return None
    require(unit in ("yd", "m"), code)
    return value * Decimal("0.9144") if unit == "yd" else value


def club(value, code):
    value = text(value, code, 100, nullable=True)
    if value is None:
        return None
    label = re.sub(r"[\s_-]+", "", value.lower())
    if label in CLUB_ALIASES:
        return CLUB_ALIASES[label]
    match = re.fullmatch(r"([1-9])(w|wood|h|hybrid|i|iron)", label)
    require(match is not None, code)
    return match[1] + match[2][0]


def shot(value, code):
    if value is None:
        return {"club": None, "x": None, "y": None, "outcome": None}
    require(isinstance(value, dict), code)
    outcome = value.get("outcome")
    require(outcome is None or (isinstance(outcome, str) and outcome in OUTCOMES), code)
    x = number(value.get("x"), code, maximum=1, nullable=True)
    y = number(value.get("y"), code, maximum=1, nullable=True)
    require((x is None) == (y is None), code)
    return {
        "club": club(value.get("club"), code),
        "x": x,
        "y": y,
        "outcome": outcome,
    }


def ratings(value, hole_count):
    if value is None:
        return {}
    require(isinstance(value, dict), "invalid_ratings")
    scopes = {"full"} if hole_count == 9 else {"full", "front_nine", "back_nine"}
    require(set(value) <= scopes, "invalid_ratings")
    clean = {}
    for scope, pair in value.items():
        if pair is None:
            pair = {}
        require(isinstance(pair, dict) and set(pair) <= {"course_rating", "slope_rating"}, "invalid_ratings")
        course_rating = number(pair.get("course_rating"), "invalid_course_rating", nullable=True)
        if course_rating is not None:
            digits, exponent = course_rating.as_tuple()[1:]
            require(course_rating > 0 and (exponent >= -1 or not any(digits[exponent + 1:])), "invalid_course_rating")
        clean[scope] = {
            "course_rating": course_rating,
            "slope_rating": integer(pair.get("slope_rating"), "invalid_slope_rating", 55, 155, nullable=True),
        }
    return clean


def transform(payload):
    require(isinstance(payload, dict), "invalid_payload")
    require(type(payload.get("schema_version")) is int and payload["schema_version"] == 1, "unsupported_version")
    round_id = identifier(payload.get("round_id"), "invalid_round_id")
    revision = integer(payload.get("revision"), "invalid_revision", 1, 999999999)
    played_on = payload.get("played_on")
    try:
        require(isinstance(played_on, str) and date.fromisoformat(played_on).isoformat() == played_on, "invalid_date")
    except ValueError:
        raise ValidationError("invalid_date") from None
    created_at = payload.get("created_at")
    require(isinstance(created_at, str) and re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})",
        created_at), "invalid_created_at")
    try:
        timestamp_format = "%Y-%m-%dT%H:%M:%S.%f%z" if "." in created_at else "%Y-%m-%dT%H:%M:%S%z"
        created_at = datetime.strptime(created_at, timestamp_format)
        require(created_at.tzinfo is not None and created_at.utcoffset() is not None, "invalid_created_at")
        created_at = created_at.astimezone(timezone.utc)
    except (ValueError, OverflowError):
        raise ValidationError("invalid_created_at") from None
    round_type = payload.get("round_type")
    require(round_type in ("casual", "competition", "tournament", "practice"), "invalid_round_type")
    status = payload.get("status")
    require(status in ("completed", "partial"), "invalid_round_status")
    planned = integer(payload.get("planned_holes"), "invalid_hole_count", 9, 18)
    require(planned in (9, 18), "invalid_hole_count")
    course, tee = payload.get("course"), payload.get("tee")
    require(isinstance(course, dict) and isinstance(tee, dict), "invalid_course")
    hole_count = integer(course.get("hole_count"), "invalid_course_hole_count", 9, 18)
    require(hole_count in (9, 18) and planned <= hole_count, "invalid_course_hole_count")
    tee_ratings = ratings(tee.get("ratings"), hole_count)
    unit = course.get("distance_unit")
    require(unit in ("yd", "m"), "invalid_distance_unit")
    result = {
        "id": round_id, "revision": revision, "transform_version": TRANSFORM_VERSION,
        "played_on": played_on, "created_at": created_at, "round_type": round_type, "status": status, "planned_holes": planned,
        "course_id": identifier(course.get("id"), "invalid_course_id"),
        "course_name": text(course.get("name"), "invalid_course_name", 200),
        "course_location": text(course.get("location"), "invalid_course_location", 300, nullable=True),
        "distance_unit": unit, "tee_id": identifier(tee.get("id"), "invalid_tee_id"),
        "tee_name": text(tee.get("name"), "invalid_tee_name", 100),
        "weather": text(payload.get("weather"), "invalid_weather", 500, nullable=True),
        "notes": text(payload.get("notes"), "invalid_notes", 4000, nullable=True),
    }
    holes = payload.get("holes")
    require(isinstance(holes, list) and len(holes) == planned, "invalid_hole_count")
    clean_holes = []
    for hole in holes:
        require(isinstance(hole, dict), "invalid_hole")
        par = integer(hole.get("par"), "invalid_par", 3, 6)
        strokes = integer(hole.get("strokes"), "invalid_strokes", 1, nullable=True)
        putts = integer(hole.get("putts"), "invalid_putts", nullable=True)
        penalties = integer(hole.get("penalties"), "invalid_penalties", nullable=True)
        require(strokes is None or (putts or 0) + (penalties or 0) <= strokes, "inconsistent_strokes")
        mode = hole.get("mode")
        require(mode in ("zen", "standard", "detailed"), "invalid_mode")
        tee_shot = shot(hole.get("tee_shot"), "invalid_tee_shot")
        require(par != 3 or hole.get("approach_shot") is None, "duplicate_par_three_shot")
        approach = tee_shot.copy() if par == 3 else shot(hole.get("approach_shot"), "invalid_approach_shot")
        hole_distance = metres(hole.get("distance"), unit, "invalid_hole_distance")
        require(hole_distance > 0, "invalid_hole_distance")
        approach_source = (hole.get("tee_shot") if par == 3 else hole.get("approach_shot")) or {}
        approach_distance = metres(approach_source.get("distance"), approach_source.get("distance_unit"),
                                   "invalid_approach_distance", nullable=True)
        if strokes is None:
            require(putts is None and penalties is None and not any(v is not None for v in tee_shot.values())
                    and not any(v is not None for v in approach.values()) and approach_distance is None, "unplayed_hole_has_stats")
        clean = {
            "number": integer(hole.get("number"), "invalid_hole_number", 1, 18),
            "par": par, "stroke_index": integer(hole.get("stroke_index"), "invalid_stroke_index", 1, 18),
            "distance_m": hole_distance, "strokes": strokes, "putts": putts, "penalties": penalties, "mode": mode,
            "approach_distance_m": approach_distance,
        }
        clean.update({"tee_" + key: value for key, value in tee_shot.items()})
        clean.update({"approach_" + key: value for key, value in approach.items()})
        clean_holes.append(clean)
    numbers = {hole["number"] for hole in clean_holes}
    expected = [set(range(1, 10)), set(range(10, 19))] if planned == 9 else [set(range(1, 19))]
    require(numbers in expected, "invalid_hole_numbers")
    require(hole_count != 9 or numbers == set(range(1, 10)), "invalid_hole_numbers")
    rating_scope = "full" if planned == hole_count else ("front_nine" if 1 in numbers else "back_nine")
    result.update(tee_ratings.get(rating_scope, {"course_rating": None, "slope_rating": None}))
    require(len({hole["stroke_index"] for hole in clean_holes}) == planned, "duplicate_stroke_index")
    scored = sum(hole["strokes"] is not None for hole in clean_holes)
    require(scored > 0, "empty_round")
    require(status != "completed" or scored == planned, "incomplete_round")
    return result, sorted(clean_holes, key=lambda hole: hole["number"])
