import XCTest
@testable import RoundLog

@MainActor
final class GolfStoreTests: XCTestCase {
    private func fixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "fixtures"))
        return try GolfCodec.decode(type, from: Data(contentsOf: url))
    }

    private func location() -> URL { FileManager.default.temporaryDirectory.appending(path: "golf-\(UUID())") }

    private func scoredRound(_ store: GolfStore) throws -> UUID {
        let course = GolfCourse(document: try fixture(GolfCourseDocument.self, "course_nine_holes"))
        try store.saveCourse(course.document, id: course.id)
        let id = try store.startRound(courseID: course.id, teeID: course.document.tees[0].id,
            selection: .frontNine, playedOn: "2026-11-01")
        let sample = try fixture(GolfRoundPayload.self, "nine_holes")
        try store.updateRound(id) { $0.holes = sample.holes }
        try store.setPhase(id, .finished)
        return id
    }

    func testAutosaveSnapshotsAndCorruptFileProtection() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GolfStore(directory: directory)
        let id = try scoredRound(store)
        let original = try XCTUnwrap(store.rounds[id]?.draft)
        var course = try XCTUnwrap(store.courses.first)
        course.document.name = "Changed template"
        try store.saveCourse(course.document, id: course.id)
        try store.updateRound(id) { $0.holes[0].mode = .zen }
        let reloaded = GolfStore(directory: directory)
        XCTAssertNil(reloaded.storageError)
        XCTAssertEqual(reloaded.rounds[id]?.draft.course.name, original.course.name)
        XCTAssertEqual(reloaded.rounds[id]?.draft.holes[0].teeShot, original.holes[0].teeShot)
        XCTAssertEqual(reloaded.rounds[id]?.draft.holes[0].mode, .zen)
        let file = directory.appending(path: "rounds/\(id.uuidString.lowercased()).json")
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: file)
        let damaged = GolfStore(directory: directory)
        XCTAssertNotNil(damaged.storageError)
        XCTAssertThrowsError(try damaged.saveCourse(course.document))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testFrozenRetrySurvivesRelaunchAndConcurrentDraftEdit() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GolfStore(directory: directory)
        let id = try scoredRound(store)
        XCTAssertEqual(try store.freezeSubmission(id), 1)
        let cloud = StoreCloud()
        cloud.failUpload = true
        cloud.duringSubmit = { _ in try! store.updateRound(id) { $0.holes[0].strokes = 7 } }
        await store.synchronize(using: cloud)
        XCTAssertEqual(cloud.sent.count, 1)
        XCTAssertEqual(cloud.sent[0].holes[0].strokes, 5)
        let reloaded = GolfStore(directory: directory)
        XCTAssertEqual(reloaded.rounds[id]?.draft.holes[0].strokes, 7)
        cloud.failUpload = false; cloud.duringSubmit = nil
        await reloaded.synchronize(using: cloud)
        XCTAssertEqual(try GolfCodec.encode(cloud.sent[0]), try GolfCodec.encode(cloud.sent[1]))
        XCTAssertEqual(reloaded.rounds[id]?.latestSubmission?.state, .processed)
        XCTAssertEqual(reloaded.rounds[id]?.hasUnsubmittedChanges, true)
        XCTAssertEqual(try reloaded.freezeSubmission(id), 2)
        await reloaded.synchronize(using: cloud)
        XCTAssertEqual(cloud.sent.last?.revision, 2)
        XCTAssertEqual(cloud.sent.last?.holes[0].strokes, 7)
        XCTAssertEqual(reloaded.rounds[id]?.hasUnsubmittedChanges, false)
        XCTAssertEqual(reloaded.rounds[id]?.submissions.count, 1)
        XCTAssertEqual(try reloaded.freezeSubmission(id), 2)
    }

    func testRetentionKeepsTwentyAndEveryProtectedRound() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = GolfStore(directory: directory)
        try initial.saveCourse(try fixture(GolfCourseDocument.self, "course_nine_holes"))
        let sample = try fixture(GolfRoundPayload.self, "nine_holes")
        var ids: [UUID] = []
        var archived: [GolfRestoredRound] = []
        for index in 0..<30 {
            var payload = sample
            payload.roundID = UUID(); payload.playedOn = String(format: "2026-10-%02d", index + 1)
            let submitted = GolfFrozenSubmission(snapshot: payload, state: .processed, uploadID: UUID())
            var saved = GolfSavedRound(draft: payload, phase: .finished, submissions: [submitted])
            if index == 0 { saved.starred = true }
            if index == 1 { saved.starSynced = false }
            if index == 2 { saved.phase = .paused }
            if index == 3 { saved.submissions[0].state = .queued; saved.submissions[0].uploadID = nil }
            if index == 4 { saved.submissions[0].state = .invalid }
            if index == 5 { saved.draft.holes[0].strokes = 6 }
            ids.append(saved.id)
            archived.append(GolfRestoredRound(payload: payload, starred: saved.starred,
                status: GolfRemoteStatus(roundID: saved.id, uploadID: submitted.uploadID!, revision: 1, state: .processed)))
            try GolfCodec.encode(saved).write(to: directory.appending(path: "rounds/\(saved.id.uuidString.lowercased()).json"))
        }
        let store = GolfStore(directory: directory)
        XCTAssertNil(store.storageError)
        try store.trimLocalHistory()
        XCTAssertEqual(store.rounds.count, 26)
        XCTAssertEqual(store.recentRounds.count, 20)
        XCTAssertTrue(ids.prefix(6).allSatisfy { store.rounds[$0] != nil })
        XCTAssertTrue(ids[6..<10].allSatisfy { store.rounds[$0] == nil })
        XCTAssertEqual(GolfStore(directory: directory).rounds.count, 26)
        let cloud = StoreCloud()
        cloud.restored.rounds = Array(archived[10..<30])
        await store.synchronize(using: cloud)
        try store.updateRound(ids[29]) { $0.playedOn = "2026-09-01" }
        try store.freezeSubmission(ids[29])
        cloud.restored.rounds = Array(archived[9..<29])
        await store.synchronize(using: cloud)
        XCTAssertEqual(store.recentRounds.count, 20)
        XCTAssertTrue(store.recentRounds.contains { $0.id == ids[9] })
        XCTAssertNil(store.rounds[ids[29]])
        try FileManager.default.removeItem(at: directory.appending(path: "courses.json"))
        XCTAssertNotNil(GolfStore(directory: directory).storageError)
    }

    func testRestorePreservesLocalEditsAndBlocksAccountSwitch() async throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GolfStore(directory: directory)
        let id = try scoredRound(store)
        var remote = try XCTUnwrap(store.rounds[id]?.draft)
        remote.holes[0].strokes = 9
        var other = remote; other.roundID = UUID()
        let cloud = StoreCloud()
        cloud.restored = GolfRestore(courses: [], rounds: [remote, other].map {
            GolfRestoredRound(payload: $0, starred: true,
                status: GolfRemoteStatus(roundID: $0.roundID, uploadID: UUID(), revision: 1, state: .processed))
        })
        await store.synchronize(using: cloud)
        XCTAssertEqual(store.rounds[id]?.draft.holes[0].strokes, 5)
        XCTAssertEqual(store.rounds[other.roundID]?.starred, true)
        XCTAssertTrue(cloud.sent.isEmpty)
        let owner = store.ownerID
        cloud.owner = UUID()
        try store.freezeSubmission(id)
        await store.synchronize(using: cloud)
        XCTAssertEqual(store.ownerID, owner)
        XCTAssertTrue(cloud.sent.isEmpty)
        XCTAssertNotNil(store.syncError)
    }
}

@MainActor
private final class StoreCloud: GolfCloud {
    var owner = UUID()
    var failUpload = false
    var sent: [GolfRoundPayload] = []
    var duringSubmit: ((GolfRoundPayload) -> Void)?
    var restored = GolfRestore(courses: [], rounds: [])
    func authenticatedUserID() async throws -> UUID { owner }
    func restore(ownerID: UUID) async throws -> GolfRestore { restored }
    func saveCourse(_ course: GolfCourse, ownerID: UUID) async throws { }
    func submit(_ payload: GolfRoundPayload, ownerID: UUID) async throws -> GolfSubmissionReceipt {
        sent.append(payload); duringSubmit?(payload)
        if failUpload { throw GolfCloudError.offline }
        return GolfSubmissionReceipt(uploadID: UUID(), roundID: payload.roundID, revision: payload.revision,
            state: .processed, duplicate: false)
    }
    func latestStatuses(ownerID: UUID) async throws -> [GolfRemoteStatus] { [] }
    func saveStar(roundID: UUID, starred: Bool, ownerID: UUID) async throws { }
}
