import Foundation

/// TASK-377 (v1.9.4): Pure cross-platform contract for the 6-step Live Share update frequency
/// battery-aware slider (parity with Android `LiveShareFrequencySliderPolicy.kt`).
///
/// Positions are evenly spaced from less frequent (index 0 = 5 minutes, less battery use)
/// to more frequent (index 5 = 5 seconds, more frequent updates).
enum LiveShareFrequencySliderPolicy {
    static let prefKey: String = "liveShareFrequency"
    static let defaultSeconds: Int = 15

    /// Ordered from less frequent (left) to more frequent (right).
    static let stepsSeconds: [Int] = [300, 60, 30, 15, 10, 5]

    static var stepCount: Int { stepsSeconds.count }
    static var maxIndex: Int { stepsSeconds.count - 1 }
    static var defaultIndex: Int { stepsSeconds.firstIndex(of: defaultSeconds) ?? 3 }

    /// Maps a persisted interval in seconds to its stepped slider index `0...5`.
    /// Non-positive values fall back to `defaultIndex` (15 seconds); non-standard positive values
    /// snap to the nearest supported step so legacy/manual prefs stay valid.
    static func index(forSeconds seconds: Int) -> Int {
        guard seconds > 0 else { return defaultIndex }
        if let exact = stepsSeconds.firstIndex(of: seconds) {
            return exact
        }
        return stepsSeconds.indices.min(by: { abs(stepsSeconds[$0] - seconds) < abs(stepsSeconds[$1] - seconds) })
            ?? defaultIndex
    }

    /// Rounds and clamps a raw slider value onto one of the 6 supported intervals in seconds.
    static func seconds(forSliderValue value: Double) -> Int {
        guard value.isFinite else { return defaultSeconds }
        let clamped = min(max(Int(value.rounded()), 0), maxIndex)
        return stepsSeconds[clamped]
    }

    /// Clamps an integer step index onto one of the 6 supported intervals in seconds.
    static func seconds(forIndex index: Int) -> Int {
        let clamped = min(max(index, 0), maxIndex)
        return stepsSeconds[clamped]
    }
}
