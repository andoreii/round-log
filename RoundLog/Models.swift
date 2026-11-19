import Foundation
import Observation

struct Person: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var avatar: String = "face"
    var color: Int = 4
}

struct Room: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var members: [Person]
    var capacity: Int = 3
    var isVlog = false
    var isZip = false
    var avatar = "face"
    var notifications = true
    var locked = false
    var classic = true
    var layout = "list"
    var code: String
}

struct LogEntry: Codable, Identifiable {
    var id: UUID
    var roomID: UUID
    var personID: UUID
    var date: Date
    var hour: Int
    var caption: String
    var media: String
    var reaction: String?
    var archived = false
}

struct ChatMessage: Codable, Identifiable {
    var id = UUID()
    var roomID: UUID
    var text: String
    var isMe: Bool
    var date: Date
    var media: String?
}

struct LogPosition: Hashable, Identifiable {
    let day: Date
    let hour: Int
    var id: Self { self }
}

struct ActivityItem: Codable, Identifiable {
    var id = UUID()
    var roomID: UUID
    var text: String
    var symbol: String
}

struct ExportOptions: Codable {
    var speed = "normal"
    var rounded = false
    var showName = false
    var hideTime = false
    var background = 0
    var usePhoto = false
}

struct DemoState: Codable {
    var version = 1
    var profile: Person
    var rooms: [Room]
    var logs: [LogEntry]
    var messages: [ChatMessage]
    var activity: [ActivityItem]
    var accent = 4
    var reminders = "1hr"
    var countryFlag = true
    var rotateToCapture = true
    var soundEffects = true
    var backupEmail = ""
    var blocked: [Person] = []
    var export = ExportOptions()

    static let meID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let friendID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let vlogID = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
    static let friendsID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

    static func seed(now: Date, calendar: Calendar = .current) -> Self {
        let me = Person(id: meID, name: "You", avatar: "cat", color: 4)
        let friend = Person(id: friendID, name: "Alex", color: 2)
        let rooms = [
            Room(id: vlogID, name: "vlog", members: [me], capacity: 1, isVlog: true, code: "vlog001"),
            Room(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, name: "Alex", members: [friend, me], capacity: 2, code: "alex001"),
            Room(id: friendsID, name: "Friends", members: [friend, me], code: "c3kyh14"),
            Room(id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!, name: "July 16", members: [me], code: "july016"),
            Room(id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!, name: "Jul.15", members: [me], code: "july015")
        ]
        let today = LogDay.start(containing: now, calendar: calendar)
        var logs: [LogEntry] = []
        for offset in 1...5 {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            for room in rooms where !room.isVlog {
                for hour in [4, 6, 7, 9, 11, 12] {
                    for (index, person) in room.members.enumerated() {
                        logs.append(LogEntry(id: UUID(), roomID: room.id, personID: person.id, date: day, hour: hour,
                                             caption: hour == 4 && index == 1 ? "good morning" : "",
                                             media: (hour + index) % 2 == 0 ? "morning" : "afternoon",
                                             reaction: hour == 12 && index == 0 ? "❤️" : nil))
                    }
                }
            }
        }
        return DemoState(profile: me, rooms: rooms, logs: logs,
                         messages: [ChatMessage(roomID: friendsID, text: "", isMe: true, date: now, media: "morning"),
                                    ChatMessage(roomID: friendsID, text: "How long are you staying?", isMe: false, date: now, media: nil),
                                    ChatMessage(roomID: friendsID, text: "", isMe: true, date: now, media: "afternoon")],
                         activity: [ActivityItem(roomID: friendsID, text: "Alex replied “How long are you staying?”", symbol: "bubble.left"),
                                    ActivityItem(roomID: friendsID, text: "Alex reacted to your log: ❤️", symbol: "heart.fill"),
                                    ActivityItem(roomID: friendsID, text: "Alex reacted to your log: ✨", symbol: "sparkles")])
    }
}

enum LogDay {
    static func start(containing date: Date, calendar: Calendar = .current) -> Date {
        let cutoff = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: date)!
        return date < cutoff ? calendar.date(byAdding: .day, value: -1, to: cutoff)! : cutoff
    }
}

@MainActor @Observable
final class AppStore {
    var state: DemoState
    var storageError: String?
    let now: Date
    let isTesting: Bool
    private let fileURL: URL

    init(fileURL: URL? = nil, now: Date? = nil, reset: Bool = false, testing: Bool = false) {
        let args = ProcessInfo.processInfo.arguments
        isTesting = testing || args.contains("--ui-testing")
        if let now { self.now = now }
        else if let index = args.firstIndex(of: "--fixed-clock"), args.indices.contains(index + 1),
                let date = ISO8601DateFormatter().date(from: args[index + 1]) { self.now = date }
        else if isTesting { self.now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 22))! }
        else { self.now = Date() }
        self.fileURL = fileURL ?? URL.applicationSupportDirectory.appending(path: "RoundLog/demo.json")
        state = .seed(now: self.now)
        if !reset && !args.contains("--reset-demo") && FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                let decoded = try JSONDecoder().decode(DemoState.self, from: Data(contentsOf: self.fileURL))
                guard decoded.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                state = decoded
            } catch {
                storageError = "Your saved demo couldn’t be opened. The original file has been kept."
            }
        } else { save() }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
        } catch { storageError = "Your changes couldn’t be saved. Please check available storage and try again." }
    }

    func update(_ change: (inout DemoState) -> Void) { change(&state); save() }
    func room(_ id: UUID) -> Room? { state.rooms.first { $0.id == id } }
    func updateRoom(_ id: UUID, _ change: (inout Room) -> Void) {
        guard let index = state.rooms.firstIndex(where: { $0.id == id }) else { return }
        change(&state.rooms[index]); save()
    }
    func updateProfile(name: String? = nil, avatar: String? = nil, color: Int? = nil) {
        if let name { state.profile.name = name }
        if let avatar { state.profile.avatar = avatar }
        if let color { state.profile.color = color }
        for index in state.rooms.indices {
            if let member = state.rooms[index].members.firstIndex(where: { $0.id == DemoState.meID }) {
                state.rooms[index].members[member] = state.profile
            }
        }
        save()
    }
    @discardableResult func createRoom(name: String, capacity: Int, zip: Bool = false) -> UUID {
        let room = Room(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (zip ? "zip" : "new room") : name,
                        members: [state.profile], capacity: capacity, isZip: zip,
                        code: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(7)).lowercased())
        state.rooms.append(room); save(); return room.id
    }
    func join(code: String) -> UUID? {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let room = state.rooms.first(where: { $0.code == code && !$0.locked }) else { return nil }
        return room.id
    }
    func send(_ text: String, to roomID: UUID) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, room(roomID) != nil else { return }
        state.messages.append(ChatMessage(roomID: roomID, text: text, isMe: true, date: now))
        save()
    }
    func entries(room: UUID, day: Date, hour: Int? = nil, archived: Bool = false) -> [LogEntry] {
        let key = LogDay.start(containing: day)
        return state.logs.filter { $0.roomID == room && LogDay.start(containing: $0.date) == key && (hour == nil || $0.hour == hour) && $0.archived == archived }
    }
    func timeline(room: UUID) -> [LogPosition] {
        var positions = Set(state.logs.filter { $0.roomID == room && !$0.archived }.map { LogPosition(day: LogDay.start(containing: $0.date), hour: $0.hour) })
        positions.insert(LogPosition(day: LogDay.start(containing: now), hour: Calendar.current.component(.hour, from: now)))
        return positions.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            return ($0.hour < 4 ? $0.hour + 24 : $0.hour) < ($1.hour < 4 ? $1.hour + 24 : $1.hour)
        }
    }
    func react(to id: UUID, with reaction: String?) {
        guard let index = state.logs.firstIndex(where: { $0.id == id }) else { return }
        state.logs[index].reaction = reaction; save()
    }
    func caption(room: UUID, day: Date, hour: Int, text: String) {
        if let index = state.logs.firstIndex(where: { $0.roomID == room && $0.personID == DemoState.meID && LogDay.start(containing: $0.date) == LogDay.start(containing: day) && $0.hour == hour }) {
            state.logs[index].caption = text
        } else {
            state.logs.append(LogEntry(id: UUID(), roomID: room, personID: DemoState.meID, date: LogDay.start(containing: day), hour: hour, caption: text, media: ""))
        }
        save()
    }
    func leaveRoom(_ id: UUID) {
        update { state in
            state.rooms.removeAll { $0.id == id }
            state.logs.removeAll { $0.roomID == id }
            state.messages.removeAll { $0.roomID == id }
            state.activity.removeAll { $0.roomID == id }
        }
    }
    func reset() { state = .seed(now: now); save() }
}
