import CoreLocation
import Combine
import StoreKit
import SwiftUI
import UserNotifications

private enum OnboardingPage: Int, CaseIterable {
    case welcome
    case ride
    case history
    case together
    case permissions
    case ready

    static var initialForProcess: OnboardingPage {
        #if DEBUG
        let prefix = "-TrackMeOnboardingPage="
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }),
           let rawValue = Int(argument.dropFirst(prefix.count)),
           let page = OnboardingPage(rawValue: rawValue) {
            return page
        }
        #endif
        return .welcome
    }
}

struct OnboardingView: View {
    let onFinish: (OnboardingOutcome) -> Void

    @StateObject private var permissions = OnboardingPermissionModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: OnboardingPage = .initialForProcess
    @State private var attempts = 0
    @State private var furthestPage = 0
    @State private var usedSkip = false
    @State private var startedAt = Date()
    @State private var analyticsWasChanged = false
    @State private var analyticsOptIn = AnalyticsDefault.startsOn(
        primaryCountryCode: nil,
        localeCountryCode: Locale.current.region?.identifier
    )

    var body: some View {
        VStack(spacing: 0) {
            chrome

            ScrollView {
                pageContent
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            }

            actions
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            if attempts == 0 {
                attempts = OnboardingGate.recordAttempt()
                startedAt = Date()
            }
            await permissions.refreshNotifications()
            guard !analyticsWasChanged, let storefront = await Storefront.current else { return }
            analyticsOptIn = AnalyticsDefault.startsOn(
                primaryCountryCode: Locale.current.region?.identifier,
                localeCountryCode: storefront.countryCode
            )
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                permissions.refreshLocation()
                Task { await permissions.refreshNotifications() }
            }
        }
    }

    private var chrome: some View {
        HStack(spacing: 12) {
            Button {
                guard let previous = OnboardingPage(rawValue: page.rawValue - 1) else { return }
                move(to: previous)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .opacity(page == .welcome ? 0 : 1)
            .disabled(page == .welcome)
            .accessibilityLabel(LocalizationHelper.localized("Back"))

            HStack(spacing: 5) {
                ForEach(OnboardingPage.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item == page ? BrandColor.primary : Color.secondary.opacity(0.25))
                        .frame(width: item == page ? 18 : 6, height: 6)
                        .animation(.easeOut(duration: 0.18), value: page)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LocalizationHelper.formatted("Step %d of %d", page.rawValue + 1, OnboardingPage.allCases.count))

            if page.rawValue >= OnboardingPage.ride.rawValue && page.rawValue <= OnboardingPage.together.rawValue {
                Button(LocalizationHelper.localized("Skip")) {
                    usedSkip = true
                    move(to: .permissions)
                }
                .font(BrandTypography.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .welcome:
            VStack(alignment: .leading, spacing: 28) {
                WelcomeOnboardingArt()
                PageCopy(
                    title: "Your rides, private by default",
                    body: "TrackMe records where you go and shares it only when you choose to. Here's the 40-second tour."
                )
            }
        case .ride:
            VStack(alignment: .leading, spacing: 24) {
                RideGestureOnboardingArt()
                PageCopy(
                    title: "Press and hold to start",
                    body: "Hold the Start button, then drag to pick how you're moving - Auto, Walk, Run, Cycling, Bike or Car. Let go, and TrackMe begins recording your route, distance and pace."
                )
            }
        case .history:
            VStack(alignment: .leading, spacing: 24) {
                HistoryOnboardingArt()
                PageCopy(
                    title: "Every ride is kept",
                    body: "Finished rides land in History with your route, distance, time and pace. Open one to inspect or replay it, or pick two rides to compare side by side."
                )
            }
        case .together:
            VStack(alignment: .leading, spacing: 24) {
                TogetherOnboardingArt()
                PageCopy(
                    title: "Ride together, on one map",
                    body: "In Community, create a group and share the code or link. Everyone who joins moves on the same map, live. Sharing with just one person? Send a live link so they can follow in a browser without the app.",
                    note: "Groups are end-to-end encrypted and expire on their own."
                )
            }
        case .permissions:
            permissionsPage
        case .ready:
            readyPage
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(LocalizationHelper.localized("Permissions, when you need them"))
                .font(BrandTypography.title2)
                .accessibilityAddTraits(.isHeader)

            LocationScopeOnboardingArt()

            OnboardingPermissionCard(
                systemImage: "location.fill",
                title: "Location",
                body: "Location is needed to record a ride or share your position with a live group. TrackMe will ask when you start your first ride.",
                badge: "Needed for rides",
                status: permissions.locationStatusText,
                isGranted: permissions.locationGranted,
                pendingStatus: "Asked when you start a ride"
            )

            OnboardingPermissionCard(
                systemImage: "bell.fill",
                title: "Notifications",
                body: "Notifications can provide group start reminders and important ride status alerts. TrackMe asks only when a feature needs them.",
                badge: "Optional",
                status: permissions.notificationsGranted ? "Allowed" : nil,
                isGranted: permissions.notificationsGranted,
                pendingStatus: "Asked when relevant"
            )

            Text(LocalizationHelper.localized("You can continue without granting access. If you decline location later, you can still use TrackMe's non-recording features and enable location in Settings at any time."))
                .font(BrandTypography.footnote)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var readyPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(LocalizationHelper.localized("Two last things"))
                .font(BrandTypography.title2)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 14) {
                Label(LocalizationHelper.localized("Keep GPS precise"), systemImage: "location.circle.fill")
                    .font(BrandTypography.headline)
                Text(LocalizationHelper.localized("For accurate routes, keep Precise Location enabled for TrackMe and avoid Low Power Mode during long rides."))
                    .font(BrandTypography.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrandColor.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizationHelper.localized("Share anonymous usage data"))
                        .font(BrandTypography.headline)
                    Text(LocalizationHelper.localized("Helps us find bugs and see which features matter. Never your location or personal details. Change it anytime in Settings."))
                        .font(BrandTypography.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(
                    get: { analyticsOptIn },
                    set: {
                        analyticsWasChanged = true
                        analyticsOptIn = $0
                    }
                ))
                .labelsHidden()
                .tint(BrandColor.primary)
                .accessibilityLabel(LocalizationHelper.localized("Share anonymous usage data"))
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var actions: some View {
        VStack(spacing: 4) {
            Button {
                switch page {
                case .ready:
                    finish()
                default:
                    move(to: OnboardingPage(rawValue: page.rawValue + 1) ?? .ready)
                }
            } label: {
                Text(LocalizationHelper.localized(primaryActionTitle))
                    .font(BrandTypography.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .foregroundStyle(BrandColor.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(BrandColor.primaryFill, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if page == .welcome {
                Button(LocalizationHelper.localized("Skip to setup")) {
                    usedSkip = true
                    move(to: .permissions)
                }
                .font(BrandTypography.footnote.weight(.semibold))
                .frame(minHeight: 44)
            }
        }
    }

    private var primaryActionTitle: String {
        switch page {
        case .welcome: "Take the tour"
        case .permissions: "Continue"
        case .ready: "Start using TrackMe"
        default: "Next"
        }
    }

    private func move(to next: OnboardingPage) {
        withAnimation(.easeInOut(duration: 0.2)) {
            page = next
            furthestPage = max(furthestPage, next.rawValue)
        }
    }

    private func finish() {
        onFinish(OnboardingOutcome(
            attempts: max(1, attempts),
            furthestPage: max(furthestPage, page.rawValue),
            usedSkip: usedSkip,
            seconds: max(0, Int(Date().timeIntervalSince(startedAt))),
            analyticsOptIn: analyticsOptIn,
            locationGranted: permissions.locationGranted,
            notificationsGranted: permissions.notificationsGranted
        ))
    }
}

private struct PageCopy: View {
    let title: String
    let message: String
    var note: String?

    init(title: String, body: String, note: String? = nil) {
        self.title = title
        self.message = body
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizationHelper.localized(title))
                .font(BrandTypography.title2)
                .accessibilityAddTraits(.isHeader)
            Text(LocalizationHelper.localized(message))
                .font(BrandTypography.body)
                .foregroundStyle(.secondary)
            if let note {
                Text(LocalizationHelper.localized(note))
                    .font(BrandTypography.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OnboardingPermissionCard: View {
    let systemImage: String
    let title: String
    let message: String
    let badge: String
    let status: String?
    let isGranted: Bool
    let pendingStatus: String

    init(
        systemImage: String,
        title: String,
        body: String,
        badge: String,
        status: String?,
        isGranted: Bool,
        pendingStatus: String
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = body
        self.badge = badge
        self.status = status
        self.isGranted = isGranted
        self.pendingStatus = pendingStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 32, height: 32)
                    .background(BrandColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Text(LocalizationHelper.localized(title))
                    .font(BrandTypography.headline)
                Spacer()
                Text(LocalizationHelper.localized(badge))
                    .font(BrandTypography.caption)
                    .foregroundStyle(.secondary)
            }

            Text(LocalizationHelper.localized(message))
                .font(BrandTypography.footnote)
                .foregroundStyle(.secondary)

            if isGranted, let status {
                Label(LocalizationHelper.localized(status), systemImage: "checkmark.circle.fill")
                    .font(BrandTypography.footnote.weight(.semibold))
                    .foregroundStyle(BrandColor.success)
            } else {
                Label(LocalizationHelper.localized(pendingStatus), systemImage: "clock")
                    .font(BrandTypography.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
private final class OnboardingPermissionModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var notificationsGranted = false

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationStatus = locationManager.authorizationStatus
        locationManager.delegate = self
    }

    var locationGranted: Bool {
        locationStatus == .authorizedAlways || locationStatus == .authorizedWhenInUse
    }

    var locationStatusText: String? {
        switch locationStatus {
        case .authorizedAlways: "Always allowed"
        case .authorizedWhenInUse: "Allowed while using"
        default: nil
        }
    }

    func refreshLocation() {
        locationStatus = locationManager.authorizationStatus
    }

    func refreshNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsGranted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationStatus = manager.authorizationStatus
    }
}

private struct WelcomeOnboardingArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(uiColor: .secondarySystemBackground))
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                .font(.system(size: 88, weight: .regular))
                .foregroundStyle(Color.secondary.opacity(0.35))
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 58, weight: .semibold))
                .foregroundStyle(BrandColor.primary)
        }
        .frame(height: 190)
        .accessibilityHidden(true)
    }
}

private struct RideGestureOnboardingArt: View {
    private let items = ["figure.walk", "figure.run", "bicycle", "motorcycle", "car.fill"]

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6]))
                .frame(width: 160, height: 160)
            ForEach(Array(items.enumerated()), id: \.offset) { index, image in
                Image(systemName: image)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(index == 2 ? BrandColor.onPrimary : BrandColor.primary)
                    .frame(width: 48, height: 48)
                    .background(index == 2 ? BrandColor.primaryFill : Color(uiColor: .secondarySystemBackground), in: Circle())
                    .overlay(Circle().stroke(BrandColor.primary.opacity(0.35)))
                    .offset(x: CGFloat(index - 2) * 62, y: index.isMultiple(of: 2) ? -58 : -14)
            }
            Image(systemName: "play.fill")
                .font(.title.bold())
                .foregroundStyle(BrandColor.onPrimary)
                .frame(width: 72, height: 72)
                .background(BrandColor.primaryFill, in: Circle())
                .offset(y: 58)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .accessibilityHidden(true)
    }
}

private struct HistoryOnboardingArt: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(BrandColor.primary.opacity(0.1))
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 44))
                    .foregroundStyle(BrandColor.primary)
            }
            .frame(width: 90, height: 76)

            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizationHelper.localized("12.4 km"))
                    .font(BrandTypography.title3)
                Text(LocalizationHelper.localized("48:20 - Cycling"))
                    .font(BrandTypography.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .accessibilityHidden(true)
    }
}

private struct TogetherOnboardingArt: View {
    var body: some View {
        HStack(spacing: 28) {
            rider(color: BrandColor.primary, icon: "bicycle")
            rider(color: BrandColor.success, icon: "figure.outdoor.cycle")
            rider(color: BrandColor.warning, icon: "motorcycle")
        }
        .overlay {
            Capsule()
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [7]))
                .frame(height: 2)
                .padding(.horizontal, 38)
                .zIndex(-1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .accessibilityHidden(true)
    }

    private func rider(color: Color, icon: String) -> some View {
        Image(systemName: icon)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(color, in: Circle())
            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 4))
    }
}

private struct LocationScopeOnboardingArt: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(LocalizationHelper.localized("Location off"))
                Spacer()
                Text(LocalizationHelper.localized("Active ride or group"))
                    .foregroundStyle(BrandColor.primary)
                Spacer()
                Text(LocalizationHelper.localized("Location off"))
            }
            .font(BrandTypography.caption)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 8)
                    Capsule()
                        .fill(BrandColor.primary)
                        .frame(width: proxy.size.width * 0.38, height: 8)
                        .offset(x: proxy.size.width * 0.32)
                    Image(systemName: "location.fill")
                        .foregroundStyle(BrandColor.primary)
                        .frame(width: 28, height: 28)
                        .background(Color(uiColor: .systemBackground), in: Circle())
                        .offset(x: proxy.size.width * 0.48 - 14)
                }
            }
            .frame(height: 28)
        }
        .accessibilityHidden(true)
    }
}
