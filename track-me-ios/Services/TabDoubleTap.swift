import Foundation

/// TASK-226: recognises a double-tap on a bottom-navigation item.
///
/// Deliberately *retrospective*. The obvious implementation waits out a timeout on every tap to see
/// whether a second one arrives, which taxes the common single tap with a delay it never had — and
/// a single tap is what almost every tap is. Here the first tap acts immediately and unchanged; the
/// second one, if it lands inside the window, does the extra work on top. Nothing is ever deferred.
///
/// Held as a plain value so the rule is testable without a tab bar. Mirrors the Android
/// `TabDoubleTapDetector` so the gesture has one definition across the two platforms.
struct TabDoubleTapDetector: Equatable {
    /// The system double-tap interval. iOS does not expose one the way Android's
    /// `ViewConfiguration` does, so this is Android's value, which keeps the two in step.
    static let defaultWindow: TimeInterval = 0.3

    private let window: TimeInterval
    private var lastIndex: Int?
    private var lastTapAt: TimeInterval = 0

    init(window: TimeInterval = TabDoubleTapDetector.defaultWindow) {
        self.window = window
    }

    /// Records a tap and reports whether it completed a pair.
    mutating func tap(index: Int, now: TimeInterval) -> Bool {
        let isDoubleTap = index == lastIndex && lastTapAt > 0 && now - lastTapAt <= window
        lastIndex = index
        // A recognised pair is consumed: three taps in a second are one double-tap and one single,
        // not two double-taps.
        lastTapAt = isDoubleTap ? 0 : now
        return isDoubleTap
    }
}
