import SwiftUI
import CoreLocation
import UserNotifications
import UIKit
import FirebaseAuth

struct HelpFeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = Set<Int>()
    @State private var notificationAuthorization = "Unknown"

    private var faqs: [(question: String, answer: String, settings: Bool)] {
        [
            (LocalizationHelper.localized("My ride stopped recording when the screen was off."), LocalizationHelper.localized("On iPhone, set Location access to Always. Also check Low Power Mode and Background App Refresh in Settings."), true),
            (LocalizationHelper.localized("TrackMe drains my battery."), LocalizationHelper.localized("GPS uses power while a ride is recording. The ongoing notification confirms recording is active; auto-pause can reduce unnecessary work."), false),
            (LocalizationHelper.localized("The distance looks wrong."), LocalizationHelper.localized("GPS drift while stopped, tunnels, and urban canyons can affect distance. GPS post-processing helps; a signal gap is shown as a straight line."), false),
            (LocalizationHelper.localized("Will tracking work without mobile data?"), LocalizationHelper.localized("Yes. Recording is local-first. A connection is needed only for cloud sync, live sharing, and SOS."), false),
            (LocalizationHelper.localized("Who can see a live-share link?"), LocalizationHelper.localized("Anyone with the link can see it until the session expires. Only the signed-in owner can start, update, or stop the session."), false),
            (LocalizationHelper.localized("How do I get my data out, or delete it?"), LocalizationHelper.localized("Open Settings → Account Management to export your data or delete your account and cloud data."), false)
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(LocalizationHelper.localized("Help & Feedback"))
                    .font(.title2.bold())
                Text(LocalizationHelper.localized("Find quick answers or send an editable support report."))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ForEach(Array(faqs.enumerated()), id: \.offset) { index, faq in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expanded.contains(index) },
                        set: { isOpen in
                            if isOpen { expanded.insert(index) } else { expanded.remove(index) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(faq.answer)
                                .font(.body)
                            if faq.settings {
                                Button(LocalizationHelper.localized("Open Settings")) {
                                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                    UIApplication.shared.open(url)
                                }
                                .foregroundColor(BrandColor.primary)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text(faq.question)
                            .font(.headline)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                }

                Button(action: contactSupport) {
                    Text(LocalizationHelper.localized("Contact support"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(BrandColor.primaryFill)
                        .foregroundColor(.primary)
                        .cornerRadius(24)
                }
                .accessibilityHint(LocalizationHelper.localized("Opens an editable email draft"))
            }
            .padding()
        }
        .navigationTitle(LocalizationHelper.localized("Help & Feedback"))
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationAuthorization = notificationStatus(settings.authorizationStatus)
        }
        .onAppear { TelemetryManager.shared.trackHelpOpened() }
    }

    private func contactSupport() {
        let body = "\(LocalizationHelper.localized("Describe the problem above. The details below help us diagnose it — edit or remove anything you don't want to send."))\n\n\(LocalizationHelper.localized("— Support details —"))\n\(diagnosticBlock())"
        TelemetryManager.shared.trackSupportContactStarted(faqExpandedCount: expanded.count)
        let subject = "\(LocalizationHelper.localized("TrackMe support")) — iOS \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")"
        var components = URLComponents(string: "mailto:\(SupportContact.email)")!
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        guard let url = components.url, UIApplication.shared.canOpenURL(url) else {
            UIPasteboard.general.string = "\(SupportContact.email)\n\n\(body)"
            ToastManager.shared.show(message: LocalizationHelper.localized("Support address and details copied"), style: .warning)
            return
        }
        UIApplication.shared.open(url)
    }

    private func diagnosticBlock() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"
        let locationManager = CLLocationManager()
        return SupportDiagnostics.render(SupportDiagnosticsInput(
            appVersion: "\(shortVersion) (\(build))",
            iosVersion: UIDevice.current.systemVersion,
            device: machineIdentifier(),
            appLanguage: UserDefaults.standard.string(forKey: "appLanguage") ?? "en",
            deviceLocale: Locale.current.identifier,
            units: UserDefaults.standard.string(forKey: "unitSystem") ?? "metric",
            locationAuthorization: locationStatus(locationManager.authorizationStatus, accuracy: locationManager.accuracyAuthorization),
            notificationAuthorization: notificationAuthorization,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled ? "enabled" : "disabled",
            backgroundRefresh: backgroundRefreshStatus(UIApplication.shared.backgroundRefreshStatus),
            signedIn: !(Auth.auth().currentUser?.isAnonymous ?? true)
        ))
    }

    private func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) ?? UIDevice.current.model
        }
    }

    private func locationStatus(_ status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization) -> String {
        switch status {
        case .authorizedAlways: return accuracy == .fullAccuracy ? "Always, precise" : "Always, reduced"
        case .authorizedWhenInUse: return accuracy == .fullAccuracy ? "While Using, precise" : "While Using, reduced"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        default: return "Not determined"
        }
    }

    private func notificationStatus(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not determined"
        @unknown default: return "Unknown"
        }
    }

    private func backgroundRefreshStatus(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available: return "Available"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }
}
