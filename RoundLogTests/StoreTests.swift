import XCTest
@testable import RoundLog

@MainActor final class StoreTests: XCTestCase {
    private var directory: URL!
    private let clock = ISO8601DateFormatter().date(from: "2026-11-16T14:00:00Z")!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "RoundLogTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }
    private func store(reset: Bool = true) -> AppStore { AppStore(fileURL: directory.appending(path: "demo.json"), now: clock, reset: reset, testing: true) }

    func testEditsAndMessagesSurviveRelaunch() {
        let first = store()
        first.updateProfile(name: "Sam", avatar: "face")
        first.update { $0.profile.color = 3; $0.export.hideTime = true; $0.backupEmail = "sam@example.com" }
        first.updateRoom(DemoState.friendsID) { $0.name = "our days"; $0.locked = true }
        first.send("See you at six", to: DemoState.friendsID)
        let second = store(reset: false)
        XCTAssertEqual(second.state.profile.name, "Sam")
        XCTAssertEqual(second.state.profile.color, 3)
        XCTAssertTrue(second.state.export.hideTime)
        XCTAssertEqual(second.state.backupEmail, "sam@example.com")
        XCTAssertEqual(second.room(DemoState.friendsID)?.name, "our days")
        XCTAssertEqual(second.room(DemoState.friendsID)?.members.last?.name, "Sam")
        XCTAssertEqual(second.state.messages.last?.text, "See you at six")
        XCTAssertNil(second.storageError)
    }

    func testCreateJoinLockReorderAndReset() {
        let store = store()
        let id = store.createRoom(name: "  ", capacity: 5)
        XCTAssertEqual(store.room(id)?.name, "new room")
        XCTAssertEqual(store.room(id)?.capacity, 5)
        let code = store.room(id)!.code
        XCTAssertEqual(store.join(code: " \(code.uppercased()) "), id)
        store.updateRoom(id) { $0.locked = true }
        XCTAssertNil(store.join(code: code))
        XCTAssertNil(store.join(code: "unknown"))
        let initial = store.room(DemoState.friendsID)!.members.map(\.id)
        store.updateRoom(DemoState.friendsID) { $0.members.reverse() }
        XCTAssertEqual(store.room(DemoState.friendsID)!.members.map(\.id), Array(initial.reversed()))
        XCTAssertEqual(self.store(reset: false).room(DemoState.friendsID)!.members.map(\.id), Array(initial.reversed()))
        store.reset()
        XCTAssertNil(store.room(id))
        XCTAssertEqual(store.state.profile.name, "You")
    }

    func testCaptionsReactionsAndArchiveShareOneStore() {
        let store = store()
        let day = Calendar.current.date(byAdding: .day, value: -1, to: clock)!
        let entry = store.entries(room: DemoState.friendsID, day: day, hour: 12).first!
        store.react(to: entry.id, with: "❤️")
        XCTAssertEqual(store.entries(room: DemoState.friendsID, day: day, hour: 12).first { $0.id == entry.id }?.reaction, "❤️")
        store.caption(room: DemoState.friendsID, day: day, hour: 12, text: "a small moment")
        XCTAssertEqual(store.entries(room: DemoState.friendsID, day: day, hour: 12).first { $0.personID == DemoState.meID }?.caption, "a small moment")
        store.update { state in state.logs[state.logs.firstIndex { $0.id == entry.id }!].archived = true }
        XCTAssertFalse(store.entries(room: DemoState.friendsID, day: day, hour: 12).contains { $0.id == entry.id })
        XCTAssertTrue(store.entries(room: DemoState.friendsID, day: day, archived: true).contains { $0.id == entry.id })
        let count = store.state.messages.count
        store.send("  \n ", to: DemoState.friendsID)
        XCTAssertEqual(store.state.messages.count, count)
    }

    func testFourAMBoundaryIncludingDaylightSaving() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        for (month, day) in [(3, 8), (11, 1), (11, 16)] {
            let before = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 3, minute: 59))!
            let after = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 4))!
            XCTAssertEqual(calendar.component(.hour, from: LogDay.start(containing: before, calendar: calendar)), 4)
            XCTAssertEqual(calendar.component(.day, from: LogDay.start(containing: before, calendar: calendar)), day - 1 == 0 ? 31 : day - 1)
            XCTAssertEqual(LogDay.start(containing: after, calendar: calendar), after)
        }
    }

    func testUnreadableStoreIsNotSilentlyOverwritten() throws {
        let url = directory.appending(path: "demo.json")
        let bytes = Data("unreadable saved data".utf8)
        try bytes.write(to: url)
        let store = store(reset: false)
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(store.state.rooms.count, 5)
    }

    func testTimelinePagesAcrossDaysAndKeepsTheCurrentEmptyHour() {
        let store = store()
        let pages = store.timeline(room: DemoState.friendsID)
        XCTAssertEqual(pages.last?.day, LogDay.start(containing: clock))
        XCTAssertEqual(pages.last?.hour, Calendar.current.component(.hour, from: clock))
        XCTAssertLessThan(pages[pages.count - 2].day, pages.last!.day)
        XCTAssertEqual(Set(pages).count, pages.count)
        XCTAssertEqual(pages.first?.hour, 4)
    }
    func testLeavingRoomRemovesRelatedStateAndSurvivesRelaunch() {
        let first = store()
        first.leaveRoom(DemoState.friendsID)
        let restored = store(reset: false)
        XCTAssertNil(restored.room(DemoState.friendsID))
        XCTAssertEqual(restored.state.rooms.count, 4)
        XCTAssertTrue(restored.state.logs.allSatisfy { $0.roomID != DemoState.friendsID })
        XCTAssertTrue(restored.state.messages.allSatisfy { $0.roomID != DemoState.friendsID })
        XCTAssertTrue(restored.state.activity.allSatisfy { $0.roomID != DemoState.friendsID })
        XCTAssertNil(restored.storageError)
    }
}
