import SwiftUI

struct RoomView: View {
    let roomID: UUID
    var namespace: Namespace.ID
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var selection: LogPosition?
    @State private var dateCaption: String?
    private var day: Date { router.days[roomID] ?? LogDay.start(containing: store.now) }
    private var pages: [LogPosition] {
        var positions = store.timeline(room: roomID)
        if !positions.contains(where: { $0.day == day }) { positions.append(LogPosition(day: day, hour: 22)); positions.sort { $0.day < $1.day } }
        return positions
    }
    private var hours: [Int] { pages.filter { $0.day == (selection?.day ?? day) }.map(\.hour) }
    var body: some View {
        if let room = store.room(roomID) {
            VStack(spacing: 0) {
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 10) {
                        RoundButton(symbol: "chevron.left", label: "Back") { router.back() }.accessibilityIdentifier("back")
                        Button { router.show(.export(roomID)) } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 22)).frame(width: 36, height: 44) }.buttonStyle(PressStyle()).accessibilityLabel("Export")
                        Spacer(minLength: 0)
                        Button { router.show(.roomSettings(roomID)) } label: {
                            HStack(spacing: 5) { Text(room.name).font(.system(size: 17, weight: .medium)).lineLimit(1); Image(systemName: "chevron.right").font(.system(size: 15, weight: .medium)) }
                                .frame(minHeight: 44)
                        }.buttonStyle(PressStyle()).accessibilityLabel("Room settings").accessibilityIdentifier("room-settings")
                        Spacer(minLength: 0)
                        HStack(spacing: 0) {
                            Button { router.show(.calendar(roomID)) } label: { Image(systemName: "calendar").frame(width: 48, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Calendar").accessibilityIdentifier("calendar")
                            NavigationLink(value: Screen.chat(roomID)) {
                                Image(systemName: "bubble.right").frame(width: 48, height: 44).contentShape(Rectangle())
                            }.accessibilityLabel("Chat").accessibilityIdentifier("chat")
                                .matchedTransitionSource(id: "chat-\(roomID)", in: namespace) { source in
                                    source.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)).background(.clear)
                                }
                        }.font(.system(size: 22)).buttonStyle(.plain).glassPill()
                    }.padding(.horizontal, 16).padding(.top, 0).frame(height: 34)
                }
                HStack(spacing: 6) {
                    ForEach(hours, id: \.self) { hour in
                        Button { withAnimation(.smooth(duration: 0.25)) { selection = LogPosition(day: day, hour: hour) } } label: {
                            Circle().fill(hour == selection?.hour ? (hours.count == 1 ? Color.black : Palette.accent(store.state.profile.color)) : Palette.accent(store.state.profile.color).opacity(0.3))
                                .frame(width: hour == selection?.hour ? 8 : 5, height: hour == selection?.hour ? 8 : 5)
                                .padding(.vertical, 7)
                        }.buttonStyle(PressStyle()).accessibilityLabel("\(hour):00").accessibilityIdentifier("hour-\(hour)")
                    }
                }.frame(height: 36)
                    .overlay { if let dateCaption { Text(dateCaption).font(.system(size: 13)).padding(.horizontal, 13).padding(.vertical, 7).background(.white, in: Capsule()).allowsHitTesting(false) } }
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(pages) { position in
                            RoomPage(room: room, day: position.day, hour: position.hour).containerRelativeFrame(.horizontal).id(position)
                        }
                    }.scrollTargetLayout()
                }.scrollIndicators(.hidden).scrollTargetBehavior(.paging).scrollPosition(id: $selection)
                    .accessibilityIdentifier("timeline")
                if room.isVlog {
                    HStack {
                        RoundButton(symbol: "square.and.arrow.up", label: "Export vlog") { router.show(.export(roomID)) }
                        Spacer()
                        Image(systemName: "camera.fill").foregroundStyle(.white).frame(width: 36, height: 36).background(.blue.opacity(0.65), in: Circle())
                            .accessibilityLabel("Camera, unavailable in this demo").disabled(true)
                    }.padding(.horizontal, 28).padding(.bottom, 10)
                }
            }.background(Palette.background).toolbar(.hidden, for: .navigationBar)
                .onAppear { selection = pages.first { $0.day == day && $0.hour == router.hours[roomID] } ?? pages.last { $0.day == day } }
                .onChange(of: router.days[roomID]) { _, _ in
                    if selection?.day != day { selection = pages.last { $0.day == day } }
                }
                .onChange(of: selection) { old, value in
                    guard let value else { return }
                    router.hours[roomID] = value.hour
                    router.days[roomID] = value.day
                    if let old, old.day != value.day {
                        let label = value.day.formatted(.dateTime.month(.abbreviated).day().year())
                        dateCaption = label
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.4))
                            if dateCaption == label { withAnimation(.smooth(duration: 0.15)) { dateCaption = nil } }
                        }
                    }
                }

        } else { ContentUnavailableView("Room unavailable", systemImage: "rectangle.stack").onAppear { router.back() } }
    }
}

struct RoomPage: View {
    let room: Room
    let day: Date
    let hour: Int
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    private var entries: [LogEntry] { store.entries(room: room.id, day: day, hour: hour) }
    private var hasMedia: Bool { entries.contains { !$0.media.isEmpty } }
    var body: some View {
        GeometryReader { geometry in
            let capacity = room.isVlog ? 1 : min(room.capacity, 20)
            let cardHeight = hasMedia ? max(150, (geometry.size.width - 24) / (room.classic ? 1.78 : 1.33)) : max(150, (geometry.size.height - 12 - CGFloat(capacity - 1) * 3) / CGFloat(capacity))
            ScrollView {
                if room.layout == "grid" && !room.isVlog {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                        cards(height: max(170, cardHeight * 0.7), capacity: capacity)
                    }
                } else {
                    VStack(spacing: room.layout == "stack" ? -36 : (hasMedia ? 10 : 3)) { cards(height: room.isVlog ? (geometry.size.width - 24) / 1.55 : cardHeight, capacity: capacity) }
                }
            }.scrollIndicators(.hidden)
                .contentMargins(.vertical, hasMedia ? max(0, (geometry.size.height - cardHeight * CGFloat(room.members.count) - CGFloat(max(0, room.members.count - 1)) * 10) / 2 - (router.safeInsets.top + 70 - router.safeInsets.bottom) / 2) : (room.isVlog ? max(0, (geometry.size.height - (geometry.size.width - 24) / 1.55) / 2 - 14) : 0))
                .padding(.horizontal, 12)
        }
    }
    @ViewBuilder private func cards(height: CGFloat, capacity: Int) -> some View {
        ForEach(Array(room.members.enumerated()), id: \.element.id) { index, person in
            LogCard(room: room, person: person, entry: entries.first { $0.personID == person.id }, day: day, hour: hour, seed: index + 1)
                .frame(height: height)
                .opacity(isEditing(person: person) ? 0 : 1)
        }
        if !hasMedia && room.members.count < capacity {
            ForEach(room.members.count..<capacity, id: \.self) { _ in
                Button { router.show(.invite(room.id)) } label: {
                    VStack(spacing: 18) {
                        Image(systemName: "plus").font(.system(size: 26)).frame(width: 54, height: 54).background(.white.opacity(0.55), in: Circle())
                        Text("invite").font(.system(size: 17)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).frame(height: height).insetCard(radius: 22)
                }.buttonStyle(PressStyle()).accessibilityIdentifier("invite-slot")
            }
        }
    }
    private func isEditing(person: Person) -> Bool {
        guard person.id == DemoState.meID, let sheet = router.sheets.last, case .caption(let id, _, _) = sheet.kind else { return false }
        return id == room.id
    }
}

struct LogCard: View {
    let room: Room
    let person: Person
    let entry: LogEntry?
    let day: Date
    let hour: Int
    let seed: Int
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var paused = false
    private var media: Bool { !(entry?.media.isEmpty ?? true) }
    var body: some View {
        ZStack {
            Palette.card
            if media, let entry {
                LoopPlayer(name: entry.media, paused: paused || store.isTesting).allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.04)).contentShape(Rectangle()).onTapGesture { paused.toggle() }.accessibilityLabel(paused ? "Play log" : "Pause log").accessibilityAddTraits(.isButton)
            } else if !room.isVlog { FloatingFace(seed: seed, testing: store.isTesting) }
            if room.isVlog {
                HStack(spacing: 8) {
                    Text("vlog").font(.custom("ArialRoundedMTBold", size: 17, relativeTo: .body)).foregroundStyle(Palette.secondary)
                    Spacer(minLength: 3)
                    Text("tap to capture").referenceFont(17).padding(.horizontal, 23).padding(.vertical, 6).background(.white, in: Capsule()).disabled(true).accessibilityLabel("Capture, unavailable in this demo")
                    Spacer(minLength: 3)
                    Text("00:00").font(.system(size: 17, weight: .medium)).foregroundStyle(.black.opacity(0.10))
                }.padding(.horizontal, 16)
                if let caption = entry?.caption, !caption.isEmpty { Text(caption).font(.subheadline).foregroundStyle(Palette.secondary).offset(y: 42) }
            } else {
                VStack(spacing: 6) {
                    Text(String(format: "%02d:00", hour)).font(.custom("ArialRoundedMTBold", size: media ? 23 : 22, relativeTo: .title3)).bold().italic()
                        .foregroundStyle(media ? .white : .black.opacity(0.12))
                    if let caption = entry?.caption, !caption.isEmpty { Text(caption).font(.system(size: 14, weight: .medium)).foregroundStyle(media ? .white : Palette.secondary).lineLimit(3) }
                    if !media && person.id == DemoState.meID {
                        Text("tap to capture").referenceFont(17).padding(.horizontal, 23).padding(.vertical, 6).background(.white, in: Capsule())
                            .accessibilityLabel("Capture, unavailable in this demo").disabled(true)
                    }
                }.allowsHitTesting(false)
            }
            VStack {
                HStack(spacing: 9) {
                    PersonAvatar(person: person, size: 28)
                    Text(person.name).referenceFont(16, weight: media ? .medium : .regular).foregroundStyle(media ? .white : .black.opacity(0.62))
                    Spacer()
                }
                Spacer()
                HStack {
                    if media && paused { Image(systemName: "play.fill").font(.footnote).foregroundStyle(.white).accessibilityHidden(true) }
                    Spacer()
                    if media, let entry {
                        VStack(spacing: 9) {
                            Button { router.show(.reactions(entry.id)) } label: { Image(systemName: "face.smiling").frame(width: 34, height: 34) }.accessibilityLabel("React to log")
                            Button { router.push(.chat(room.id, zoom: false)) } label: { Image(systemName: "arrowshape.turn.up.left").frame(width: 34, height: 34) }.accessibilityLabel("Reply to log")
                            Button { store.react(to: entry.id, with: entry.reaction == nil ? "❤️" : nil) } label: {
                                if let reaction = entry.reaction { Text(reaction).font(.system(size: 22)).frame(width: 34, height: 34) }
                                else { Image(systemName: "heart").frame(width: 34, height: 34) }
                            }.accessibilityLabel(entry.reaction == nil ? "Like log" : "Remove reaction")
                        }.font(.system(size: 20)).foregroundStyle(.white).buttonStyle(PressStyle())
                    }
                    if person.id == DemoState.meID {
                        Menu {
                            Button("edit caption", systemImage: "text.cursor") { router.show(.caption(room.id, day, hour)) }
                            if let entry, media {
                                Button("reply", systemImage: "bubble.left") { router.push(.chat(room.id, zoom: false)) }
                                Button("archive", systemImage: "archivebox") {
                                    store.update { state in if let index = state.logs.firstIndex(where: { $0.id == entry.id }) { state.logs[index].archived = true } }
                                }
                            }
                        } label: { Image(systemName: "ellipsis").font(.system(size: 20, weight: .medium)).frame(width: 38, height: 34).foregroundStyle(media ? .white : .black.opacity(0.6)) }
                            .buttonStyle(.automatic).accessibilityLabel("Log options").accessibilityIdentifier("log-options")
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 10)
        }.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct ChatView: View {
    let roomID: UUID
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var message = ""
    var body: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 12) {
                HStack {
                    RoundButton(symbol: "chevron.left", label: "Back") { router.back() }.accessibilityIdentifier("back")
                    Spacer(); Text("chat").font(.system(size: 17, weight: .medium)); Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }.padding(.horizontal, 16).frame(height: 54)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        Text("yesterday").font(.caption).foregroundStyle(Palette.secondary).padding(.vertical, 10)
                        ForEach(store.state.messages.filter { $0.roomID == roomID }) { item in
                            HStack {
                                if item.isMe { Spacer(minLength: 80) }
                                Group {
                                    if let media = item.media { LoopPlayer(name: media, paused: store.isTesting).frame(width: 160, height: 100).clipShape(RoundedRectangle(cornerRadius: 24)) }
                                    else { Text(item.text).referenceFont(16).padding(.horizontal, 15).padding(.vertical, 12).background(item.isMe ? Palette.card : .white, in: RoundedRectangle(cornerRadius: 23)) }
                                }
                                if !item.isMe { Spacer(minLength: 80) }
                            }.id(item.id)
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 16)
                }.scrollDismissesKeyboard(.interactively)
                    .onChange(of: store.state.messages.count) { _, _ in if let id = store.state.messages.last?.id { withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            HStack(spacing: 9) {
                Image(systemName: "camera.fill").font(.system(size: 17)).foregroundStyle(.gray).frame(width: 25, height: 32).accessibilityLabel("Camera unavailable").disabled(true)
                TextField("message", text: $message, axis: .vertical).referenceFont(16).lineLimit(1...4).autocorrectionDisabled().submitLabel(.send).onSubmit(send).accessibilityIdentifier("message-input")
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold)).foregroundStyle(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.25) : .white).frame(width: 31, height: 31).background(message.isEmpty ? .clear : .blue, in: Circle()) }.buttonStyle(PressStyle()).disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Send message").accessibilityIdentifier("send-message")
            }.padding(.horizontal, 13).padding(.vertical, 8).softSurface().padding(.horizontal, 16).padding(.bottom, 12)
        }.background(Palette.background).toolbar(.hidden, for: .navigationBar)
    }
    private func send() { store.send(message, to: roomID); message = "" }
}

struct ArchiveView: View {
    let roomID: UUID
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    private var entries: [LogEntry] { store.state.logs.filter { $0.roomID == roomID && $0.archived } }
    var body: some View {
        VStack {
            HStack { RoundButton(symbol: "chevron.left", label: "Back") { router.back() }; Spacer(); Text("archive").font(.headline); Spacer(); Color.clear.frame(width: 44, height: 44) }.padding(.horizontal, 16)
            if entries.isEmpty { Spacer(); Image(systemName: "archivebox").font(.system(size: 36)).foregroundStyle(.gray.opacity(0.45)); Text("no archived logs").foregroundStyle(Palette.secondary).padding(.top, 8); Spacer() }
            else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(entries) { entry in
                            VStack {
                                if !entry.media.isEmpty { LoopPlayer(name: entry.media, paused: store.isTesting).frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 22)) }
                                HStack { Text(entry.date.formatted(date: .abbreviated, time: .omitted)); Spacer(); Button("restore") { store.update { state in if let index = state.logs.firstIndex(where: { $0.id == entry.id }) { state.logs[index].archived = false } } }.buttonStyle(PressStyle()) }.font(.subheadline)
                            }.padding(12).insetCard()
                        }
                    }.padding(16)
                }
            }
        }.background(Palette.background).toolbar(.hidden, for: .navigationBar)
    }
}
