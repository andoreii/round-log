import SwiftUI
import CoreImage.CIFilterBuiltins

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var confirmation: String?
    private var accent: Color { Palette.accent(store.state.profile.color) }
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    RoundButton(symbol: "xmark", label: "Close settings") { router.close() }
                    Spacer()
                    Button { router.show(.qr(nil)) } label: { Image(systemName: "qrcode").font(.system(size: 23)).frame(width: 44, height: 44) }.accessibilityLabel("My QR code")
                }.padding(.bottom, 0)
                Button { router.show(.avatar(nil)) } label: {
                    PersonAvatar(person: store.state.profile, size: 72).frame(width: 88, height: 88).insetCard(radius: 44)
                        .overlay(alignment: .bottomTrailing) { Image(systemName: "pencil").font(.system(size: 17)).frame(width: 32, height: 32).softSurface().offset(x: 3, y: 3) }
                }.buttonStyle(PressStyle()).accessibilityLabel("Edit avatar").padding(.bottom, 24)
                Button { router.show(.editProfile) } label: {
                    Text(store.state.profile.name).frame(maxWidth: .infinity).frame(height: 56)
                        .overlay(alignment: .trailing) { Image(systemName: "pencil").padding(.trailing, 22) }.insetCard(radius: 28)
                }.accessibilityIdentifier("edit-profile")
                SectionLabel(title: "color")
                HStack {
                    ForEach(Palette.accents.indices, id: \.self) { index in
                        Spacer(minLength: 0)
                        Button { store.updateProfile(color: index) } label: {
                            Circle().fill(Palette.accent(index)).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(.black.opacity(0.18), lineWidth: 1))
                                .padding(4).overlay(Circle().stroke(store.state.profile.color == index ? .black : .clear, lineWidth: 2))
                        }.buttonStyle(PressStyle()).accessibilityLabel(["cyan", "orange", "purple", "green", "blue", "pink"][index]).accessibilityAddTraits(store.state.profile.color == index ? .isSelected : []).accessibilityIdentifier("color-\(index)")
                        Spacer(minLength: 0)
                    }
                }.frame(height: 56).padding(.horizontal, 12).insetCard(radius: 28)
                SectionLabel(title: "hourly log reminders")
                HStack(spacing: 12) {
                    ForEach(["1hr", "3hr", "off"], id: \.self) { item in
                        Button { store.update { $0.reminders = item } } label: {
                            Text(item).font(.system(size: 16)).frame(width: 50, height: 36)
                                .foregroundStyle(store.state.reminders == item ? .white : .black)
                                .background(store.state.reminders == item ? .black : .white.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
                        }.accessibilityLabel("Reminders \(item)").accessibilityAddTraits(store.state.reminders == item ? .isSelected : [])
                    }
                    Spacer()
                }.padding(.horizontal, 20).frame(height: 56).insetCard(radius: 28)
                SettingToggle(symbol: "globe", color: .blue.opacity(0.6), title: "country flag...", value: store.binding(\.countryFlag), tint: accent).insetCard(radius: 28).padding(.top, 26)
                Text("Help friends see my country flag and local time when we’re in different countries. Country is approximate and may not always be accurate.")
                    .font(.footnote).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 14)
                SectionLabel(title: "backup")
                SettingsGroup {
                    SettingRow(symbol: "envelope", color: .blue.opacity(0.6), title: store.state.backupEmail.isEmpty ? "add backup email" : store.state.backupEmail) { router.show(.backup) }
                    line
                    SettingRow(symbol: "key", color: .yellow.opacity(0.55), title: "encryption key backup", subtitle: store.state.backupEmail.isEmpty ? "add a backup email first" : "backed up on this device") { router.show(store.state.backupEmail.isEmpty ? .backup : .info("encryption key backup")) }
                    line
                    SettingRow(symbol: "rectangle.portrait.and.arrow.right", color: .green, title: "move to a new device") { router.show(.info("move to a new device")) }
                }
                SectionLabel(title: "support")
                SettingsGroup {
                    SettingRow(symbol: "bubble.left", color: .purple.opacity(0.6), title: "feedback") { router.show(.info("feedback")) }; line
                    SettingRow(symbol: "star", color: .yellow, title: "rate round-log") { router.show(.info("rate round-log")) }; line
                    SettingRow(symbol: "document", color: .gray, title: "terms of service") { router.show(.info("terms of service")) }; line
                    SettingRow(symbol: "hand.raised", color: .blue.opacity(0.6), title: "privacy policy") { router.show(.info("privacy policy")) }
                }
                SectionLabel(title: "camera")
                SettingToggle(symbol: "camera", color: .blue.opacity(0.6), title: "rotate to capture", value: .constant(store.state.rotateToCapture), tint: accent)
                    .disabled(true).opacity(1).insetCard(radius: 28).accessibilityHint("Camera use is unavailable")
                SectionLabel(title: "app")
                SettingsGroup {
                    SettingToggle(symbol: "speaker.wave.2", color: .gray, title: "sound effects", value: store.binding(\.soundEffects), tint: accent); line
                    SettingRow(symbol: "person.crop.circle.badge.xmark", color: .gray, title: "blocked users") { router.show(.blocked) }; line
                    SettingRow(symbol: "externaldrive", color: .gray, title: "clear cache", chevron: false) { router.notify("cache cleared") }
                }
                SettingsGroup { SettingRow(symbol: "rectangle.portrait.and.arrow.right", color: .gray, title: "log out", chevron: false) { confirmation = "log out" } }.padding(.top, 26)
                Button("delete account", role: .destructive) { confirmation = "delete account" }.font(.system(size: 16, weight: .semibold)).padding(.top, 27)
                VStack(spacing: 3) { Text("PIN: local01"); Text("Version 2.8.2 (1)") }.font(.system(size: 12)).foregroundStyle(.gray.opacity(0.55)).padding(.top, 30).padding(.bottom, 26)
            }.padding(.horizontal, 16).padding(.top, 14)
        }.scrollIndicators(.hidden)
            .confirmationDialog(confirmation ?? "", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                Button(confirmation ?? "Reset", role: .destructive) { store.reset(); router.closeAll(); router.path = []; confirmation = nil }
                Button("cancel", role: .cancel) { confirmation = nil }
            } message: { Text("This resets the local demo and its saved changes.") }
    }
    private var line: some View { Divider().padding(.leading, 60).padding(.trailing, 18).opacity(0.5) }
}

struct RoomSettingsView: View {
    let roomID: UUID
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var leaving = false
    var body: some View {
        if let room = store.room(roomID) {
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        RoundButton(symbol: "xmark", label: "Close room settings") { router.close() }
                        Spacer()
                        Button("invite") { router.show(.invite(roomID)) }.font(.system(size: 14, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 7).background(.blue.gradient, in: Capsule())
                    }
                    Button { router.show(.avatar(roomID)) } label: {
                        Face(color: Palette.accent(4), cat: room.avatar == "cat", size: 80).frame(width: 88, height: 88).background(.blue, in: RoundedRectangle(cornerRadius: 23))
                            .overlay(alignment: .bottomTrailing) { Image(systemName: "pencil").font(.system(size: 16)).frame(width: 30, height: 30).softSurface() }
                    }.accessibilityLabel("Edit room avatar").padding(.top, 4).padding(.bottom, 24)
                    Button { router.show(.editRoom(roomID)) } label: { Text(room.name).frame(maxWidth: .infinity).frame(height: 56).overlay(alignment: .trailing) { Image(systemName: "pencil").padding(.trailing, 22) }.insetCard(radius: 28) }
                    SectionLabel(title: "settings")
                    SettingsGroup {
                        SettingToggle(symbol: "bell", color: .orange.opacity(0.65), title: "notifications", value: store.roomBinding(roomID, \.notifications, fallback: true)); line
                        SettingRow(symbol: "person.2", color: .green, title: "room size", value: room.capacity == 20 ? "6–20" : "\(room.capacity)") { router.show(.capacity(roomID)) }; line
                        SettingRow(symbol: "number", color: .blue.opacity(0.6), title: "room code", value: room.code, chevron: false) { UIPasteboard.general.string = room.code; router.notify("room code copied") }; line
                        SettingToggle(symbol: "lock", color: .yellow, title: "room locked", value: store.roomBinding(roomID, \.locked, fallback: false))
                    }
                    Text("When the room is locked, no one else can join.").font(.system(size: 12)).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 8)
                    HStack { SectionLabel(title: "members"); Spacer(); Button("reorder") { router.show(.members(roomID)) }.font(.system(size: 13)).foregroundStyle(.blue) }.padding(.trailing, 14)
                    SettingsGroup {
                        ForEach(room.members) { member in
                            Button { router.show(.member(roomID, member.id)) } label: {
                                HStack(spacing: 12) { PersonAvatar(person: member, size: 30, colored: true); Text(member.name); Spacer(); if member.id == DemoState.meID { Text("you").font(.subheadline).foregroundStyle(Palette.secondary) }; Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.gray.opacity(0.5)) }.padding(.horizontal, 16).frame(minHeight: 55)
                            }
                        }
                        Button { router.show(.invite(roomID)) } label: { HStack(spacing: 12) { Image(systemName: "plus").frame(width: 28, height: 28).background(.black.opacity(0.05), in: Circle()); Text("invite"); Spacer() }.foregroundStyle(.gray).padding(.horizontal, 16).frame(minHeight: 54) }
                    }
                    SettingsGroup {
                        SettingRow(symbol: "archivebox", color: .orange.opacity(0.6), title: "view archive") { router.open(.archive(roomID)) }; line
                        SettingRow(symbol: "square.and.arrow.up", color: .gray, title: "export") { router.show(.export(roomID)) }
                    }.padding(.top, 25)
                    SectionLabel(title: "layout")
                    SettingsGroup {
                        SettingToggle(symbol: "rectangle.on.rectangle", color: .pink.opacity(0.5), title: "classic layout", value: store.roomBinding(roomID, \.classic, fallback: true)); line
                        SettingRow(symbol: "rectangle.split.3x1", color: .purple.opacity(0.6), title: "layout", value: room.layout) { router.show(.layout(roomID)) }
                    }
                    Text("Vertical videos will be cropped.").font(.system(size: 12)).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 8)
                    SettingsGroup { SettingRow(symbol: "rectangle.portrait.and.arrow.right", color: .gray, title: "leave room", chevron: false) { leaving = true } }.padding(.top, 24).padding(.bottom, 26)
                }.padding(.horizontal, 16).padding(.top, 14)
            }.scrollIndicators(.hidden)
                .confirmationDialog("leave \(room.name)?", isPresented: $leaving, titleVisibility: .visible) {
                    Button("leave room", role: .destructive) { store.leaveRoom(roomID); router.closeAll(); router.path = [] }
                }
        }
    }
    private var line: some View { Divider().padding(.leading, 60).padding(.trailing, 18).opacity(0.5) }
}

struct EditNameView: View {
    var roomID: UUID?
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 20) {
            HStack { RoundButton(symbol: "xmark", label: "Cancel") { router.close() }; Spacer(); Text(roomID == nil ? "your name" : "room name").font(.headline); Spacer(); RoundButton(symbol: "checkmark", label: "Save name", filled: true, tint: .blue) { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.padding(.horizontal, 16).padding(.top, 14)
            TextField("name", text: $name).textInputAutocapitalization(.words).submitLabel(.done).onSubmit(save).focused($focused).padding(18).insetCard().padding(.horizontal, 22).accessibilityIdentifier("name-input")
            Spacer(minLength: 0)
        }.onAppear { name = roomID.flatMap(store.room)?.name ?? store.state.profile.name; focused = true }
    }
    private func save() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let roomID { store.updateRoom(roomID) { $0.name = value } } else { store.updateProfile(name: value) }
        dismissKeyboard(); router.close()
    }
}

struct AvatarPicker: View {
    var roomID: UUID?
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    var body: some View {
        VStack {
            SheetHeading(title: "avatar")
            HStack(spacing: 35) {
                ForEach(["face", "cat"], id: \.self) { avatar in
                    Button {
                        if let roomID { store.updateRoom(roomID) { $0.avatar = avatar } } else { store.updateProfile(avatar: avatar) }
                        router.close()
                    } label: { Face(color: Palette.accent(store.state.profile.color), cat: avatar == "cat", size: 76).padding(14).insetCard(radius: 30) }.accessibilityLabel(avatar)
                }
            }.padding(.vertical, 22)
            Spacer(minLength: 0)
        }
    }
}

struct MembersView: View {
    let roomID: UUID
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "reorder members")
            List {
                ForEach(store.room(roomID)?.members ?? []) { person in HStack(spacing: 14) { PersonAvatar(person: person, colored: true); Text(person.name) }.listRowBackground(Palette.card) }
                    .onMove { source, destination in
                        store.updateRoom(roomID) { room in room.members.move(fromOffsets: source, toOffset: destination) }
                    }
            }.scrollContentBackground(.hidden).environment(\.editMode, .constant(.active))
        }
    }
}

struct MemberView: View {
    let roomID: UUID
    let personID: UUID
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    var body: some View {
        VStack(spacing: 24) {
            SheetHeading(title: "profile")
            if let person = store.room(roomID)?.members.first(where: { $0.id == personID }) {
                PersonAvatar(person: person, size: 90, colored: true)
                Text(person.name).font(.title2.weight(.medium))
                if person.id == DemoState.meID { Button("edit profile") { router.show(.editProfile) } }
                else {
                    Button("block user", role: .destructive) {
                        store.update { state in if !state.blocked.contains(where: { $0.id == personID }) { state.blocked.append(person) } }
                        router.close(); router.notify("user blocked")
                    }
                }
            }
            Spacer()
        }
    }
}

struct BlockedView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack {
            SheetHeading(title: "blocked users")
            if store.state.blocked.isEmpty { Spacer(); Image(systemName: "person.crop.circle.badge.checkmark").font(.largeTitle).foregroundStyle(.gray.opacity(0.4)); Text("no blocked users").foregroundStyle(Palette.secondary); Spacer() }
            else { List { ForEach(store.state.blocked) { person in HStack { PersonAvatar(person: person); Text(person.name); Spacer(); Button("unblock") { store.update { $0.blocked.removeAll { $0.id == person.id } } }.foregroundStyle(.blue) }.listRowBackground(Palette.card) } }.scrollContentBackground(.hidden) }
        }
    }
}

struct QRView: View {
    var roomID: UUID?
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(spacing: 24) {
            SheetHeading(title: roomID == nil ? "your code" : "room code")
            if let image = qr { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 230, maxHeight: 230).padding(20).background(.white, in: RoundedRectangle(cornerRadius: 28)).accessibilityLabel("Local invitation QR code") }
            Text(roomID.flatMap(store.room)?.code ?? "local01").font(.title3.monospaced().weight(.medium))
            Spacer(minLength: 0)
        }
    }
    private var qr: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("round-log://\(roomID == nil ? "profile/local01" : "join/" + (roomID.flatMap(store.room)?.code ?? ""))".utf8)
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output.transformed(by: .init(scaleX: 8, y: 8)), from: output.extent.applying(.init(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: cg)
    }
}

func dismissKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }

struct SheetHeading: View {
    let title: String
    @Environment(AppRouter.self) private var router
    var body: some View { HStack { RoundButton(symbol: "xmark", label: "Close \(title)") { dismissKeyboard(); router.close() }; Spacer(); Text(title).font(.system(size: 18, weight: .semibold)); Spacer(); Color.clear.frame(width: 44, height: 44) }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10) }
}
