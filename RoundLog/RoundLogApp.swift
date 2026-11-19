import SwiftUI

enum Screen: Hashable { case room(UUID), chat(UUID, zoom: Bool = true), archive(UUID) }
enum Modal {
    case profile, activity, create(Bool), join, roomSettings(UUID), calendar(UUID), export(UUID), preview(UUID)
    case editProfile, editRoom(UUID), capacity(UUID), members(UUID), member(UUID, UUID), invite(UUID), avatar(UUID?)
    case caption(UUID, Date, Int), reactions(UUID), layout(UUID), background, qr(UUID?), info(String), backup, blocked
}
struct PresentedSheet: Identifiable { let id = UUID(); var kind: Modal }

@Observable final class AppRouter {
    var path: [Screen] = []
    var sheets: [PresentedSheet] = []
    var days: [UUID: Date] = [:]
    var hours: [UUID: Int] = [:]
    var safeInsets = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)
    var toast: String?
    var activityButtonFrame = CGRect.zero
    var displayCornerRadius: CGFloat = 0
    var activityPresented: Bool { sheets.contains { if case .activity = $0.kind { return true }; return false } }
    func show(_ modal: Modal) { withAnimation(Motion.sheet) { sheets.append(PresentedSheet(kind: modal)) } }
    func close() { withAnimation(Motion.dismiss) { if !sheets.isEmpty { sheets.removeLast() } } }
    func closeAll() { withAnimation(Motion.dismiss) { sheets.removeAll() } }
    func push(_ screen: Screen) { withAnimation(Motion.navigation) { path.append(screen) } }
    func open(_ screen: Screen) {
        closeAll()
        if case .chat(let id, _) = screen { push(.chat(id, zoom: false)) }
        else { push(screen) }
    }
    func back() { withAnimation(Motion.navigation) { if !path.isEmpty { path.removeLast() } } }
    func notify(_ message: String) {
        withAnimation(.smooth(duration: 0.2)) { toast = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { withAnimation { toast = nil } }
        }
    }
}

@main struct RoundLogApp: App {
    @State private var store = AppStore()
    @State private var router = AppRouter()
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).environment(router).preferredColorScheme(.light)
                .tint(Palette.accent(store.state.profile.color))
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Namespace private var zoom
    @State private var safeTop: CGFloat = 47
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        @Bindable var router = router
        ZStack {
            Palette.background.ignoresSafeArea()
            NavigationStack(path: $router.path) {
                HomeView(namespace: zoom)
                    .navigationDestination(for: Screen.self) { screen in
                        switch screen {
                        case .room(let id): RoomView(roomID: id, namespace: zoom).navigationTransition(.zoom(sourceID: id, in: zoom))
                        case .chat(let id, let usesZoom):
                            if usesZoom && !reduceMotion {
                                ChatView(roomID: id).navigationTransition(.zoom(sourceID: "chat-\(id)", in: zoom))
                            } else { ChatView(roomID: id) }
                        case .archive(let id): ArchiveView(roomID: id)
                        }
                    }
            }.ignoresSafeArea(.keyboard, edges: .bottom).accessibilityHidden(!router.sheets.isEmpty)
            ModalHost(topInset: safeTop)
            if router.path.isEmpty && (router.sheets.isEmpty || router.activityPresented) {
                RoundButton(symbol: router.activityPresented ? "xmark" : "bell", label: router.activityPresented ? "Close activity" : "Activity", size: 48) {
                    if router.activityPresented { router.close() } else { router.show(.activity) }
                }
                .accessibilityIdentifier("activity")
                .position(x: router.activityButtonFrame.midX, y: router.activityButtonFrame.midY - safeTop)
                .zIndex(100)
            }
            if let toast = router.toast {
                VStack { Spacer(); Text(toast).font(.subheadline.weight(.medium)).padding(.horizontal, 22).padding(.vertical, 14)
                    .background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.08), radius: 15, y: 6).padding(.bottom, 100) }
                    .allowsHitTesting(false).transition(.opacity).accessibilityLabel(toast)
            }
        }
        .coordinateSpace(name: "app")
        .foregroundStyle(Palette.ink)
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
            if $0.top > 0 { safeTop = $0.top; router.safeInsets = $0 }
        }
        .background(ScreenEdgeOverlay(color: Palette.accent(store.state.profile.color)) { router.displayCornerRadius = $0 })
        .animation(reduceMotion ? .none : .smooth(duration: 0.25), value: store.state.profile.color)
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--screen"), args.indices.contains(index + 1) else { return }
            let id = DemoState.friendsID
            switch args[index + 1] {
            case "vlog": router.path = [.room(DemoState.vlogID)]
            case "caption": router.path = [.room(DemoState.vlogID)]; router.show(.caption(DemoState.vlogID, LogDay.start(containing: store.now), Calendar.current.component(.hour, from: store.now)))
            case "room": router.path = [.room(id)]
            case "history": router.days[id] = LogDay.start(containing: Calendar.current.date(byAdding: .day, value: -1, to: store.now)!); router.hours[id] = 12; router.path = [.room(id)]
            case "chat": router.path = [.room(id), .chat(id)]
            case "profile": router.show(.profile)
            case "activity": router.show(.activity)
            case "create": router.show(.create(false))
            case "join": router.show(.join)
            case "settings": router.path = [.room(id)]; router.show(.roomSettings(id))
            case "calendar": router.path = [.room(id)]; router.show(.calendar(id))
            case "export": router.path = [.room(id)]; router.show(.export(id))
            case "archive": router.path = [.room(id), .archive(id)]
            default: break
            }
        }
        .alert("Couldn’t save the demo", isPresented: Binding(get: { store.storageError != nil }, set: { if !$0 { store.storageError = nil } })) {
            Button("Try again") { store.storageError = nil; store.save() }
            Button("Keep exploring", role: .cancel) { store.storageError = nil }
        } message: { Text(store.storageError ?? "") }
    }
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    var namespace: Namespace.ID
    @State private var showingCamera = false
    @Namespace private var tabs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $showingCamera) {
                Palette.background.accessibilityLabel("Blank camera preview").accessibilityIdentifier("camera-preview")
                    .accessibilityHidden(!showingCamera).tag(true)
                ScrollView {
                    VStack(spacing: 0) {
                        HStack(spacing: 9) {
                            Face(color: Palette.accent(store.state.profile.color), size: 18)
                            Text("rotate to capture").referenceFont(16).foregroundStyle(Palette.secondary)
                            Spacer()
                        }.padding(.horizontal, 14).frame(height: 30).padding(.bottom, 20)
                        if let vlog = store.state.rooms.first(where: \.isVlog) {
                            NavigationLink(value: Screen.room(vlog.id)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("vlog").referenceFont(20, weight: .medium)
                                        Text("your space. each day runs 4am\nto 4am.").referenceFont(14).foregroundStyle(Palette.secondary).multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 8); StarMark().frame(width: 52, height: 52)
                                }.padding(.horizontal, 23).frame(minHeight: 94).insetCard(radius: 25)
                            }.buttonStyle(PressStyle()).matchedTransitionSource(id: vlog.id, in: namespace).accessibilityIdentifier("vlog")
                        }
                        let rooms = store.state.rooms.filter { !$0.isVlog }
                        VStack(spacing: 6) {
                            ForEach(Array(rooms.enumerated()), id: \.element.id) { index, room in
                                NavigationLink(value: Screen.room(room.id)) {
                                    HStack(spacing: 14) {
                                        PersonAvatar(person: room.members.first ?? store.state.profile, size: 46)
                                            .frame(width: 50, height: 50).overlay(RoundedRectangle(cornerRadius: index == 0 ? 25 : 15).stroke(.black.opacity(0.06)))
                                        Text(room.name).referenceFont(18, weight: .medium).lineLimit(2)
                                        Spacer(minLength: 4)
                                        if room.members.count > 1 { VStack(spacing: 3) { Circle().fill(.black.opacity(0.08)); Circle().fill(.black.opacity(0.08)) }.frame(width: 7, height: 17).padding(.trailing, 4) }
                                        Face(size: 28)
                                        Image(systemName: "chevron.right").font(.system(size: 16, weight: .medium)).padding(.leading, 7)
                                    }.padding(.horizontal, 14).frame(minHeight: 74).insetCard(radius: 28)
                                }.buttonStyle(PressStyle()).matchedTransitionSource(id: room.id, in: namespace)
                                    .accessibilityIdentifier(index == 1 ? "friends-room" : "room-\(index)")
                                    .padding(.bottom, index == 0 ? 10 : 0)
                            }
                        }.padding(.top, 16)
                    }.padding(.horizontal, 16).padding(.top, 72).padding(.bottom, 24)
                }.scrollIndicators(.hidden).accessibilityIdentifier("home-content")
                    .accessibilityHidden(showingCamera).tag(false)
            }.tabViewStyle(.page(indexDisplayMode: .never))
                .overlay(alignment: .top) { header }
            HStack {
                Color.clear.frame(width: 48, height: 48)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("app")) } action: { router.activityButtonFrame = $0 }
                Spacer(minLength: 20)
                HStack(spacing: 0) {
                    homeTab("camera", selected: showingCamera, width: 78) { showingCamera = true }
                    homeTab("logs", selected: !showingCamera, width: 70) { showingCamera = false }
                }.buttonStyle(.plain).padding(5).glassPill()
                Spacer(minLength: 20)
                Menu {
                    Button("create a room") { router.show(.create(false)) }.buttonStyle(.automatic).accessibilityIdentifier("create-room")
                    Button("join with code") { router.show(.join) }.buttonStyle(.automatic).accessibilityIdentifier("join-room")
                    Divider()
                    Button("start a zip") { router.show(.create(true)) }.buttonStyle(.automatic).accessibilityIdentifier("create-zip")
                } label: {
                    Image(systemName: "plus").font(.system(size: 23)).frame(width: 34, height: 34)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle).menuOrder(.fixed)
                .accessibilityLabel("Create or join a room").accessibilityIdentifier("creation-menu")
            }.padding(.horizontal, 36).padding(.top, 12).padding(.bottom, 16)
        }.background(Palette.background).toolbar(.hidden, for: .navigationBar)
    }
    private func homeTab(_ title: String, selected: Bool, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9)) { action() }
        } label: {
            Text(title).font(.system(size: 17, weight: selected ? .medium : .regular))
                .frame(width: width, height: 40)
                .contentShape(Rectangle())
                .background {
                    if selected { Capsule().fill(.black.opacity(0.08)).matchedGeometryEffect(id: "home-tab", in: tabs) }
                }
        }.accessibilityIdentifier("tab-\(title)").accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var header: some View {
        HStack {
            Image("Wordmark").resizable().scaledToFit().frame(width: 80, height: 32)
                .accessibilityLabel("RoundLog").accessibilityIdentifier("wordmark")
            Spacer()
            Button { router.show(.profile) } label: {
                PersonAvatar(person: store.state.profile, size: 24).frame(width: 44, height: 44).softSurface()
            }.buttonStyle(PressStyle()).accessibilityLabel("Profile and settings").accessibilityIdentifier("profile")
        }
        .padding(.horizontal, 30).frame(height: 72)
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.65), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .padding(.bottom, -22).ignoresSafeArea(edges: .top)
        }
    }
}

struct ModalHost: View {
    var topInset: CGFloat
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            // Keep the host alive: scrim and panels must be independent inserted views.
            ZStack {
                if let top = router.sheets.last {
                    Color.black.opacity(isCalendar(top.kind) ? 0.20 : 0.035)
                        .contentShape(Rectangle())
                        .onTapGesture { dismissKeyboard(); router.close() }
                        .accessibilityLabel("Dismiss sheet")
                        .transition(.opacity)
                        .zIndex(0)
                }
                ForEach(Array(router.sheets.enumerated()), id: \.element.id) { index, sheet in
                    let floating = isFloating(sheet.kind)
                    let maxHeight = max(200, geometry.size.height - topInset - 36)
                    let panelHeight = min(height(sheet.kind, total: geometry.size.height, width: geometry.size.width, maximum: maxHeight), maxHeight)
                    let panelWidth = min(sheetWidth(sheet.kind), geometry.size.width - horizontalInset(sheet.kind) * 2)
                    let centerY = floating ? geometry.size.height / 2 + verticalOffset(sheet.kind) : geometry.size.height - bottomInset(sheet.kind) - panelHeight / 2
                    let travel = geometry.size.height - centerY + panelHeight / 2 + 48
                    let isTop = index == router.sheets.count - 1
                    if index > 0 {
                        Color.black.opacity(0.035)
                            .contentShape(Rectangle())
                            .onTapGesture { dismissKeyboard(); router.close() }
                            .transition(.opacity)
                            .zIndex(Double(index) + 0.5)
                            .allowsHitTesting(isTop)
                            .accessibilityHidden(true)
                    }
                    ModalPanel(sheet: sheet, height: panelHeight, radius: floating || isCaption(sheet.kind) ? sheetRadius(sheet.kind) : max(sheetRadius(sheet.kind), router.displayCornerRadius - horizontalInset(sheet.kind)))
                        .frame(width: panelWidth, height: panelHeight)
                        .transition(reduceMotion ? .opacity : .modifier(
                            active: SheetMotion(progress: 0, travel: travel, expands: floating),
                            identity: SheetMotion(progress: 1, travel: travel, expands: floating)))
                        .position(x: geometry.size.width / 2, y: centerY)
                        .zIndex(Double(index + 1))
                        .allowsHitTesting(isTop)
                        .accessibilityHidden(!isTop)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.ignoresSafeArea(.container)
    }
}

private struct ModalPanel: View {
    let sheet: PresentedSheet
    let height: CGFloat
    let radius: CGFloat
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0
    @State private var dragOrigin: CGFloat = 0
    @State private var dragging = false
    @State private var presentation = SheetDragPresentation()

    var body: some View {
        ModalContent(kind: sheet.kind)
            .buttonStyle(PressStyle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .background(Palette.background.opacity(0.92))
            .clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(radius)), isUniform: true))
            .overlay(ConcentricRectangle(corners: .concentric(minimum: .fixed(radius)), isUniform: true).stroke(.white.opacity(0.65), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
            .modifier(SheetDragOffset(offset: drag, presentation: presentation))
            .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .local)
                .onChanged { value in
                    guard value.startLocation.y < 66 else { return }
                    // Finger tracking stays direct. Upward resistance has no hard stop.
                    if !dragging { dragOrigin = presentation.offset; dragging = true }
                    let distance = dragOrigin + value.translation.height
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { drag = distance >= 0 ? distance : -sqrt(-distance) * 2 }
                }
                .onEnded { value in
                    guard value.startLocation.y < 66 else { return }
                    dragging = false
                    let projected = value.predictedEndTranslation.height
                    if drag > height * 0.23 || (drag > 18 && projected > height * 0.48) {
                        // Preserve the current offset while the reverse transition leaves.
                        dismissKeyboard()
                        router.close()
                    } else {
                        let velocity = value.velocity.height / max(abs(drag), 1)
                        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .interpolatingSpring(stiffness: 430, damping: 39, initialVelocity: -velocity)) { drag = 0 }
                    }
                })
    }
}
