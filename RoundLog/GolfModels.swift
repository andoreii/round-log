import Foundation

enum GolfDistanceUnit: String, Codable, Sendable {
    case yd, m

    func metres(_ distance: Decimal) -> Decimal {
        self == .yd ? distance * Decimal(string: "0.9144")! : distance
    }
}

enum GolfRecordingMode: String, Codable, Sendable { case zen, standard, detailed }
enum GolfRoundType: String, Codable, Sendable { case casual, competition, tournament, practice }
enum GolfRoundStatus: String, Codable, Sendable { case completed, partial }
enum GolfHoleSelection: Sendable { case frontNine, backNine, eighteen }
enum GolfOutcome: String, Codable, CaseIterable, Sendable {
    case hit, left, right, short, long
    case shortLeft = "short_left", shortRight = "short_right"
    case longLeft = "long_left", longRight = "long_right"
}

struct GolfRating: Codable, Equatable, Sendable {
    var courseRating: Decimal? = nil
    var slopeRating: Int? = nil
    enum CodingKeys: String, CodingKey {
        case courseRating = "course_rating", slopeRating = "slope_rating"
    }
}

struct GolfRatings: Codable, Equatable, Sendable {
    var full: GolfRating? = nil
    var frontNine: GolfRating? = nil
    var backNine: GolfRating? = nil
    enum CodingKeys: String, CodingKey {
        case full, frontNine = "front_nine", backNine = "back_nine"
    }
}

struct GolfCourseHole: Codable, Equatable, Sendable {
    var number: Int
    var par: Int
    var strokeIndex: Int
    enum CodingKeys: String, CodingKey { case number, par, strokeIndex = "stroke_index" }
}

struct GolfTeeDistance: Codable, Equatable, Sendable {
    var number: Int
    var distance: Decimal
}

struct GolfTee: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var distances: [GolfTeeDistance]
    var ratings: GolfRatings? = nil
}

struct GolfCourseDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var name: String
    var location: String? = nil
    var archived = false
    var distanceUnit: GolfDistanceUnit
    var holes: [GolfCourseHole]
    var tees: [GolfTee]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", name, location, archived
        case distanceUnit = "distance_unit", holes, tees
    }
}

struct GolfCourse: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var revision = 1
    var document: GolfCourseDocument

    func validate() throws {
        try golfRequire((1...999_999_999).contains(revision), "invalid_revision")
        try golfRequire(document.schemaVersion == 1, "unsupported_version")
        try golfText(document.name, limit: 200, code: "invalid_course_name")
        try golfText(document.location, limit: 300, code: "invalid_course_location")
        let count = document.holes.count
        try golfRequire(count == 9 || count == 18, "invalid_course_hole_count")
        try golfRequire(Set(document.holes.map(\.number)) == Set(1...count), "invalid_hole_numbers")
        try golfRequire(Set(document.holes.map(\.strokeIndex)).count == count, "duplicate_stroke_index")
        for hole in document.holes {
            try golfRequire((3...6).contains(hole.par), "invalid_par")
            try golfRequire((1...18).contains(hole.strokeIndex), "invalid_stroke_index")
        }
        try golfRequire(!document.tees.isEmpty && Set(document.tees.map(\.id)).count == document.tees.count, "invalid_tee")
        for tee in document.tees {
            try golfText(tee.name, limit: 100, code: "invalid_tee_name")
            try golfRequire(tee.distances.count == count && Set(tee.distances.map(\.number)) == Set(1...count), "invalid_tee_distances")
            for distance in tee.distances {
                try golfRequire(!distance.distance.isNaN && distance.distance > 0, "invalid_hole_distance")
            }
            try tee.ratings?.validate(holeCount: count)
        }
        try golfRequire(GolfCodec.encode(document).count <= 100_000, "course_too_large")
    }
}

struct GolfCourseSnapshot: Codable, Equatable, Sendable {
    var id: UUID
    var holeCount: Int
    var name: String
    var location: String? = nil
    var distanceUnit: GolfDistanceUnit
    enum CodingKeys: String, CodingKey {
        case id, holeCount = "hole_count", name, location, distanceUnit = "distance_unit"
    }
}

struct GolfTeeSnapshot: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var ratings: GolfRatings? = nil
}

struct GolfShot: Codable, Equatable, Sendable {
    var club: String? = nil
    var x: Decimal? = nil
    var y: Decimal? = nil
    var outcome: GolfOutcome? = nil
    var distance: Decimal? = nil
    var distanceUnit: GolfDistanceUnit? = nil
    enum CodingKeys: String, CodingKey { case club, x, y, outcome, distance, distanceUnit = "distance_unit" }

    var hasObservation: Bool {
        club?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || x != nil || y != nil || outcome != nil || distance != nil
    }

    func validate(code: String) throws {
        do { _ = try GolfClub.normalize(club) } catch { throw GolfValidationError(code) }
        try golfRequire((x == nil) == (y == nil), code)
        for coordinate in [x, y].compactMap({ $0 }) {
            try golfRequire(!coordinate.isNaN && coordinate >= 0 && coordinate <= 1, code)
        }
    }

    func validateDistance() throws {
        try golfRequire((distance == nil) == (distanceUnit == nil), "invalid_approach_distance")
        if let distance { try golfRequire(!distance.isNaN && distance >= 0, "invalid_approach_distance") }
    }
}

struct GolfHoleResult: Codable, Equatable, Sendable {
    var number: Int
    var par: Int
    var strokeIndex: Int
    var distance: Decimal
    var strokes: Int? = nil
    var putts: Int? = nil
    var penalties: Int? = nil
    var mode: GolfRecordingMode = .standard
    var teeShot: GolfShot? = nil
    var approachShot: GolfShot? = nil
    enum CodingKeys: String, CodingKey {
        case number, par, strokeIndex = "stroke_index", distance, strokes, putts, penalties, mode
        case teeShot = "tee_shot", approachShot = "approach_shot"
    }

    var effectiveApproach: GolfShot? { par == 3 ? teeShot : approachShot }
}

struct GolfRoundPayload: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var roundID: UUID = UUID()
    var revision = 1
    var playedOn: String
    var createdAt: String
    var roundType: GolfRoundType
    var status: GolfRoundStatus
    var plannedHoles: Int
    var course: GolfCourseSnapshot
    var tee: GolfTeeSnapshot
    var holes: [GolfHoleResult]
    var weather: String? = nil
    var notes: String? = nil
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", roundID = "round_id", revision, playedOn = "played_on"
        case createdAt = "created_at", roundType = "round_type", status, plannedHoles = "planned_holes"
        case course, tee, holes, weather, notes
    }

    static func start(course: GolfCourse, teeID: UUID, selection: GolfHoleSelection, playedOn: String,
                      roundType: GolfRoundType = .casual, mode: GolfRecordingMode = .standard,
                      weather: String? = nil, notes: String? = nil, now: Date = Date()) throws -> Self {
        try course.validate()
        try golfRequire(!course.document.archived, "course_archived")
        guard let tee = course.document.tees.first(where: { $0.id == teeID }) else { throw GolfValidationError("invalid_tee_id") }
        let count = course.document.holes.count
        let numbers: ClosedRange<Int>
        switch selection {
        case .frontNine: numbers = 1...9
        case .backNine:
            try golfRequire(count == 18, "invalid_hole_selection")
            numbers = 10...18
        case .eighteen:
            try golfRequire(count == 18, "invalid_hole_selection")
            numbers = 1...18
        }
        let distances = Dictionary(uniqueKeysWithValues: tee.distances.map { ($0.number, $0.distance) })
        let holes = course.document.holes.filter { numbers.contains($0.number) }.sorted { $0.number < $1.number }.map {
            GolfHoleResult(number: $0.number, par: $0.par, strokeIndex: $0.strokeIndex, distance: distances[$0.number]!, mode: mode)
        }
        let result = Self(playedOn: playedOn, createdAt: GolfCodec.timestamp(now), roundType: roundType, status: .partial,
                          plannedHoles: holes.count,
                          course: GolfCourseSnapshot(id: course.id, holeCount: count, name: course.document.name,
                                                     location: course.document.location, distanceUnit: course.document.distanceUnit),
                          tee: GolfTeeSnapshot(id: tee.id, name: tee.name, ratings: tee.ratings), holes: holes, weather: weather, notes: notes)
        try result.validateDraft()
        return result
    }

    var selectedRating: GolfRating? {
        if plannedHoles == course.holeCount { return tee.ratings?.full }
        return holes.contains(where: { $0.number == 1 }) ? tee.ratings?.frontNine : tee.ratings?.backNine
    }

    func validateDraft() throws { try validate(requirePlayed: false) }
    func validateForSubmission() throws {
        try validate(requirePlayed: true)
        try golfRequire(GolfCodec.encode(self).count <= 65_536, "payload_too_large")
    }

    private func validate(requirePlayed: Bool) throws {
        try golfRequire(schemaVersion == 1, "unsupported_version")
        try golfRequire((1...999_999_999).contains(revision), "invalid_revision")
        try golfRequire(GolfCodec.isDate(playedOn), "invalid_date")
        try golfRequire(GolfCodec.date(createdAt) != nil, "invalid_created_at")
        try golfRequire([9, 18].contains(plannedHoles), "invalid_hole_count")
        try golfRequire([9, 18].contains(course.holeCount) && plannedHoles <= course.holeCount, "invalid_course_hole_count")
        try golfText(course.name, limit: 200, code: "invalid_course_name")
        try golfText(course.location, limit: 300, code: "invalid_course_location")
        try golfText(tee.name, limit: 100, code: "invalid_tee_name")
        try golfText(weather, limit: 500, code: "invalid_weather")
        try golfText(notes, limit: 4_000, code: "invalid_notes")
        try tee.ratings?.validate(holeCount: course.holeCount)
        try golfRequire(holes.count == plannedHoles, "invalid_hole_count")
        let numbers = Set(holes.map(\.number))
        let allowed = plannedHoles == 18 ? [Set(1...18)] : course.holeCount == 9 ? [Set(1...9)] : [Set(1...9), Set(10...18)]
        try golfRequire(allowed.contains(numbers), "invalid_hole_numbers")
        try golfRequire(Set(holes.map(\.strokeIndex)).count == plannedHoles, "duplicate_stroke_index")
        for hole in holes {
            try golfRequire((3...6).contains(hole.par), "invalid_par")
            try golfRequire((1...18).contains(hole.strokeIndex), "invalid_stroke_index")
            try golfRequire(!hole.distance.isNaN && hole.distance > 0, "invalid_hole_distance")
            if let strokes = hole.strokes { try golfRequire((1...2_147_483_647).contains(strokes), "invalid_strokes") }
            if let putts = hole.putts { try golfRequire((0...2_147_483_647).contains(putts), "invalid_putts") }
            if let penalties = hole.penalties { try golfRequire((0...2_147_483_647).contains(penalties), "invalid_penalties") }
            if let strokes = hole.strokes {
                try golfRequire((hole.putts ?? 0) + (hole.penalties ?? 0) <= strokes, "inconsistent_strokes")
            }
            try golfRequire(hole.par != 3 || hole.approachShot == nil, "duplicate_par_three_shot")
            try hole.teeShot?.validate(code: "invalid_tee_shot")
            try hole.approachShot?.validate(code: "invalid_approach_shot")
            try hole.effectiveApproach?.validateDistance()
            if hole.strokes == nil {
                try golfRequire(hole.putts == nil && hole.penalties == nil && hole.teeShot?.hasObservation != true
                                && hole.approachShot?.hasObservation != true, "unplayed_hole_has_stats")
            }
        }
        if requirePlayed {
            let scored = holes.filter { $0.strokes != nil }.count
            try golfRequire(scored > 0, "empty_round")
            try golfRequire(status != .completed || scored == plannedHoles, "incomplete_round")
        }
    }
}

struct GolfValidationError: Error, Equatable, LocalizedError {
    let code: String
    init(_ code: String) { self.code = code }
    var errorDescription: String? { code }
}

enum GolfClub {
    static let all = ["driver"] + (2...9).map { "\($0)w" } + (1...9).map { "\($0)h" } + (1...9).map { "\($0)i" } + ["pw", "gw", "sw", "lw", "putter"]

    static func normalize(_ value: String?) throws -> String? {
        guard let value else { return nil }
        try golfRequire(value.unicodeScalars.count <= 100, "invalid_club")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let label = trimmed.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
        let aliases = ["d": "driver", "1w": "driver", "1wood": "driver", "driver": "driver",
                       "p": "pw", "pw": "pw", "pitchingwedge": "pw", "a": "gw", "aw": "gw", "gw": "gw",
                       "approachwedge": "gw", "attackwedge": "gw", "gapwedge": "gw", "sw": "sw", "sandwedge": "sw",
                       "lw": "lw", "lobwedge": "lw", "pt": "putter", "putter": "putter"]
        if let club = aliases[label] { return club }
        guard let digit = label.first, ("1"..."9").contains(String(digit)) else { throw GolfValidationError("invalid_club") }
        let suffix = String(label.dropFirst())
        guard ["w", "wood", "h", "hybrid", "i", "iron"].contains(suffix), let first = suffix.first else { throw GolfValidationError("invalid_club") }
        return String(digit) + String(first)
    }
}

enum GolfCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func date(_ value: String) -> Date? {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,6})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])$"#, options: .regularExpression) != nil,
              isDate(String(value.prefix(10))) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func isDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return value.count == 10 && formatter.string(from: date) == value
    }
}

private struct GolfJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension GolfRating {
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: GolfJSONKey.self).allKeys.map(\.stringValue)
        try golfRequire(Set(keys).isSubset(of: ["course_rating", "slope_rating"]), "invalid_ratings")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        courseRating = try container.decodeIfPresent(Decimal.self, forKey: .courseRating)
        slopeRating = try container.decodeIfPresent(Int.self, forKey: .slopeRating)
    }
}

extension GolfRatings {
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: GolfJSONKey.self).allKeys.map(\.stringValue)
        try golfRequire(Set(keys).isSubset(of: ["full", "front_nine", "back_nine"]), "invalid_ratings")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Keep an explicit null scope present so a nine-hole course rejects front/back ratings.
        func pair(_ key: CodingKeys) throws -> GolfRating? {
            container.contains(key) ? try container.decodeIfPresent(GolfRating.self, forKey: key) ?? GolfRating() : nil
        }
        full = try pair(.full)
        frontNine = try pair(.frontNine)
        backNine = try pair(.backNine)
    }
}

private extension GolfRatings {
    func validate(holeCount: Int) throws {
        try golfRequire(holeCount == 18 || (frontNine == nil && backNine == nil), "invalid_ratings")
        for rating in [full, frontNine, backNine].compactMap({ $0 }) {
            if var number = rating.courseRating {
                try golfRequire(!number.isNaN && number > 0, "invalid_course_rating")
                var rounded = Decimal()
                NSDecimalRound(&rounded, &number, 1, .plain)
                try golfRequire(rounded == number, "invalid_course_rating")
            }
            if let slope = rating.slopeRating { try golfRequire((55...155).contains(slope), "invalid_slope_rating") }
        }
    }
}

private func golfRequire(_ condition: Bool, _ code: String) throws {
    guard condition else { throw GolfValidationError(code) }
}

private func golfText(_ value: String, limit: Int, code: String) throws {
    try golfRequire(value.unicodeScalars.count <= limit && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, code)
}

private func golfText(_ value: String?, limit: Int, code: String) throws {
    if let value { try golfRequire(value.unicodeScalars.count <= limit, code) }
}
