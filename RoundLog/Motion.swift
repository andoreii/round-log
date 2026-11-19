import SwiftUI

/// Timings sampled from the supplied Setlog recordings at 25-ms intervals.
enum Motion {
    static var sheet: Animation { UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.90) }
    static var dismiss: Animation { UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.16) : .spring(response: 0.24, dampingFraction: 0.92) }
    static var navigation: Animation { UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.18) : .spring(response: 0.35, dampingFraction: 0.90) }
}

/// The sheet remains rendered and opaque while rising and expanding from below
/// the display. A single progress value makes reversal follow the same path.
struct SheetMotion: AnimatableModifier {
    var progress: CGFloat
    var travel: CGFloat
    var expands = false
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: expands ? 0.38 + 0.62 * progress : 1, y: expands ? 0.18 + 0.82 * progress : 1)
            .offset(y: travel * (1 - progress))
    }
}

/// A non-observable presentation sample lets a new drag pick up an interrupted
/// spring at its visible position, without starting a second rendering loop.
final class SheetDragPresentation {
    var offset: CGFloat = 0
}

struct SheetDragOffset: AnimatableModifier {
    var offset: CGFloat
    let presentation: SheetDragPresentation
    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }
    func body(content: Content) -> some View {
        presentation.offset = offset
        return content.offset(y: offset)
    }
}
