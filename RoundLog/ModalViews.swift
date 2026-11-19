import SwiftUI

struct ModalContent: View {
    let kind: Modal
    var body: some View {
        switch kind {
        case .profile: ProfileView()
        case .activity: ActivityView()
        case .create(let zip): CreateRoomView(zip: zip)
        case .join: JoinRoomView()
        case .roomSettings(let id): RoomSettingsView(roomID: id)
        case .calendar(let id): CalendarView(roomID: id)
        case .export(let id): ExportView(roomID: id)
        case .preview(let id): ExportPreview(roomID: id)
        case .editProfile: EditNameView()
        case .editRoom(let id): EditNameView(roomID: id)
        case .capacity(let id): CapacityView(roomID: id)
        case .members(let id): MembersView(roomID: id)
        case .member(let room, let person): MemberView(roomID: room, personID: person)
        case .invite(let id): InviteView(roomID: id)
        case .avatar(let id): AvatarPicker(roomID: id)
        case .caption(let id, let day, let hour): CaptionView(roomID: id, day: day, hour: hour)
        case .reactions(let id): ReactionsView(entryID: id)
        case .layout(let id): LayoutView(roomID: id)
        case .background: BackgroundView()
        case .qr(let id): QRView(roomID: id)
        case .info(let title): InfoView(title: title)
        case .backup: BackupView()
        case .blocked: BlockedView()
        }
    }
}

extension ModalHost {
    func isCaption(_ kind: Modal) -> Bool { if case .caption = kind { return true }; return false }
    func isCalendar(_ kind: Modal) -> Bool { if case .calendar = kind { return true }; return false }
    func isFloating(_ kind: Modal) -> Bool {
        switch kind { case .create, .join, .editProfile, .editRoom, .capacity, .avatar, .reactions: true; default: false }
    }
    func horizontalInset(_ kind: Modal) -> CGFloat {
        if case .create = kind { return 10 }
        if case .caption = kind { return 12 }
        return isFloating(kind) ? 28 : 10
    }
    func bottomInset(_ kind: Modal) -> CGFloat { if case .caption = kind { return 21 }; return isFloating(kind) ? 0 : 10 }
    func sheetRadius(_ kind: Modal) -> CGFloat { if case .caption = kind { return 22 }; return isFloating(kind) ? 42 : 34 }
    func sheetWidth(_ kind: Modal) -> CGFloat {
        switch kind { case .create: .infinity; case .join: 318; default: isFloating(kind) ? 342 : .infinity }
    }
    func verticalOffset(_ kind: Modal) -> CGFloat { if case .create = kind { return 10 }; return 0 }
    func height(_ kind: Modal, total: CGFloat, width: CGFloat, maximum: CGFloat) -> CGFloat {
        switch kind {
        case .join: 138
        case .create: 420
        case .editProfile, .editRoom: 205
        case .capacity: 260
        case .avatar: 250
        case .reactions: 150
        case .calendar: total * 0.52
        case .export: total * 0.553
        case .caption: min(maximum, (width - 24) / 1.55)
        case .invite, .qr: min(maximum, 500)
        case .background, .layout: min(maximum, 430)
        default: maximum
        }
    }
}

struct CreateRoomView: View {
    var zip = false
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var name = ""
    @State private var capacity = 3
    @State private var stack = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RoundButton(symbol: "xmark", label: "Cancel") { dismissKeyboard(); router.close() }
                Spacer()
                RoundButton(symbol: "checkmark", label: "Create room", filled: true, tint: .blue) {
                    let id = store.createRoom(name: name, capacity: capacity, zip: zip)
                    if stack { store.updateRoom(id) { $0.layout = "stack" } }
                    dismissKeyboard(); router.open(.room(id))
                }.accessibilityIdentifier("confirm-create")
            }.overlay {
                Text(zip ? "new zip" : "new room").font(.system(size: 17, weight: .semibold))
                    .overlay(alignment: .leading) { StarMark(size: 44).offset(x: -52) }
                    .allowsHitTesting(false)
            }.padding(.horizontal, 24).padding(.top, 26)
            TextField("room name (optional)", text: $name).font(.system(size: 16)).textInputAutocapitalization(.never).padding(.horizontal, 23).frame(height: 54).background(.white, in: Capsule()).focused($focused).submitLabel(.done).accessibilityIdentifier("room-name-input").padding(.horizontal, 16).padding(.top, 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("room size").font(.system(size: 17))
                CapacityChips(selection: $capacity, minimum: 1).padding(.top, 14)
                Button { stack.toggle() } label: { Text("stack").font(.system(size: 16)).padding(.horizontal, 16).frame(height: 42).background(stack ? .blue.opacity(0.15) : .white.opacity(0.6), in: Capsule()).overlay(Capsule().stroke(.black.opacity(0.08))) }.accessibilityAddTraits(stack ? .isSelected : []).padding(.top, 8)
                Text(capacity == 20 ? "you + up to 19 friends" : "you + \(capacity - 1) \(capacity == 2 ? "friend" : "friends")").font(.system(size: 13)).foregroundStyle(Palette.secondary).padding(.top, 22)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 30).padding(.top, 28)
            Divider().opacity(0.35).padding(.horizontal, 34).padding(.top, 17)
            Button("or join with code") { router.close(); router.show(.join) }.font(.system(size: 14)).foregroundStyle(.blue).frame(height: 44).padding(.top, 7)
            Spacer(minLength: 0)
        }
            .task { try? await Task.sleep(for: .milliseconds(280)); focused = true }
    }
}

struct CapacityChips: View {
    @Binding var selection: Int
    var minimum: Int
    var body: some View {
        HStack(spacing: 10) {
            ForEach([2, 3, 4, 5, 20], id: \.self) { item in
                Button { selection = item } label: {
                    Text(item == 20 ? "6–20" : "\(item)").font(.system(size: 17)).frame(minWidth: item == 20 ? 76 : 44, minHeight: 44)
                        .foregroundStyle(selection == item ? .white : .black)
                        .background(selection == item ? .blue : .white.opacity(0.65), in: Capsule())
                        .overlay(Capsule().stroke(.black.opacity(selection == item ? 0 : 0.09), lineWidth: 1))
                }.disabled(item < minimum).opacity(item < minimum ? 0.35 : 1).accessibilityLabel("\(item) members").accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
    }
}

struct CapacityView: View {
    let roomID: UUID
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var selection = 3
    var body: some View {
        VStack(spacing: 20) {
            SheetHeading(title: "room size")
            CapacityChips(selection: $selection, minimum: store.room(roomID)?.members.count ?? 1)
            Button("done") { store.updateRoom(roomID) { $0.capacity = selection }; router.close() }.font(.system(size: 16, weight: .medium)).foregroundStyle(.blue).frame(minHeight: 44)
            Spacer(minLength: 0)
        }.onAppear { selection = store.room(roomID)?.capacity ?? 3 }
    }
}

struct JoinRoomView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var code = ""
    @State private var error = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("join from code").font(.system(size: 17, weight: .medium)); Spacer(); Button { router.show(.info("scan a code")) } label: { Image(systemName: "viewfinder").foregroundStyle(.blue) }.accessibilityLabel("Scan a code, simulated") }
            HStack {
                TextField("pin code", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused).submitLabel(.go).onSubmit(join).accessibilityIdentifier("join-code-input")
                Button(action: join) { Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).frame(width: 28, height: 28).background(.blue, in: Circle()) }.accessibilityLabel("Join room").accessibilityIdentifier("confirm-join")
            }.padding(.horizontal, 20).frame(height: 52).background(.white, in: Capsule())
        }.padding(20).overlay(alignment: .bottomLeading) {
            if error { Text("No unlocked room with this code. Try c3kyh14.").font(.system(size: 10)).foregroundStyle(.red).lineLimit(1).padding(.horizontal, 20).padding(.bottom, 3).accessibilityIdentifier("join-error") }
        }.task { try? await Task.sleep(for: .milliseconds(260)); focused = true }
    }
    private func join() {
        if let id = store.join(code: code) { dismissKeyboard(); router.open(.room(id)) }
        else { error = true }
    }
}

struct InviteView: View {
    let roomID: UUID
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    var body: some View {
        VStack(spacing: 23) {
            SheetHeading(title: "invite")
            Face(color: .blue, size: 66)
            Text(store.room(roomID)?.name ?? "room").font(.title3.weight(.medium))
            Text(store.room(roomID)?.code ?? "").font(.system(size: 28, weight: .medium, design: .monospaced)).padding(.horizontal, 28).padding(.vertical, 18).insetCard()
            HStack(spacing: 30) {
                Button { UIPasteboard.general.string = store.room(roomID)?.code; router.notify("invite copied") } label: { Label("copy code", systemImage: "document.on.document") }.font(.system(size: 15))
                Button { router.show(.qr(roomID)) } label: { Label("QR code", systemImage: "qrcode") }.font(.system(size: 15))
            }.foregroundStyle(.blue)
            if store.room(roomID)?.locked == true { Text("This room is locked. Unlock it to accept invites.").font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center) }
            Spacer(minLength: 0)
        }.padding(.horizontal, 20)
    }
}

struct CaptionView: View {
    let roomID: UUID
    let day: Date
    let hour: Int
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var caption = ""
    @FocusState private var focused: Bool
    var body: some View {
        ZStack {
            Palette.card.opacity(0.65)
            HStack(alignment: .center) {
                Text(store.room(roomID)?.isVlog == true ? "vlog" : String(format: "%02d:00", hour))
                    .font(.custom("ArialRoundedMTBold", size: 18, relativeTo: .body)).foregroundStyle(Palette.secondary)
                Spacer()
                Text("00:00").font(.system(size: 17)).foregroundStyle(.black.opacity(0.12))
            }.padding(.horizontal, 16)
            TextEditor(text: $caption).font(.system(size: 18)).multilineTextAlignment(.center).autocorrectionDisabled().scrollContentBackground(.hidden).focused($focused)
                .frame(maxWidth: .infinity).frame(height: 96).padding(.horizontal, 68).padding(.top, 20).accessibilityIdentifier("caption-input")
            VStack {
                HStack {
                    Button { dismissKeyboard(); router.close() } label: { Image(systemName: "xmark").font(.system(size: 24)).foregroundStyle(Palette.secondary).frame(width: 44, height: 44) }.accessibilityLabel("Cancel caption")
                    Spacer()
                    HStack(spacing: 7) { Text(store.room(roomID)?.name ?? "caption"); Image(systemName: "chevron.right") }.font(.system(size: 17)).foregroundStyle(Palette.secondary)
                    Spacer()
                    RoundButton(symbol: "arrow.up", label: "Save caption", filled: true, tint: .blue) { store.caption(room: roomID, day: day, hour: hour, text: caption); dismissKeyboard(); router.close() }.accessibilityIdentifier("save-caption")
                }
                Spacer()
                HStack { Spacer(); Image(systemName: "square.and.arrow.down").font(.system(size: 24)).foregroundStyle(Palette.secondary).frame(width: 44, height: 44).accessibilityLabel("Import media, unavailable in this demo").disabled(true) }
            }.padding(10)
        }.onAppear { caption = store.entries(room: roomID, day: day, hour: hour).first { $0.personID == DemoState.meID }?.caption ?? ""; focused = true }
    }
}

struct CalendarView: View {
    let roomID: UUID
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var month = Date()
    private var canAdvance: Bool { Calendar.current.compare(month, to: store.now, toGranularity: .month) == .orderedAscending }
    private var logged: Set<Date> { Set(store.state.logs.filter { $0.roomID == roomID && !$0.media.isEmpty && !$0.archived }.map { Calendar.current.startOfDay(for: $0.date) }) }
    private var days: [Date?] {
        let calendar = Calendar.current
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
        let leading = (calendar.component(.weekday, from: first) + 6) % 7
        return Array(repeating: nil, count: leading) + (calendar.range(of: .day, in: .month, for: first) ?? 1..<2).map { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
    }
    var body: some View {
        VStack(spacing: 15) {
            HStack {
                RoundButton(symbol: "chevron.left", label: "Previous month", size: 44) { shift(-1) }
                Spacer(); Text(month.formatted(.dateTime.month(.wide).year()).lowercased()).font(.system(size: 16, weight: .semibold)); Spacer()
                RoundButton(symbol: "chevron.right", label: "Next month", size: 44, tint: canAdvance ? Palette.ink : Palette.ink.opacity(0.22)) { shift(1) }
                    .disabled(!canAdvance)
            }.padding(.horizontal, 16).padding(.top, 12)
            HStack(spacing: 55) {
                VStack(spacing: 5) { HStack(spacing: 5) { Image(systemName: "leaf.fill").foregroundStyle(.green); Text((logged.min() ?? store.now).formatted(.dateTime.month(.abbreviated).day()).lowercased()) }; Text("since 2026").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                VStack(spacing: 5) { HStack(spacing: 5) { Face(color: .pink, size: 16); Text("\(logged.count)") }; Text("days logged").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
            }.font(.system(size: 15, weight: .medium)).padding(.vertical, 2)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 7) {
                    ForEach(["sun", "mon", "tue", "wed", "thu", "fri", "sat"], id: \.self) { Text($0).font(.system(size: 10)).foregroundStyle(Palette.secondary).frame(height: 18) }
                    ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                        if let date {
                            let selected = Calendar.current.isDate(date, inSameDayAs: router.days[roomID] ?? store.now)
                            Button {
                                router.days[roomID] = LogDay.start(containing: Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date)!)
                                router.close()
                            } label: {
                                VStack(spacing: 3) {
                                    Text("\(Calendar.current.component(.day, from: date))").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                                    if logged.contains(date) { Face(color: .blue, size: 17) } else if Calendar.current.isDate(date, inSameDayAs: store.now) { Circle().fill(.black.opacity(0.10)).frame(width: 15, height: 15) } else { Color.clear.frame(width: 15, height: 15) }
                                }.frame(maxWidth: .infinity, minHeight: 32).padding(.vertical, 2).background(selected ? .black.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }.disabled(date > store.now).accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton).accessibilityLabel(date.formatted(date: .complete, time: .omitted)).accessibilityIdentifier("date-\(Calendar.current.component(.day, from: date))")
                        } else { Color.clear.frame(height: 32) }
                    }
                }.id(Calendar.current.dateComponents([.year, .month], from: month))
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }.scrollIndicators(.hidden)
        }.onAppear { month = router.days[roomID] ?? store.now }
    }
    private func shift(_ offset: Int) {
        guard offset <= 0 || canAdvance else { return }
        // The reference switches the month grid immediately; only the sheet itself travels.
        month = Calendar.current.date(byAdding: .month, value: offset, to: month)!
    }
}

struct ActivityView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    var body: some View {
        VStack(spacing: 0) {
            Text("activity").font(.system(size: 18, weight: .semibold)).frame(height: 64)
            ScrollView {
                VStack(spacing: 18) {
                    ForEach(store.state.activity) { item in
                        Button { router.open(.chat(item.roomID)) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text("A").font(.system(size: 12)).foregroundStyle(Palette.secondary).frame(width: 36, height: 36).background(.black.opacity(0.12), in: Circle())
                                VStack(alignment: .leading, spacing: 4) { Text(item.text).font(.system(size: 15)).multilineTextAlignment(.leading); Text("yesterday").font(.system(size: 12)).foregroundStyle(.gray.opacity(0.55)) }
                                Spacer(minLength: 2)
                                RoundedRectangle(cornerRadius: 8).fill(Palette.accent(4).opacity(0.15)).frame(width: 48, height: 32).overlay(Image(systemName: item.symbol).font(.system(size: 13)).foregroundStyle(Palette.secondary))
                            }
                        }.buttonStyle(PressStyle())
                    }
                }.padding(.horizontal, 20).padding(.bottom, 22)
            }
            Color.clear.frame(height: 80).accessibilityHidden(true)
        }
    }
}

struct ReactionsView: View {
    let entryID: UUID
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    var body: some View { VStack { SheetHeading(title: "react"); HStack(spacing: 22) { ForEach(["❤️", "✨", "🥰", "😂", "👀"], id: \.self) { reaction in Button { store.react(to: entryID, with: reaction); router.close() } label: { Text(reaction).font(.system(size: 28)).frame(minWidth: 36, minHeight: 44) }.accessibilityLabel(reaction) } }; Spacer(minLength: 0) } }
}

struct LayoutView: View {
    let roomID: UUID
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    var body: some View {
        VStack(spacing: 15) {
            SheetHeading(title: "layout")
            ForEach(["list", "grid", "stack"], id: \.self) { item in
                Button { store.updateRoom(roomID) { $0.layout = item }; router.close() } label: {
                    HStack { Image(systemName: item == "grid" ? "square.grid.2x2" : item == "stack" ? "square.stack" : "rectangle.split.1x2").frame(width: 30); Text(item); Spacer(); if store.room(roomID)?.layout == item { Image(systemName: "checkmark").foregroundStyle(.blue) } }.padding(18).insetCard()
                }.padding(.horizontal, 20)
            }
            Spacer()
        }
    }
}

struct ExportView: View {
    let roomID: UUID
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RoundButton(symbol: "xmark", label: "Close export") { router.close() }
                Spacer(); Text("export").font(.system(size: 18, weight: .semibold)); Spacer()
                RoundButton(symbol: "checkmark", label: "Preview export", filled: true, tint: .blue) { router.show(.preview(roomID)) }.accessibilityIdentifier("preview-export")
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "speedometer").foregroundStyle(.white).frame(width: 28, height: 28).background(.cyan, in: RoundedRectangle(cornerRadius: 7)); Text("video speed"); Spacer()
                        Picker("video speed", selection: store.binding(\.export.speed)) { ForEach(["0.5×", "normal", "1.5×", "2×"], id: \.self) { Text($0).tag($0) } }.labelsHidden().tint(Palette.secondary).accessibilityIdentifier("export-speed")
                    }.padding(.horizontal, 18).frame(minHeight: 56).insetCard(radius: 28)
                    SettingsGroup {
                        SettingToggle(symbol: "rectangle.on.rectangle", color: .purple.opacity(0.55), title: "rounded cards", value: store.binding(\.export.rounded)); line
                        SettingToggle(symbol: "person.crop.rectangle", color: .green, title: "show name", value: store.binding(\.export.showName)); line
                        SettingToggle(symbol: "clock", color: .yellow, title: "hide time", value: store.binding(\.export.hideTime))
                    }
                    VStack(spacing: 0) {
                        SectionLabel(title: "background")
                        SettingsGroup {
                            SettingRow(symbol: "paintpalette", color: .pink.opacity(0.5), title: "color", swatch: exportColor(store.state.export.background)) { router.show(.background) }; line
                            SettingRow(symbol: "photo", color: .blue.opacity(0.6), title: "photo library", value: store.state.export.usePhoto ? "selected" : nil) { router.show(.background) }
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 20)
            }.scrollIndicators(.hidden)
        }
    }
    private var line: some View { Divider().padding(.leading, 60).padding(.trailing, 18).opacity(0.5) }
}

struct BackgroundView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    var body: some View {
        VStack(spacing: 22) {
            SheetHeading(title: "background")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 20) {
                ForEach(0..<8) { index in
                    Button { store.update { $0.export.background = index; $0.export.usePhoto = false }; router.close() } label: {
                        Circle().fill(exportColor(index)).frame(width: 52, height: 52).overlay(Circle().stroke(.gray.opacity(0.2)))
                            .overlay { if store.state.export.background == index { Image(systemName: "checkmark").foregroundStyle(index == 0 ? .white : .black) } }
                    }.accessibilityLabel(["black", "white", "cyan", "orange", "purple", "green", "blue", "pink"][index])
                }
            }.padding(.horizontal, 30)
            Button { store.update { $0.export.usePhoto = true }; router.close() } label: { Label("use sample background", systemImage: "photo").font(.system(size: 16)).padding(20).frame(maxWidth: .infinity).insetCard() }.padding(.horizontal, 22)
            Spacer()
        }
    }
}
func exportColor(_ index: Int) -> Color { index == 0 ? .black : index == 1 ? .white : Palette.accent(index - 2) }

struct ExportPreview: View {
    let roomID: UUID
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    var body: some View {
        VStack(spacing: 18) {
            SheetHeading(title: "preview")
            GeometryReader { geometry in
                ZStack {
                    exportColor(store.state.export.background)
                    if store.state.export.usePhoto { LoopPlayer(name: "morning", paused: true).blur(radius: 20) }
                    VStack(spacing: 8) {
                        ForEach(Array((store.room(roomID)?.members ?? [store.state.profile]).enumerated()), id: \.element.id) { index, person in
                            ZStack {
                                LoopPlayer(name: index == 0 ? "morning" : "afternoon", paused: store.isTesting, rate: ["0.5×": Float(0.5), "normal": 1, "1.5×": 1.5, "2×": 2][store.state.export.speed] ?? 1)
                                if !store.state.export.hideTime { Text("12:00").font(.custom("ArialRoundedMTBold", size: 23)).foregroundStyle(.white) }
                                if store.state.export.showName { VStack { HStack { PersonAvatar(person: person, size: 24); Text(person.name).font(.system(size: 14)).foregroundStyle(.white); Spacer() }; Spacer() }.padding(12) }
                            }.frame(height: min(200, geometry.size.width / 1.78)).clipShape(RoundedRectangle(cornerRadius: store.state.export.rounded ? 22 : 0))
                        }
                    }.padding(16)
                }.clipShape(RoundedRectangle(cornerRadius: 26))
            }.padding(.horizontal, 20)
            Button { router.closeAll(); router.notify("preview ready") } label: { Text("done").font(.system(size: 17, weight: .medium)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 52).background(.blue, in: Capsule()) }.padding(.horizontal, 28).padding(.bottom, 22)
        }
    }
}

struct BackupView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var email = ""
    @State private var error = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetHeading(title: "backup email")
            VStack(alignment: .leading, spacing: 12) {
                Text("add a backup email").font(.title3.weight(.medium))
                TextField("email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().padding(18).insetCard().accessibilityIdentifier("backup-email")
                if error { Text("Enter a valid email address.").font(.subheadline).foregroundStyle(.red) }
                Button("save") {
                    let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
                    if value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil { store.update { $0.backupEmail = value }; dismissKeyboard(); router.close(); router.notify("backup email saved") }
                    else { error = true }
                }.foregroundStyle(.blue).frame(maxWidth: .infinity, minHeight: 48).insetCard()
            }.padding(.horizontal, 24)
            Spacer()
        }.onAppear { email = store.state.backupEmail }
    }
}

struct InfoView: View {
    let title: String
    @Environment(AppRouter.self) private var router
    @State private var text = ""
    @State private var stars = 0
    var body: some View {
        VStack(spacing: 24) {
            SheetHeading(title: title)
            if title == "feedback" {
                TextEditor(text: $text).scrollContentBackground(.hidden).padding(16).insetCard().padding(.horizontal, 20)
                Button("send feedback") { dismissKeyboard(); router.close(); router.notify("feedback saved") }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).foregroundStyle(.blue).padding(.bottom, 24)
            } else if title == "rate round-log" {
                Spacer(); HStack(spacing: 14) { ForEach(1...5, id: \.self) { index in Button { stars = index } label: { Image(systemName: index <= stars ? "star.fill" : "star").font(.system(size: 32)).foregroundStyle(.yellow) }.accessibilityLabel("\(index) stars") } }; Button("done") { router.close(); router.notify("thank you") }.foregroundStyle(.blue); Spacer()
            } else {
                Image(systemName: title.contains("key") ? "key" : title.contains("device") ? "iphone.gen3" : title.contains("scan") ? "qrcode.viewfinder" : "document.text").font(.system(size: 40)).foregroundStyle(Palette.secondary).padding(.top, 32)
                Text(title).font(.title3.weight(.medium))
                Text(title.contains("scan") ? "Use a room’s pin code to join." : title.contains("device") ? "Your backup email is ready to help you move your logs." : title.contains("key") ? "Keep your key somewhere safe." : "A little space for everyday moments.")
                    .foregroundStyle(Palette.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
                if title.contains("key") || title.contains("device") { Button("continue") { router.close(); router.notify("all set") }.foregroundStyle(.blue).frame(minHeight: 44) }
                Spacer()
            }
        }
    }
}
