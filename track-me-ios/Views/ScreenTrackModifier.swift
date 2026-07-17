import SwiftUI

struct ScreenTrackModifier: ViewModifier {
    let screenName: String
    @State private var startTime: Date?
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                startTime = Date()
            }
            .onDisappear {
                if let start = startTime {
                    let duration = Int(Date().timeIntervalSince(start))
                    TelemetryManager.shared.trackScreenViewed(screenName: screenName, durationSeconds: duration)
                }
            }
    }
}

extension View {
    func trackScreen(_ screenName: String) -> some View {
        self.modifier(ScreenTrackModifier(screenName: screenName))
    }
}
