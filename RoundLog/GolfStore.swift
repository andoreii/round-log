import Foundation
import Observation

enum GolfRoundPhase: String, Codable, Sendable { case active, paused, finished }
enum GolfSubmissionState: String, Codable, Sendable { case queued, pending, processed, invalid }

struct GolfFrozenSubmission: Codable, Equatable, Sendable {
    let snapshot: GolfRoundPayload
    var state: GolfSubmissionState = .queued
    var uploadID: UUID?
    var errorCode: String?
}

struct GolfSavedRound: Codable, Equatable, Identifiable, Sendable {
    var version = 1
    var draft: GolfRoundPayload
    var phase: GolfRoundPhase = .active
    var submissions: [GolfFrozenSubmission] = []
    var starred = false
    var starSynced = true
    var updatedAt = Date()
    var id: UUID { draft.roundID }
    var latestSubmission: GolfFrozenSubmission? { submissions.max { $0.snapshot.revision < $1.snapshot.revision } }
    var hasUnsubmittedChanges: Bool { latestSubmission?.snapshot != draft }
    var safelyBackedUp: Bool {
        phase == .finished && !hasUnsubmittedChanges && latestSubmission?.state == .processed
        && !submissions.contains { $0.state == .queued } && starSynced
    }
}

private struct GolfLibrary: Codable {
    var version = 1
    var ownerID: UUID?
    var distanceUnit: GolfDistanceUnit = .yd
    var courses: [GolfCourse] = []
    var backedUpRevisions: [UUID: Int] = [:]
}

enum GolfStoreError: Error, Equatable { case unavailable, missingCourse, missingRound, invalidTransition, immutableIdentity, accountMismatch }

@MainActor @Observable
final class GolfStore {
    private(set) var courses: [GolfCourse] = []
    private(set) var rounds: [UUID: GolfSavedRound] = [:]
    private(set) var storageError: String?
    private(set) var syncError: String?
    private(set) var requiresSignIn = false
    private(set) var isSyncing = false
    @ObservationIgnored var workAvailable: (() -> Void)?
    @ObservationIgnored private var library = GolfLibrary()
    @ObservationIgnored private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "RoundLog/Golf")) {
        self.directory = directory
        reload()
    }

    var ownerID: UUID? { library.ownerID }
    var distanceUnit: GolfDistanceUnit { library.distanceUnit }
    var resumeRound: GolfSavedRound? { rounds.values.filter { $0.phase != .finished }.max { $0.updatedAt < $1.updatedAt } }
    var recentRounds: [GolfSavedRound] {
        let ids = GolfAnalytics.latestTwenty(rounds.values.filter { $0.phase == .finished }.map(\.draft)).map(\.roundID)
        return ids.compactMap { rounds[$0] }
    }
    var starredRounds: [GolfSavedRound] {
        rounds.values.filter(\.starred).sorted { GolfAnalytics.isMoreRecent($0.draft, $1.draft) }
    }
    var trends: [GolfAnalyticsGroup] { GolfAnalytics.trends(rounds.values.filter { $0.phase == .finished }.map(\.draft)) }
    var hasPendingWork: Bool {
        courses.contains { $0.revision > (library.backedUpRevisions[$0.id] ?? 0) }
        || rounds.values.contains { !$0.starSynced || $0.submissions.contains { $0.state == .queued || $0.state == .pending } }
    }

    func reload() {
        storageError = nil
        do {
            try FileManager.default.createDirectory(at: directory.appending(path: "rounds"), withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let url = directory.appending(path: "courses.json")
            var loaded = GolfLibrary()
            if FileManager.default.fileExists(atPath: url.path) {
                loaded = try GolfCodec.decode(GolfLibrary.self, from: Data(contentsOf: url))
                guard loaded.version == 1, Set(loaded.courses.map(\.id)).count == loaded.courses.count else { throw GolfStoreError.unavailable }
                for course in loaded.courses { try course.validate() }
            }
            var saved: [UUID: GolfSavedRound] = [:]
            for file in try FileManager.default.contentsOfDirectory(at: directory.appending(path: "rounds"), includingPropertiesForKeys: nil)
                where file.pathExtension == "json" {
                let round = try GolfCodec.decode(GolfSavedRound.self, from: Data(contentsOf: file))
                guard round.version == 1, file.deletingPathExtension().lastPathComponent.lowercased() == round.id.uuidString.lowercased(),
                      saved[round.id] == nil else { throw GolfStoreError.unavailable }
                try round.draft.validateDraft()
                if round.phase == .finished { try round.draft.validateForSubmission() }
                for submission in round.submissions {
                    try submission.snapshot.validateForSubmission()
                    guard submission.snapshot.roundID == round.id && submission.snapshot.createdAt == round.draft.createdAt else { throw GolfStoreError.unavailable }
                }
                guard Set(round.submissions.map { $0.snapshot.revision }).count == round.submissions.count else { throw GolfStoreError.unavailable }
                saved[round.id] = round
            }
            guard FileManager.default.fileExists(atPath: url.path) || saved.isEmpty else { throw GolfStoreError.unavailable }
            library = loaded; courses = loaded.courses; rounds = saved
        } catch {
            storageError = "Saved golf data could not be opened. Original files have been kept; saving is paused."
        }
    }

    @discardableResult
    func saveCourse(_ document: GolfCourseDocument, id: UUID? = nil) throws -> UUID {
        let id = id ?? UUID()
        let previous = courses.first { $0.id == id }
        if previous?.document == document { return id }
        let course = GolfCourse(id: id, revision: (previous?.revision ?? 0) + 1, document: document)
        try course.validate()
        var next = library
        next.courses.removeAll { $0.id == id }; next.courses.append(course)
        try saveLibrary(next)
        workAvailable?()
        return id
    }

    func archiveCourse(_ id: UUID, archived: Bool = true) throws {
        guard var document = courses.first(where: { $0.id == id })?.document else { throw GolfStoreError.missingCourse }
        document.archived = archived
        try saveCourse(document, id: id)
    }

    func setDistanceUnit(_ unit: GolfDistanceUnit) throws {
        var next = library; next.distanceUnit = unit
        try saveLibrary(next)
    }

    @discardableResult
    func startRound(courseID: UUID, teeID: UUID, selection: GolfHoleSelection, playedOn: String,
                    roundType: GolfRoundType = .casual, mode: GolfRecordingMode = .standard,
                    weather: String? = nil, notes: String? = nil, now: Date = Date()) throws -> UUID {
        guard let course = courses.first(where: { $0.id == courseID }), !course.document.archived else { throw GolfStoreError.missingCourse }
        let payload = try GolfRoundPayload.start(course: course, teeID: teeID, selection: selection, playedOn: playedOn,
            roundType: roundType, mode: mode, weather: weather, notes: notes, now: now)
        try saveRound(GolfSavedRound(draft: payload, updatedAt: now))
        return payload.roundID
    }

    func updateRound(_ id: UUID, _ change: (inout GolfRoundPayload) -> Void) throws {
        guard var round = rounds[id] else { throw GolfStoreError.missingRound }
        let original = round.draft
        change(&round.draft)
        guard round.draft.roundID == original.roundID, round.draft.createdAt == original.createdAt,
              round.draft.revision == original.revision else { throw GolfStoreError.immutableIdentity }
        if round.phase == .finished {
            round.draft.status = round.draft.holes.allSatisfy { $0.strokes != nil } ? .completed : .partial
            try round.draft.validateForSubmission()
        } else { try round.draft.validateDraft() }
        round.updatedAt = Date()
        try saveRound(round)
    }

    func setPhase(_ id: UUID, _ phase: GolfRoundPhase) throws {
        guard var round = rounds[id] else { throw GolfStoreError.missingRound }
        guard round.phase != .finished || phase == .finished else { throw GolfStoreError.invalidTransition }
        if phase == .finished {
            round.draft.status = round.draft.holes.allSatisfy { $0.strokes != nil } ? .completed : .partial
            try round.draft.validateForSubmission()
        }
        round.phase = phase; round.updatedAt = Date()
        try saveRound(round)
    }

    func setStarred(_ id: UUID, _ starred: Bool) throws {
        guard var round = rounds[id] else { throw GolfStoreError.missingRound }
        guard round.starred != starred else { return }
        round.starred = starred; round.starSynced = false
        try saveRound(round)
        workAvailable?()
    }

    @discardableResult
    func freezeSubmission(_ id: UUID) throws -> Int {
        guard var round = rounds[id] else { throw GolfStoreError.missingRound }
        guard round.phase == .finished else { throw GolfStoreError.invalidTransition }
        if let latest = round.latestSubmission, latest.snapshot == round.draft {
            workAvailable?()
            return latest.snapshot.revision
        }
        round.draft.revision = (round.latestSubmission?.snapshot.revision ?? 0) + 1
        try round.draft.validateForSubmission()
        round.submissions.append(GolfFrozenSubmission(snapshot: round.draft))
        try saveRound(round)
        workAvailable?()
        return round.draft.revision
    }

    func synchronize(using cloud: any GolfCloud) async {
        guard !isSyncing, storageError == nil else { return }
        isSyncing = true; syncError = nil
        defer { isSyncing = false }
        do {
            let user = try await cloud.authenticatedUserID()
            requiresSignIn = false
            if let ownerID, ownerID != user { throw GolfStoreError.accountMismatch }
            if library.ownerID == nil {
                var next = library; next.ownerID = user
                try saveLibrary(next)
            }
            for course in courses where course.revision > (library.backedUpRevisions[course.id] ?? 0) {
                do {
                    try Task.checkCancellation()
                    try await cloud.saveCourse(course, ownerID: user)
                    var next = library
                    next.backedUpRevisions[course.id] = max(next.backedUpRevisions[course.id] ?? 0, course.revision)
                    try saveLibrary(next)
                } catch GolfCloudError.conflict { syncError = "A course backup conflicts with its cloud revision. Local edits have been kept." }
                  catch GolfCloudError.rejected { syncError = "A course backup needs correction. Local edits have been kept." }
            }
            let submitted: [GolfFrozenSubmission] = rounds.values.flatMap { $0.submissions }
            let pending = submitted.filter { $0.state == .queued || $0.state == .pending }
                .sorted { $0.snapshot.revision < $1.snapshot.revision }
            for submission in pending {
                try Task.checkCancellation()
                do {
                    let receipt = try await cloud.submit(submission.snapshot, ownerID: user)
                    guard receipt.roundID == submission.snapshot.roundID, receipt.revision == submission.snapshot.revision else { throw GolfCloudError.unavailable }
                    try updateSubmission(receipt.roundID, revision: receipt.revision) {
                        $0.uploadID = receipt.uploadID; $0.state = GolfSubmissionState(rawValue: receipt.state.rawValue)!
                        $0.errorCode = receipt.state == .invalid ? (receipt.code ?? "needs_correction") : nil
                    }
                } catch GolfCloudError.conflict(let code) {
                    try updateSubmission(submission.snapshot.roundID, revision: submission.snapshot.revision) { $0.state = .invalid; $0.errorCode = code }
                } catch GolfCloudError.rejected(let code) {
                    try updateSubmission(submission.snapshot.roundID, revision: submission.snapshot.revision) { $0.state = .invalid; $0.errorCode = code }
                }
            }
            for status in try await cloud.latestStatuses(ownerID: user) {
                guard rounds[status.roundID]?.submissions.contains(where: { $0.snapshot.revision == status.revision }) == true else { continue }
                try updateSubmission(status.roundID, revision: status.revision) {
                    $0.state = GolfSubmissionState(rawValue: status.state.rawValue)!
                    $0.uploadID = status.uploadID; $0.errorCode = status.errorCode
                }
            }
            for saved in rounds.values where !saved.starSynced && saved.latestSubmission?.state == .processed {
                try Task.checkCancellation()
                try await cloud.saveStar(roundID: saved.id, starred: saved.starred, ownerID: user)
                guard var current = rounds[saved.id] else { continue }
                if current.starred == saved.starred { current.starSynced = true; try saveRound(current) }
            }
            // A date correction can bring a previously trimmed round back into the latest twenty.
            try merge(await cloud.restore(ownerID: user))
            try trimLocalHistory()
        } catch GolfCloudError.authenticationRequired {
            requiresSignIn = true
        } catch is CancellationError { }
          catch GolfStoreError.accountMismatch { syncError = "This golf library belongs to another account. Sign in with its original account." }
          catch { syncError = "Cloud sync could not finish. Saved data and frozen submissions will retry." }
    }

    func trimLocalHistory() throws {
        let recent = Set(recentRounds.map(\.id))
        for round in Array(rounds.values) where !recent.contains(round.id) && !round.starred && round.safelyBackedUp {
            do {
                try FileManager.default.removeItem(at: roundURL(round.id))
                rounds.removeValue(forKey: round.id)
            } catch { throw storageFailure() }
        }
    }

    private func merge(_ restored: GolfRestore) throws {
        for remote in restored.courses {
            try remote.validate()
            let local = library.courses.first { $0.id == remote.id }
            if local == nil || ((library.backedUpRevisions[remote.id] ?? 0) >= (local?.revision ?? 0) && remote.revision > (local?.revision ?? 0)) {
                var next = library
                next.courses.removeAll { $0.id == remote.id }; next.courses.append(remote)
                next.backedUpRevisions[remote.id] = remote.revision
                try saveLibrary(next)
            }
        }
        for remote in restored.rounds where rounds[remote.payload.roundID] == nil {
            try remote.payload.validateForSubmission()
            let submission = GolfFrozenSubmission(snapshot: remote.payload,
                state: GolfSubmissionState(rawValue: remote.status.state.rawValue)!, uploadID: remote.status.uploadID, errorCode: remote.status.errorCode)
            try saveRound(GolfSavedRound(draft: remote.payload, phase: .finished, submissions: [submission],
                starred: remote.starred, starSynced: true, updatedAt: GolfCodec.date(remote.payload.createdAt) ?? Date()))
        }
    }

    private func updateSubmission(_ id: UUID, revision: Int, _ change: (inout GolfFrozenSubmission) -> Void) throws {
        guard var round = rounds[id], let index = round.submissions.firstIndex(where: { $0.snapshot.revision == revision }) else { return }
        change(&round.submissions[index])
        if let latest = round.latestSubmission, latest.state == .processed {
            round.submissions.removeAll { $0.snapshot.revision < latest.snapshot.revision && $0.uploadID != nil }
        }
        try saveRound(round)
    }

    private func saveLibrary(_ next: GolfLibrary) throws {
        try write(next, to: directory.appending(path: "courses.json"))
        library = next; courses = next.courses
    }

    private func saveRound(_ round: GolfSavedRound) throws {
        try write(round, to: roundURL(round.id))
        rounds[round.id] = round
    }

    private func roundURL(_ id: UUID) -> URL { directory.appending(path: "rounds/\(id.uuidString.lowercased()).json") }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        guard storageError == nil else { throw GolfStoreError.unavailable }
        do { try GolfCodec.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { throw storageFailure() }
    }

    private func storageFailure() -> GolfStoreError {
        storageError = "Golf data could not be saved. Original files have been kept; saving is paused."
        return .unavailable
    }
}
