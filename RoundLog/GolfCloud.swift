import Foundation
import Security

enum GolfProcessingState: String, Codable, Sendable { case pending, processed, invalid }

struct GolfRemoteStatus: Codable, Equatable, Sendable {
    var roundID: UUID
    var uploadID: UUID
    var revision: Int
    var state: GolfProcessingState
    var errorCode: String?

    enum CodingKeys: String, CodingKey {
        case roundID = "round_id", uploadID = "upload_id", revision, state, errorCode = "error_code"
    }
}

struct GolfSubmissionReceipt: Codable, Equatable, Sendable {
    var uploadID: UUID
    var roundID: UUID
    var revision: Int
    var state: GolfProcessingState
    var duplicate: Bool
    var dispatch: String?
    var code: String?

    enum CodingKeys: String, CodingKey {
        case uploadID = "upload_id", roundID = "round_id", revision, state, duplicate, dispatch, code
    }
}

struct GolfRestoredRound: Sendable {
    var payload: GolfRoundPayload
    var starred: Bool
    var status: GolfRemoteStatus
}

struct GolfRestore: Sendable {
    var courses: [GolfCourse]
    var rounds: [GolfRestoredRound]
}

protocol GolfCloud: Sendable {
    func authenticatedUserID() async throws -> UUID
    func saveCourse(_ course: GolfCourse, ownerID: UUID) async throws
    func submit(_ payload: GolfRoundPayload, ownerID: UUID) async throws -> GolfSubmissionReceipt
    func latestStatuses(ownerID: UUID) async throws -> [GolfRemoteStatus]
    func saveStar(roundID: UUID, starred: Bool, ownerID: UUID) async throws
    func restore(ownerID: UUID) async throws -> GolfRestore
}

enum GolfCloudError: Error, Equatable, Sendable {
    case authenticationRequired, offline, unavailable, secureStorage
    case conflict(String), rejected(String)
}

struct GolfCloudConfiguration: Sendable {
    var url: URL
    var publishableKey: String
    static let project = GolfCloudConfiguration(
        url: URL(string: "https://joevrtazhvmhrdmxneow.supabase.co")!,
        publishableKey: "sb_publishable_Coje-xZdWUOx49aTyp483Q_5AtqOH-q"
    )
}

struct GolfAuthSession: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: UUID
}

protocol GolfSessionStorage: Sendable {
    func load() throws -> GolfAuthSession?
    func save(_ session: GolfAuthSession) throws
    func clear() throws
}

struct GolfKeychainStorage: GolfSessionStorage {
    var service = "com.andrei.roundlog.supabase"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "session"]
    }

    func load() throws -> GolfAuthSession? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let session = try? JSONDecoder().decode(GolfAuthSession.self, from: data) else {
            throw GolfCloudError.secureStorage
        }
        return session
    }

    func save(_ session: GolfAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GolfCloudError.secureStorage }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GolfCloudError.secureStorage }
    }
}

private final class GolfNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor SupabaseGolfService: GolfCloud {
    private let configuration: GolfCloudConfiguration
    private let network: URLSession
    private let storage: any GolfSessionStorage
    private var session: GolfAuthSession?
    private var loadedSession = false
    private var generation = UUID()
    private var refreshing: (id: UUID, task: Task<GolfAuthSession, Error>)?

    init(configuration: GolfCloudConfiguration = .project, network: URLSession? = nil,
         storage: any GolfSessionStorage = GolfKeychainStorage()) {
        self.configuration = configuration
        self.storage = storage
        let options = URLSessionConfiguration.ephemeral
        options.urlCache = nil
        options.httpCookieStorage = nil
        options.timeoutIntervalForRequest = 30
        options.timeoutIntervalForResource = 60
        self.network = network ?? URLSession(configuration: options, delegate: GolfNoRedirects(), delegateQueue: nil)
    }

    func signIn(email: String, password: String) async throws {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            throw GolfCloudError.rejected("credentials_required")
        }
        let attempt = UUID()
        generation = attempt
        refreshing?.task.cancel()
        refreshing = nil
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let signedIn = try await exchange(grant: "password", body: body)
        guard generation == attempt else { throw GolfCloudError.authenticationRequired }
        try storage.save(signedIn)
        session = signedIn
        loadedSession = true
    }

    func signOut() async throws {
        try loadSession()
        let token = session?.accessToken
        generation = UUID()
        refreshing?.task.cancel()
        refreshing = nil
        try storage.clear()
        session = nil
        if let token {
            // Local sign-out still works without a connection; offline data stays on the phone.
            _ = try? await send(path: "auth/v1/logout", method: "POST", token: token,
                                query: [URLQueryItem(name: "scope", value: "local")])
        }
    }

    @discardableResult func restoreSession() async throws -> UUID { try await authenticatedUserID() }

    func authenticatedUserID() async throws -> UUID {
        let data = try await authorized(path: "auth/v1/user")
        let user = try decode(AuthUser.self, data)
        guard user.isAnonymous != true, user.id == session?.userID else {
            try clearSession()
            throw GolfCloudError.authenticationRequired
        }
        return user.id
    }

    func saveCourse(_ course: GolfCourse, ownerID: UUID) async throws {
        try course.validate()
        let owner = try await authenticatedUserID()
        guard owner == ownerID else { throw GolfCloudError.authenticationRequired }
        let body = CourseSave(courseID: course.id, revision: course.revision, document: course.document)
        _ = try await authorized(path: "rest/v1/rpc/save_course", method: "POST", body: GolfCodec.encode(body), owner: owner)
    }

    func submit(_ payload: GolfRoundPayload, ownerID: UUID) async throws -> GolfSubmissionReceipt {
        try payload.validateForSubmission()
        let owner = try await authenticatedUserID()
        guard owner == ownerID else { throw GolfCloudError.authenticationRequired }
        let data = try await authorized(path: "functions/v1/submit-round", method: "POST", body: GolfCodec.encode(payload), owner: owner)
        let receipt = try decode(GolfSubmissionReceipt.self, data)
        guard receipt.roundID == payload.roundID, receipt.revision == payload.revision else {
            throw GolfCloudError.rejected("invalid_cloud_data")
        }
        return receipt
    }

    func latestStatuses(ownerID: UUID) async throws -> [GolfRemoteStatus] {
        let owner = try await authenticatedUserID()
        guard owner == ownerID else { throw GolfCloudError.authenticationRequired }
        return try await statuses(owner: owner)
    }

    func saveStar(roundID: UUID, starred: Bool, ownerID: UUID) async throws {
        let owner = try await authenticatedUserID()
        guard owner == ownerID else { throw GolfCloudError.authenticationRequired }
        let body = StarSave(userID: owner, roundID: roundID, starred: starred)
        _ = try await authorized(path: "rest/v1/round_preferences", method: "POST", body: GolfCodec.encode(body),
                                 query: [URLQueryItem(name: "on_conflict", value: "user_id,round_id")],
                                 prefer: "resolution=merge-duplicates,return=minimal", owner: owner)
    }

    func restore(ownerID: UUID) async throws -> GolfRestore {
        let owner = try await authenticatedUserID()
        guard owner == ownerID else { throw GolfCloudError.authenticationRequired }
        let courses: [GolfCourse] = try await rows("courses", owner: owner, select: "id,revision,document", order: "id.asc")
        for course in courses { try course.validate() }
        let statuses = try await statuses(owner: owner)
        let stars: [StarRow] = try await rows("round_preferences", owner: owner,
            select: "round_id", order: "round_id.asc", filters: [URLQueryItem(name: "starred", value: "eq.true")])
        let starred = Set(stars.map(\.roundID))
        var metadata: [UploadMetadata] = []
        for batch in statuses.map(\.uploadID).batches(of: 100) {
            metadata += try await rows("round_uploads", owner: owner,
                select: "id,round_id,played_on,created_at", order: "id.asc", filters: [idsFilter(batch)])
        }
        guard metadata.count == statuses.count, Set(metadata.map(\.id)).count == metadata.count,
              Set(metadata.map(\.roundID)) == Set(statuses.map(\.roundID)) else {
            throw GolfCloudError.rejected("invalid_cloud_data")
        }
        let ordered = try metadata.map { row in (row: row, created: try cloudDate(row.createdAt)) }.sorted {
            if $0.row.playedOn != $1.row.playedOn { return $0.row.playedOn > $1.row.playedOn }
            if $0.created != $1.created { return $0.created > $1.created }
            return $0.row.roundID.uuidString < $1.row.roundID.uuidString
        }
        let retained = Set(ordered.prefix(20).map { $0.row.roundID }).union(starred)
        let wantedStatuses = statuses.filter { retained.contains($0.roundID) }
        let statusByRound = Dictionary(uniqueKeysWithValues: wantedStatuses.map { ($0.roundID, $0) })
        var restored: [GolfRestoredRound] = []
        for batch in wantedStatuses.map(\.uploadID).batches(of: 100) {
            let uploads: [UploadPayload] = try await rows("round_uploads", owner: owner,
                select: "id,payload", order: "id.asc", filters: [idsFilter(batch)])
            for upload in uploads {
                let payload = upload.payload
                guard let status = statusByRound[payload.roundID], status.uploadID == upload.id,
                      status.revision == payload.revision else { throw GolfCloudError.rejected("invalid_cloud_data") }
                try payload.validateForSubmission()
                restored.append(GolfRestoredRound(payload: payload, starred: starred.contains(payload.roundID), status: status))
            }
        }
        guard restored.count == wantedStatuses.count,
              Set(restored.map { $0.payload.roundID }).count == restored.count else {
            throw GolfCloudError.rejected("invalid_cloud_data")
        }
        return GolfRestore(courses: courses, rounds: restored)
    }

    private func statuses(owner: UUID) async throws -> [GolfRemoteStatus] {
        let statuses: [GolfRemoteStatus] = try await rows("latest_round_status", owner: owner,
            select: "round_id,upload_id,revision,state,error_code", order: "round_id.asc")
        guard Set(statuses.map(\.roundID)).count == statuses.count,
              Set(statuses.map(\.uploadID)).count == statuses.count,
              statuses.allSatisfy({ $0.revision > 0 }) else { throw GolfCloudError.rejected("invalid_cloud_data") }
        return statuses
    }

    private func rows<T: Decodable>(_ table: String, owner: UUID, select: String,
                                    order: String, filters: [URLQueryItem] = []) async throws -> [T] {
        var result: [T] = []
        var offset = 0
        while true {
            let query = [URLQueryItem(name: "select", value: select),
                         URLQueryItem(name: "user_id", value: "eq.\(owner.uuidString.lowercased())"),
                         URLQueryItem(name: "order", value: order), URLQueryItem(name: "limit", value: "200"),
                         URLQueryItem(name: "offset", value: String(offset))] + filters
            let page: [T] = try decode([T].self, await authorized(path: "rest/v1/\(table)", query: query, owner: owner))
            result += page
            if page.count < 200 { return result }
            offset += page.count
        }
    }

    private func idsFilter(_ ids: [UUID]) -> URLQueryItem {
        URLQueryItem(name: "id", value: "in.(\(ids.map { $0.uuidString.lowercased() }.joined(separator: ",")))")
    }

    private func cloudDate(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw GolfCloudError.rejected("invalid_cloud_data") }
        return date
    }

    private func loadSession() throws {
        guard !loadedSession else { return }
        session = try storage.load()
        loadedSession = true
    }

    private func clearSession() throws {
        generation = UUID()
        refreshing?.task.cancel()
        refreshing = nil
        try storage.clear()
        session = nil
        loadedSession = true
    }

    private func validSession() async throws -> GolfAuthSession {
        try loadSession()
        guard let session else { throw GolfCloudError.authenticationRequired }
        return session.expiresAt > Date().addingTimeInterval(30) ? session : try await refreshSession()
    }

    private func refreshSession() async throws -> GolfAuthSession {
        guard let previous = session else { throw GolfCloudError.authenticationRequired }
        let attempt = generation
        let work: (id: UUID, task: Task<GolfAuthSession, Error>)
        if let refreshing { work = refreshing } else {
            let body = try JSONSerialization.data(withJSONObject: ["refresh_token": previous.refreshToken])
            work = (UUID(), Task { try await self.exchange(grant: "refresh_token", body: body) })
            refreshing = work
        }
        do {
            let refreshed = try await work.task.value
            guard generation == attempt, refreshed.userID == previous.userID else {
                throw GolfCloudError.authenticationRequired
            }
            if refreshing?.id == work.id {
                try storage.save(refreshed)
                session = refreshed
                refreshing = nil
            }
            return refreshed
        } catch {
            if generation == attempt, refreshing?.id == work.id {
                refreshing = nil
                if error as? GolfCloudError == .authenticationRequired { try clearSession() }
            }
            throw error
        }
    }

    private func exchange(grant: String, body: Data) async throws -> GolfAuthSession {
        let (data, response) = try await send(path: "auth/v1/token", method: "POST", body: body,
                                             query: [URLQueryItem(name: "grant_type", value: grant)])
        if [400, 401, 403, 422].contains(response.statusCode) {
            let error = try? JSONDecoder().decode(AuthError.self, from: data)
            let invalid = ["invalid_credentials", "refresh_token_not_found", "refresh_token_already_used",
                           "session_not_found", "session_expired", "user_not_found", "user_banned", "bad_jwt"]
            if grant == "password" || invalid.contains(error?.code ?? "") {
                throw GolfCloudError.authenticationRequired
            }
        }
        try check(response, data)
        let result = try decode(TokenResponse.self, data)
        guard !result.accessToken.isEmpty, !result.refreshToken.isEmpty,
              result.expiresIn > 0 else { throw GolfCloudError.unavailable }
        let (userData, userResponse) = try await send(path: "auth/v1/user", token: result.accessToken)
        try check(userResponse, userData)
        let user = try decode(AuthUser.self, userData)
        guard user.isAnonymous != true else { throw GolfCloudError.authenticationRequired }
        return GolfAuthSession(accessToken: result.accessToken, refreshToken: result.refreshToken,
                               expiresAt: Date().addingTimeInterval(result.expiresIn), userID: user.id)
    }

    private func authorized(path: String, method: String = "GET", body: Data? = nil,
                            query: [URLQueryItem] = [], prefer: String? = nil, owner: UUID? = nil) async throws -> Data {
        let current = try await validSession()
        guard owner == nil || owner == current.userID else { throw GolfCloudError.authenticationRequired }
        let attempt = generation
        var (data, response) = try await send(path: path, method: method, body: body,
                                              token: current.accessToken, query: query, prefer: prefer)
        guard attempt == generation else { throw GolfCloudError.authenticationRequired }
        if response.statusCode == 401 {
            let updated: GolfAuthSession
            if let session, session.accessToken != current.accessToken { updated = session }
            else { updated = try await refreshSession() }
            (data, response) = try await send(path: path, method: method, body: body,
                                             token: updated.accessToken, query: query, prefer: prefer)
            guard attempt == generation else { throw GolfCloudError.authenticationRequired }
            if response.statusCode == 401 { try clearSession() }
        }
        try check(response, data)
        return data
    }

    private func send(path: String, method: String = "GET", body: Data? = nil, token: String? = nil,
                      query: [URLQueryItem] = [], prefer: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard configuration.url.scheme == "https", configuration.url.user == nil,
              configuration.url.password == nil,
              var url = URLComponents(url: configuration.url.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw GolfCloudError.unavailable
        }
        url.queryItems = query.isEmpty ? nil : query
        guard let endpoint = url.url else { throw GolfCloudError.unavailable }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        do {
            let (data, response) = try await network.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw GolfCloudError.unavailable }
            return (data, response)
        } catch let error as URLError {
            if [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                .cannotConnectToHost, .dnsLookupFailed].contains(error.code) { throw GolfCloudError.offline }
            throw GolfCloudError.unavailable
        }
    }

    private func check(_ response: HTTPURLResponse, _ data: Data) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        if response.statusCode == 401 { throw GolfCloudError.authenticationRequired }
        let error = try? JSONDecoder().decode(ServerError.self, from: data)
        let conflicts = ["revision_conflict", "created_at_conflict", "stale_revision"]
        let code = error?.code == "22023" ? error?.message : error?.code
        if let code, conflicts.contains(code) { throw GolfCloudError.conflict(code) }
        if response.statusCode == 409 { throw GolfCloudError.conflict("conflict") }
        if [400, 413, 415, 422].contains(response.statusCode) {
            let allowed = ["invalid_envelope", "submission_too_large", "json_required", "invalid_json"]
            throw GolfCloudError.rejected(allowed.contains(code ?? "") ? code! : "invalid_data")
        }
        throw GolfCloudError.unavailable
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try GolfCodec.decode(type, from: data) }
        catch { throw GolfCloudError.rejected("invalid_cloud_data") }
    }
}

private struct AuthUser: Decodable {
    var id: UUID
    var isAnonymous: Bool?
    enum CodingKeys: String, CodingKey { case id, isAnonymous = "is_anonymous" }
}
private struct TokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String
    var expiresIn: TimeInterval
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in" }
}
private struct AuthError: Decodable { var code: String? }
private struct ServerError: Decodable { var code: String?; var message: String? }
private struct CourseSave: Encodable {
    var courseID: UUID; var revision: Int; var document: GolfCourseDocument
    enum CodingKeys: String, CodingKey { case courseID = "course_id", revision, document }
}
private struct StarSave: Encodable {
    var userID: UUID; var roundID: UUID; var starred: Bool
    enum CodingKeys: String, CodingKey { case userID = "user_id", roundID = "round_id", starred }
}
private struct StarRow: Decodable {
    var roundID: UUID
    enum CodingKeys: String, CodingKey { case roundID = "round_id" }
}
private struct UploadMetadata: Decodable {
    var id: UUID; var roundID: UUID; var playedOn: String; var createdAt: String
    enum CodingKeys: String, CodingKey { case id, roundID = "round_id", playedOn = "played_on", createdAt = "created_at" }
}
private struct UploadPayload: Decodable { var id: UUID; var payload: GolfRoundPayload }
private extension Array {
    func batches(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
