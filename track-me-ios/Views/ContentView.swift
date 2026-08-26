//
//  ContentView.swift
//  track-me-ios
//
//  Created by Shivam Singh on 22/06/26.
//

import SwiftUI
import SwiftData
import DeclaredAgeRange
import UIKit

struct ContentView: View {
    // B2: shared foreground trigger (scenePhase) — parity with Android MainActivity.onResume.
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var recapCoordinator = WeeklyRecapCoordinator.shared
    @ObservedObject private var updateManager = AppUpdateManager.shared
    @ObservedObject private var ageSignalManager = AgeSignalManager.shared
    @Environment(\.requestAgeRange) private var requestAgeRange
    @Environment(\.modelContext) private var modelContext
    private var trackingManager = TrackingManager.shared
    @Bindable private var groupRide = GroupRideManager.shared
    @Bindable private var emergencyRetirement = EmergencyDataPurge.shared
    @State private var selectedTab: AppTab = .home
    @State private var tabScrollToTopRequest = 0
    @AppStorage(OnboardingGate.stateKey) private var onboardingStateRaw = OnboardingState.legacy.rawValue

    private var onboardingState: OnboardingState {
        OnboardingState(rawValue: onboardingStateRaw) ?? .legacy
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                onNavigateHistory: { selectedTab = .history },
                onNavigateCommunity: { selectedTab = .community },
                scrollToTopRequest: tabScrollToTopRequest
            )
            .tabItem { Label("Home", systemImage: "house.fill") }
            .tag(AppTab.home)

            HistoryView(scrollToTopRequest: tabScrollToTopRequest)
                .tabItem { Label("History", systemImage: "clock.fill") }
                .tag(AppTab.history)

            CommunityView()
                .tabItem { Label(LocalizationHelper.localized("Community"), systemImage: "person.2.fill") }
                .tag(AppTab.community)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .onChange(of: selectedTab) { _, _ in tabScrollToTopRequest += 1 }
        .background(TabBarReselectObserver { tabScrollToTopRequest += 1 })
    }

    var body: some View {
        Group {
            if ageSignalManager.decision == .blocked {
                AgeRestrictedView()
            } else if ageSignalManager.decision == nil {
                AgeSignalCheckingView()
            } else if onboardingState == .pending {
                OnboardingView { outcome in
                    OnboardingGate.complete(outcome)
                    // Land on Home with a real default, without turning the CTA into a location
                    // permission trap or starting a recording before the user's next gesture.
                    trackingManager.selectedPersona = outcome.selectedPersona
                    DashboardPersonaPreference.recordOnboardingFallback(outcome.selectedPersona)
                    onboardingStateRaw = OnboardingState.done.rawValue
                    try? OnboardingSampleRideSeeder.seedIfNeeded(
                        context: modelContext,
                        onboardingState: .done,
                        title: LocalizationHelper.localized("Sample ride")
                    )
                }
            } else {
                mainTabs
            }
        }
        .sheet(item: $recapCoordinator.pending, onDismiss: {
            // TASK-119: prompt 30 requires acknowledging on ANY *user* dismissal. A gate-driven
            // park (the moment stopped being calm) is not a dismissal — it must leave the week
            // un-acked so the recap returns at the next calm check.
            guard !recapCoordinator.consumeGatePark() else { return }
            Task { await recapCoordinator.acknowledge() }
        }) { recap in
            WeeklyRecapView(recap: recap) {
                recapCoordinator.pending = nil
            }
        }
        .task { await recapCoordinator.check() }
        // TASK-119: a recap queued while idle must not stay on screen if tracking starts moments
        // later (a restored ride resuming after launch is the realistic case). Parity with the
        // Android `HomeScreen` render-time guard.
        .onChange(of: trackingManager.state) { _, _ in
            recapCoordinator.parkIfNotCalm()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await recapCoordinator.check() }
                FirestoreSyncManager.shared.syncOnForegroundIfDue()
                Task { _ = await updateManager.checkForUpdate() }
            }
        }
        .onChange(of: groupRide.pendingJoinCode) { _, code in
            if code != nil { selectedTab = .community }
        }
        .onChange(of: groupRide.pendingJoinToken) { _, token in
            if token != nil { selectedTab = .community }
        }
        .onChange(of: groupRide.communityNavigationRequest) { _, _ in
            selectedTab = .community
        }
        .onChange(of: groupRide.mapFocusRequest) { _, _ in
            selectedTab = .home
        }
        .sheet(isPresented: Binding(
            get: { onboardingState != .pending && updateManager.updateInfo != nil && trackingManager.state == .idle },
            set: { _ in }
        )) {
            if let info = updateManager.updateInfo {
                AppUpdateView(updateInfo: info) {
                    updateManager.dismissUpdate(version: info.latestVersionName)
                }
            }
        }
        // C2 — brand system v1: Inter as the app-wide default family, cyan as the
        // framework tint (selected tab, switches, framework controls). Individual
        // views still override per role.
        .brandDefaultFont()
        .tint(BrandColor.primary)
        .task {
            await ageSignalManager.checkAndPersist { gate in
                try await requestAgeRange(ageGates: gate)
            }
        }
        .alert(
            LocalizationHelper.localized("The SOS button has been removed"),
            isPresented: $emergencyRetirement.shouldShowRemovalNotice
        ) {
            Button(LocalizationHelper.localized("I understand")) {
                emergencyRetirement.acknowledgeRemovalNotice()
            }
        } message: {
            Text(LocalizationHelper.localized("TrackMe no longer includes in-app SOS or automatic SMS alerts. Your saved emergency contacts were removed from this device. For a real emergency, use your phone's built-in Emergency SOS or call local emergency services."))
        }
    }
}

private enum AppTab: Hashable {
    case home
    case history
    case community
    case settings
}

/// SwiftUI's TabView does not publish a selection change when the active item is tapped again.
/// Observe the UIKit tab bar only for that reselect gesture; ordinary content taps are untouched.
private struct TabBarReselectObserver: UIViewRepresentable {
    let onReselect: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onReselect: onReselect) }
    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onReselect = onReselect
        DispatchQueue.main.async {
            guard let tabBar = Self.findTabBar(from: view), context.coordinator.tabBar !== tabBar else { return }
            if let oldTabBar = context.coordinator.tabBar, let gesture = context.coordinator.gesture {
                oldTabBar.removeGestureRecognizer(gesture)
            }
            let gesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tabBarTapped(_:)))
            gesture.cancelsTouchesInView = false
            tabBar.addGestureRecognizer(gesture)
            context.coordinator.tabBar = tabBar
            context.coordinator.gesture = gesture
        }
    }

    private static func findTabBar(from view: UIView) -> UITabBar? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let controller = next as? UITabBarController { return controller.tabBar }
            responder = next
        }
        if let rootView = view.window?.rootViewController?.view {
            return findTabBar(in: rootView)
        }
        return nil
    }

    private static func findTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar { return tabBar }
        for child in view.subviews {
            if let tabBar = findTabBar(in: child) { return tabBar }
        }
        return nil
    }

    final class Coordinator: NSObject {
        var onReselect: () -> Void
        weak var tabBar: UITabBar?
        weak var gesture: UITapGestureRecognizer?

        init(onReselect: @escaping () -> Void) { self.onReselect = onReselect }

        @objc func tabBarTapped(_ gesture: UITapGestureRecognizer) {
            guard let tabBar else { return }
            let point = gesture.location(in: tabBar)
            guard tabBar.bounds.contains(point), tabBar.selectedItem != nil else { return }
            onReselect()
        }
    }
}

#Preview {
    ContentView()
}
