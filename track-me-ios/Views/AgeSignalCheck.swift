//
//  AgeSignalCheck.swift
//  track-me-ios
//
//  TASK-288. The one place in the app allowed to name a `DeclaredAgeRange` symbol.
//

import SwiftUI
import DeclaredAgeRange

extension View {
    /// Runs the one-shot age-signal check that gates the app's root view.
    ///
    /// **This must run on every OS version, not only on iOS 26.**
    ///
    /// `ContentView` renders `AgeSignalCheckingView()` for as long as
    /// `AgeSignalManager.shared.decision` is nil. Skipping the check below iOS 26 — the obvious
    /// reading of "the framework isn't available here" — would leave every iOS 17–25 device
    /// parked on that loading screen forever, which is precisely the population lowering the
    /// deployment floor exists to serve. Lowering the floor without this is shipping a brick.
    ///
    /// So the check always runs. Only the *source of the signal* is version-dependent: iOS 26
    /// asks Apple, and everything older reports `.noSignal`, which `AgeSignalManager` resolves to
    /// `.unknown` → `.allowed`. That is the identical outcome the old
    /// `guard #available(iOS 26.0, *) else { return .unknown }` produced inside the manager.
    @ViewBuilder
    func ageSignalCheck() -> some View {
        if #available(iOS 26.0, *) {
            modifier(DeclaredAgeRangeSignalModifier())
        } else {
            task { await AgeSignalManager.shared.checkAndPersist { _ in .noSignal } }
        }
    }
}

/// Holds the iOS 26-only environment action. It lives in its own `@available`-annotated type
/// because a stored `@Environment(\.requestAgeRange)` property cannot be conditionally compiled
/// inside a view that also has to build for iOS 17.
@available(iOS 26.0, *)
private struct DeclaredAgeRangeSignalModifier: ViewModifier {
    @Environment(\.requestAgeRange) private var requestAgeRange

    func body(content: Content) -> some View {
        content.task {
            await AgeSignalManager.shared.checkAndPersist { gate in
                // Apple's response type is mapped to the domain type here, at the boundary, so it
                // never reaches AgeSignalManager — that is what keeps the manager buildable below
                // iOS 26. A nil lowerBound means "below the lowest gate requested", which the
                // manager treats as a declared minor; anything that is not a share is no signal.
                guard case let .sharing(range) = try await requestAgeRange(ageGates: gate) else {
                    return .noSignal
                }
                return .sharing(lowerBound: range.lowerBound)
            }
        }
    }
}
