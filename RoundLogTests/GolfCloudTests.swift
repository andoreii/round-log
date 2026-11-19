import XCTest
@testable import RoundLog

final class GolfCloudTests: XCTestCase {
    private let owner = UUID(uuidString: "00000000-0000-4000-8000-000000000010")!

    private func service(storage: MemoryGolfSessionStorage, handler: @escaping (URLRequest) throws -> (Int, Data)) -> SupabaseGolfService {
        CloudURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudURLProtocol.self]
        return SupabaseGolfService(network: URLSession(configuration: configuration), storage: storage)
    }

    private func savedSession(expired: Bool = false) -> GolfAuthSession {
        GolfAuthSession(accessToken: "test-access", refreshToken: "test-refresh",
                        expiresAt: Date().addingTimeInterval(expired ? -100 : 3600), userID: owner)
    }

    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    func testConcurrentExpiredRequestsShareOneRefreshAndKeepOwnerFilters() async throws {
        let storage = MemoryGolfSessionStorage(savedSession(expired: true))
        let calls = CloudCallCounter()
        let owner = self.owner
        let cloud = service(storage: storage) { request in
            switch request.url!.path {
            case "/auth/v1/token":
                calls.increment()
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "refresh_token")
                return (200, try self.json(["access_token": "new-access", "refresh_token": "rotated-refresh", "expires_in": 3600]))
            case "/auth/v1/user":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
                return (200, try self.json(["id": owner.uuidString, "is_anonymous": false]))
            case "/rest/v1/latest_round_status":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "user_id" }?.value, "eq.\(owner.uuidString.lowercased())")
                return (200, Data("[]".utf8))
            default: XCTFail("Unexpected endpoint"); return (500, Data())
            }
        }
        async let first = cloud.latestStatuses(ownerID: owner)
        async let second = cloud.latestStatuses(ownerID: owner)
        let results = try await (first, second)
        XCTAssertTrue(results.0.isEmpty && results.1.isEmpty)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(try storage.load()?.refreshToken, "rotated-refresh")
        do {
            try await cloud.saveStar(roundID: UUID(), starred: true, ownerID: UUID())
            XCTFail("A different account's queued write must be rejected")
        } catch { XCTAssertEqual(error as? GolfCloudError, .authenticationRequired) }
    }

    func testTransientRefreshRetainsSessionAndRevokedRefreshClearsIt() async throws {
        let storage = MemoryGolfSessionStorage(savedSession(expired: true))
        let cloud = service(storage: storage) { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await cloud.authenticatedUserID(); XCTFail("Expected connection error") }
        catch { XCTAssertEqual(error as? GolfCloudError, .offline) }
        XCTAssertNotNil(try storage.load())
        CloudURLProtocol.handler = { _ in
            (400, try self.json(["code": "refresh_token_not_found", "msg": "Private server detail"]))
        }
        do { _ = try await cloud.authenticatedUserID(); XCTFail("Expected authentication error") }
        catch { XCTAssertEqual(error as? GolfCloudError, .authenticationRequired) }
        XCTAssertNil(try storage.load())
    }

    func testRestoreKeepsLatestTwentyAndOlderStarsWithoutInventingScores() async throws {
        let storage = MemoryGolfSessionStorage(savedSession())
        let payloads = (1...22).map { index -> GolfRoundPayload in
            let roundID = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 100))!
            let holes = (1...9).map { GolfHoleResult(number: $0, par: 4, strokeIndex: $0, distance: 300, strokes: 4, mode: .zen) }
            return GolfRoundPayload(roundID: roundID, revision: 1,
                playedOn: String(format: "2026-11-%02d", index), createdAt: "2026-11-01T01:00:00Z",
                roundType: .casual, status: .completed, plannedHoles: 9,
                course: GolfCourseSnapshot(id: UUID(), holeCount: 9, name: "Sample Links", distanceUnit: .yd),
                tee: GolfTeeSnapshot(id: UUID(), name: "White"), holes: holes)
        }
        let uploads = (1...22).map { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0 + 200))! }
        let owner = self.owner
        let cloud = service(storage: storage) { request in
            if request.url!.path == "/auth/v1/user" {
                return (200, try self.json(["id": owner.uuidString, "is_anonymous": false]))
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "user_id" }?.value, "eq.\(owner.uuidString.lowercased())")
            switch request.url!.lastPathComponent {
            case "courses": return (200, Data("[]".utf8))
            case "latest_round_status":
                let statuses = zip(payloads, uploads).map { payload, upload in
                    GolfRemoteStatus(roundID: payload.roundID, uploadID: upload, revision: 1, state: .processed)
                }
                return (200, try GolfCodec.encode(statuses))
            case "round_preferences": return (200, try self.json([["round_id": payloads[0].roundID.uuidString]]))
            case "round_uploads":
                let select = query.first { $0.name == "select" }!.value!
                if select.contains("played_on") {
                    return (200, try self.json(zip(payloads, uploads).map { payload, upload in
                        ["id": upload.uuidString, "round_id": payload.roundID.uuidString,
                         "played_on": payload.playedOn, "created_at": payload.createdAt]
                    }))
                }
                let requested = query.first { $0.name == "id" }!.value!
                XCTAssertFalse(requested.lowercased().contains(uploads[1].uuidString.lowercased()))
                let rows = try zip(payloads, uploads).filter { requested.lowercased().contains($0.1.uuidString.lowercased()) }.map { payload, upload in
                    ["id": upload.uuidString, "payload": try JSONSerialization.jsonObject(with: GolfCodec.encode(payload))] as [String: Any]
                }
                return (200, try self.json(rows))
            default: XCTFail("Unexpected endpoint"); return (500, Data())
            }
        }
        let restored = try await cloud.restore(ownerID: owner)
        XCTAssertEqual(restored.rounds.count, 21)
        XCTAssertTrue(restored.rounds.contains { $0.payload.roundID == payloads[0].roundID && $0.starred })
        XCTAssertFalse(restored.rounds.contains { $0.payload.roundID == payloads[1].roundID })
        XCTAssertTrue(restored.rounds.flatMap { $0.payload.holes }.allSatisfy { $0.putts == nil && $0.penalties == nil })
    }
}

private final class MemoryGolfSessionStorage: GolfSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: GolfAuthSession?
    init(_ session: GolfAuthSession?) { value = session }
    func load() throws -> GolfAuthSession? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ session: GolfAuthSession) throws { lock.lock(); defer { lock.unlock() }; value = session }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}

private final class CloudCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

private final class CloudURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var callback: ((URLRequest) throws -> (Int, Data))?
    static var handler: ((URLRequest) throws -> (Int, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); defer { lock.unlock() }; callback = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
