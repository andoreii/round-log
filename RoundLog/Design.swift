import SwiftUI
import AVFoundation

enum Palette {
    static let background = Color(white: 0.965)
    static let card = Color(white: 0.925)
    static let ink = Color(white: 0.025)
    static let secondary = Color(white: 0.47)
    static let accents: [Color] = [.init(red: 0.03, green: 0.79, blue: 0.88), .init(red: 1, green: 0.49, blue: 0.31), .init(red: 0.76, green: 0.40, blue: 0.98), .init(red: 0.51, green: 1, blue: 0.28), .init(red: 0.22, green: 0.48, blue: 0.97), .init(red: 0.95, green: 0.43, blue: 0.98)]
    static func accent(_ index: Int) -> Color { accents[max(0, min(index, accents.count - 1))] }
}

struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.94 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(
                reduceMotion ? .linear(duration: 0.08) :
                    (configuration.isPressed ? .easeOut(duration: 0.08) : .spring(response: 0.28, dampingFraction: 0.78)),
                value: configuration.isPressed
            )
    }
}

struct SoftSurface: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.glassEffect(
            .regular.interactive(isEnabled && !reduceMotion),
            in: RoundedRectangle(cornerRadius: 100, style: .continuous)
        )
    }
}

struct GlassPill: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.glassEffect(.regular.interactive(isEnabled && !reduceMotion), in: Capsule())
    }
}

extension View {
    func softSurface() -> some View { modifier(SoftSurface()) }
    func glassPill() -> some View { modifier(GlassPill()) }
    func insetCard(radius: CGFloat = 24) -> some View { background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous)) }
    func referenceFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View { modifier(ReferenceFont(size: size, weight: weight)) }
}
private struct ReferenceFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    var weight: Font.Weight
    init(size: CGFloat, weight: Font.Weight) { _size = ScaledMetric(wrappedValue: size, relativeTo: .body); self.weight = weight }
    func body(content: Content) -> some View { content.font(.system(size: size, weight: weight)) }
}
extension AppStore {
    func binding<Value>(_ keyPath: WritableKeyPath<DemoState, Value>) -> Binding<Value> {
        Binding(get: { self.state[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
    func roomBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<Room, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { self.room(id)?[keyPath: keyPath] ?? fallback }, set: { value in self.updateRoom(id) { $0[keyPath: keyPath] = value } })
    }
}

struct RoundButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 44
    var filled = false
    var tint: Color = Palette.ink
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if filled {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: size > 44 ? 23 : 21)).foregroundStyle(.white)
                    .frame(width: size - 14, height: size - 14)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.circle).tint(tint)
            .frame(width: size, height: size)
            .accessibilityLabel(label)
        } else {
            Button(action: action) {
                Image(systemName: symbol).contentTransition(.symbolEffect(.replace)).font(.system(size: size > 44 ? 23 : 21)).foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .glassEffect(.regular.interactive(isEnabled && !reduceMotion), in: Circle())
                    .contentShape(Circle())
            }.buttonStyle(PressStyle()).accessibilityLabel(label)
        }
    }
}

struct Face: View {
    var color: Color = .white
    var cat = false
    var size: CGFloat = 36
    var body: some View {
        Canvas { context, canvas in
            let scale = min(canvas.width, canvas.height) / 64
            context.scaleBy(x: scale, y: scale)
            if cat {
                var body = Path()
                body.move(to: CGPoint(x: 16, y: 27)); body.addLine(to: CGPoint(x: 15, y: 17))
                body.addQuadCurve(to: CGPoint(x: 25, y: 21), control: CGPoint(x: 19, y: 13))
                body.addQuadCurve(to: CGPoint(x: 34, y: 21), control: CGPoint(x: 29, y: 17))
                body.addQuadCurve(to: CGPoint(x: 41, y: 32), control: CGPoint(x: 45, y: 14))
                body.addCurve(to: CGPoint(x: 46, y: 48), control1: CGPoint(x: 57, y: 29), control2: CGPoint(x: 61, y: 48))
                body.addQuadCurve(to: CGPoint(x: 18, y: 47), control: CGPoint(x: 31, y: 51))
                body.addQuadCurve(to: CGPoint(x: 16, y: 27), control: CGPoint(x: 10, y: 39))
                context.fill(body, with: .color(.black))
                var tail = Path(); tail.move(to: CGPoint(x: 47, y: 42))
                tail.addCurve(to: CGPoint(x: 58, y: 25), control1: CGPoint(x: 61, y: 43), control2: CGPoint(x: 60, y: 32))
                context.stroke(tail, with: .color(.black), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                for x in [22.0, 30.0] { context.fill(Path(ellipseIn: CGRect(x: x, y: 29, width: 2.5, height: 3)), with: .color(.white)) }
            } else {
                context.fill(Path(ellipseIn: CGRect(x: 1, y: 1, width: 62, height: 62)), with: .color(color))
                var arc = Path(); arc.move(to: CGPoint(x: 9, y: 31))
                arc.addCurve(to: CGPoint(x: 55, y: 31), control1: CGPoint(x: 12, y: 1), control2: CGPoint(x: 52, y: 1))
                context.stroke(arc, with: .color(.black), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                for x in [21.0, 39.0] { context.fill(Path(ellipseIn: CGRect(x: x, y: 36, width: 4, height: 8)), with: .color(.black)) }
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct PersonAvatar: View {
    var person: Person
    var size: CGFloat = 30
    var colored = false
    var body: some View { Face(color: colored ? Palette.accent(person.color) : Palette.background, cat: person.avatar == "cat", size: size) }
}

struct StarMark: View {
    var size: CGFloat = 52
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 52, y: size.height / 52)
            var star = Path()
            for index in 0..<10 {
                let angle = Double(index) * .pi / 5 - .pi / 2
                let radius = index.isMultiple(of: 2) ? 18.0 : 10.5
                let point = CGPoint(x: 26 + cos(angle) * radius, y: 26 + sin(angle) * radius)
                if index == 0 { star.move(to: point) } else { star.addLine(to: point) }
            }
            star.closeSubpath(); context.fill(star, with: .color(Color(red: 1, green: 0.96, blue: 0.65)))
            context.stroke(star, with: .color(.black), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            for x in [22.0, 28.0] { context.fill(Path(ellipseIn: CGRect(x: x, y: 22, width: 1.7, height: 4)), with: .color(.black)) }
            context.stroke(Path(ellipseIn: CGRect(x: 24, y: 29, width: 5, height: 3.5)), with: .color(.black), lineWidth: 1.3)
            for index in 0..<7 {
                let angle = Double(index) * .pi * 2 / 7
                var ray = Path(); ray.move(to: CGPoint(x: 26 + cos(angle) * 23, y: 26 + sin(angle) * 23))
                ray.addLine(to: CGPoint(x: 26 + cos(angle) * 27, y: 26 + sin(angle) * 27))
                context.stroke(ray, with: .color(.black), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct FloatingFace: View {
    var seed: Int
    var testing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || testing)) { timeline in
                let time = testing || reduceMotion ? Double(seed) : timeline.date.timeIntervalSinceReferenceDate
                let phase = time * 0.55 + Double(seed) * 2.1
                Face(color: Color(hue: (phase * 0.11).truncatingRemainder(dividingBy: 1).magnitude, saturation: 0.65, brightness: 0.98), size: 58)
                    .rotationEffect(.degrees(sin(phase) * 18))
                    .position(x: geometry.size.width * (0.5 + 0.32 * sin(phase * 0.73)), y: geometry.size.height * (0.51 + 0.28 * cos(phase * 0.91)))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct SettingRow: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var chevron = true
    var swatch: Color? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.white).frame(width: 28, height: 28)
                    .background(color, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Palette.ink)
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondary) }
                }
                Spacer(minLength: 4)
                if let value { Text(value).font(.subheadline).foregroundStyle(Palette.secondary) }
                if let swatch { Circle().fill(swatch).frame(width: 28, height: 28) }
                if chevron { Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium)).foregroundStyle(.gray.opacity(0.5)) }
            }.padding(.horizontal, 18).padding(.vertical, 13).frame(minHeight: 54).contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }
}

struct SettingToggle: View {
    let symbol: String
    let color: Color
    let title: String
    @Binding var value: Bool
    var tint: Color = .blue
    var body: some View {
        Toggle(isOn: $value) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.white).frame(width: 28, height: 28)
                    .background(color, in: RoundedRectangle(cornerRadius: 7))
                Text(title)
            }
        }.tint(tint).padding(.horizontal, 18).frame(minHeight: 56)
    }
}
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(spacing: 0) { content }.insetCard(radius: 25) }
}
struct SectionLabel: View {
    let title: String
    var body: some View { Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 16).padding(.top, 16).padding(.bottom, 8) }
}

struct LoopPlayer: UIViewRepresentable {
    var name: String
    var paused = false
    var rate: Float = 1
    func makeUIView(context: Context) -> LoopSurface { LoopSurface() }
    func updateUIView(_ view: LoopSurface, context: Context) { view.configure(name: name, paused: paused, rate: rate) }
    static func dismantleUIView(_ view: LoopSurface, coordinator: ()) { view.player?.pause() }
}
final class LoopSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentName = ""
    private var shouldPause = false
    private var playbackRate: Float = 1
    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { player?.pause() } else if !shouldPause { player?.playImmediately(atRate: playbackRate) }
    }
    func configure(name: String, paused: Bool, rate: Float) {
        shouldPause = paused
        playbackRate = rate
        if currentName != name {
            currentName = name
            guard let url = Bundle.main.url(forResource: name, withExtension: "mp4") else { return }
            let queue = AVQueuePlayer(); queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url)); player = queue
            (layer as? AVPlayerLayer)?.player = queue; (layer as? AVPlayerLayer)?.videoGravity = .resizeAspectFill
        }
        if paused { player?.pause() } else { player?.playImmediately(atRate: rate) }
    }
    @objc private func background() { player?.pause() }
    @objc private func foreground() { if !shouldPause && window != nil { player?.playImmediately(atRate: playbackRate) } }
}
