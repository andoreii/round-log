import XCTest
@testable import RoundLog

final class GolfModelTests: XCTestCase {
    private func fixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "fixtures"))
        return try GolfCodec.decode(type, from: Data(contentsOf: url))
    }

    func testWireFixturePreservesUnknownsAndSharedParThreeMetrics() throws {
        let round = try fixture(GolfRoundPayload.self, "nine_holes")
        try round.validateForSubmission()
        XCTAssertEqual(try GolfCodec.decode(GolfRoundPayload.self, from: GolfCodec.encode(round)), round)
        XCTAssertNil(round.holes[2].putts)
        XCTAssertEqual(round.holes[6].putts, 0)
        let summary = GolfAnalytics.summary(round)
        XCTAssertEqual(summary.totalStrokes, 41)
        XCTAssertEqual(summary.scoreToPar, 5)
        XCTAssertEqual(summary.putting.recorded, 3)
        XCTAssertEqual(summary.putting.eligible, 9)
        XCTAssertEqual(summary.putting.total, 4)
        XCTAssertEqual(summary.penalties.total, 0)
        XCTAssertEqual(summary.fairways, GolfRate(count: 1, recorded: 2, eligible: 7))
        XCTAssertEqual(summary.approaches, GolfRate(count: 1, recorded: 3, eligible: 9))
        let observations = GolfAnalytics.shots(round)
        XCTAssertEqual(observations.count, 5)
        let parThree = try XCTUnwrap(observations.first { $0.holeNumber == 2 })
        XCTAssertEqual(parThree.kind, .approach)
        XCTAssertEqual(parThree.club, "8i")
        XCTAssertEqual(parThree.distanceMetres, Decimal(string: "138.0744"))
        XCTAssertFalse(observations.contains { $0.holeNumber == 2 && $0.kind == .tee })
    }

    func testCourseSnapshotsSupportBothLengthsAndScopedRatings() throws {
        var course = GolfCourse(document: try fixture(GolfCourseDocument.self, "course_eighteen_holes"))
        try course.validate()
        let teeID = course.document.tees[0].id
        var back = try GolfRoundPayload.start(course: course, teeID: teeID, selection: .backNine, playedOn: "2026-11-19", mode: .zen)
        XCTAssertEqual(back.holes.map(\.number), Array(10...18))
        XCTAssertEqual(back.selectedRating?.courseRating, Decimal(string: "36.3"))
        XCTAssertTrue(back.holes.allSatisfy { $0.strokes == nil && $0.mode == .zen })
        course.document.name = "Edited later"
        course.document.tees[0].distances[9].distance = 999
        XCTAssertNotEqual(back.course.name, course.document.name)
        XCTAssertNotEqual(back.holes[0].distance, 999)
        back.holes[0].strokes = 5
        try back.validateForSubmission()
        back.tee.ratings?.backNine = nil
        XCTAssertNil(back.selectedRating)
        var full = try GolfRoundPayload.start(course: course, teeID: teeID, selection: .eighteen, playedOn: "2026-11-19")
        for index in full.holes.indices { full.holes[index].strokes = full.holes[index].par }
        full.status = .completed
        try full.validateForSubmission()
        XCTAssertEqual(full.selectedRating?.courseRating, Decimal(string: "72.1"))
        XCTAssertEqual(GolfAnalytics.summary(full).scoreToPar, 0)
        let nine = GolfCourse(document: try fixture(GolfCourseDocument.self, "course_nine_holes"))
        XCTAssertThrowsError(try GolfRoundPayload.start(course: nine, teeID: nine.document.tees[0].id, selection: .backNine, playedOn: "2026-11-19"))
    }

    func testValidationProtectsScoresAndDoesNotEraseModeData() throws {
        var round = try fixture(GolfRoundPayload.self, "nine_holes")
        let observation = round.holes[0].teeShot
        round.holes[0].mode = .zen
        try round.validateForSubmission()
        XCTAssertEqual(round.holes[0].teeShot, observation)
        round.holes[0].teeShot?.y = nil
        XCTAssertThrowsError(try round.validateForSubmission()) { XCTAssertEqual(($0 as? GolfValidationError)?.code, "invalid_tee_shot") }
        round.holes[0].teeShot = observation
        round.holes[1].approachShot = GolfShot(outcome: .hit)
        XCTAssertThrowsError(try round.validateForSubmission()) { XCTAssertEqual(($0 as? GolfValidationError)?.code, "duplicate_par_three_shot") }
        round.holes[1].approachShot = nil
        round.holes[0].penalties = 4
        XCTAssertThrowsError(try round.validateForSubmission()) { XCTAssertEqual(($0 as? GolfValidationError)?.code, "inconsistent_strokes") }
        round.holes[0].penalties = 0
        round.holes[0].strokes = nil
        round.status = .partial
        XCTAssertThrowsError(try round.validateForSubmission()) { XCTAssertEqual(($0 as? GolfValidationError)?.code, "unplayed_hole_has_stats") }
        XCTAssertNil(GolfCodec.date("2026-02-30T10:00:00Z"))
        XCTAssertNil(GolfCodec.date("2026-11-19T24:00:00Z"))
        round.tee.ratings = try GolfCodec.decode(GolfRatings.self, from: Data(#"{"front_nine":null}"#.utf8))
        XCTAssertThrowsError(try round.validateForSubmission()) { XCTAssertEqual(($0 as? GolfValidationError)?.code, "invalid_ratings") }
        XCTAssertThrowsError(try GolfCodec.decode(GolfRatings.self, from: Data(#"{"unknown":{}}"#.utf8)))
    }

    func testLatestTwentyUsesNewestRevisionAndKeepsPartialComparisonsSeparate() throws {
        let base = try fixture(GolfRoundPayload.self, "nine_holes")
        var rounds = (1...22).map { day in
            var round = base
            round.roundID = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", day))!
            round.playedOn = String(format: "2026-11-%02d", day)
            return round
        }
        var correction = rounds[21]
        correction.revision = 2
        correction.playedOn = "2026-09-01"
        rounds.append(correction)
        rounds[20].status = .partial
        let window = GolfAnalytics.latestTwenty(rounds)
        XCTAssertEqual(window.count, 20)
        XCTAssertEqual(window.first?.roundID, rounds[20].roundID)
        XCTAssertFalse(window.contains { $0.roundID == rounds[0].roundID || $0.roundID == correction.roundID })
        var tied = rounds[0]
        tied.roundID = rounds[1].roundID
        XCTAssertEqual(GolfAnalytics.latestTwenty([tied, rounds[0]]).first?.roundID, rounds[0].roundID)
        let groups = GolfAnalytics.trends(rounds)
        XCTAssertEqual(groups.map(\.roundCount), [19, 1])
        XCTAssertEqual(groups.map(\.status), [.completed, .partial])
        var zen = base
        for index in zen.holes.indices {
            zen.holes[index].teeShot = nil
            zen.holes[index].approachShot = nil
            zen.holes[index].putts = nil
            zen.holes[index].penalties = nil
        }
        let summary = GolfAnalytics.summary(zen)
        XCTAssertNil(summary.putting.total)
        XCTAssertNil(summary.putting.average)
        XCTAssertNil(summary.fairways.value)
        XCTAssertEqual(summary.fairways.eligible, 7)
    }
}
