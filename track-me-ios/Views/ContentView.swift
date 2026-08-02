//
//  ContentView.swift
//  track-me-ios
//
//  Created by Shivam Singh on 22/06/26.
//

import SwiftUI
import SwiftData
import DeclaredAgeRange

struct ContentView: View {
    // B2: shared foreground trigger (scenePhase) — parity with Android MainActivity.onResume.
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var recapCoordinator = WeeklyRecapCoordinator.shared
    @ObservedObject private var updateManager = AppUpdateManager.shared
    @ObservedObject private var ageSignalManager = AgeSignalManager.shared
    @Environment(\.requestAgeRange) private var requestAgeRange
    private var trackingManager = TrackingManager.shared

    var body: some View {
        Group {
            if ageSignalManager.decision == .blocked {
                AgeRestrictedView()
            } else if ageSignalManager.decision == nil {
                AgeSignalCheckingView()
            } else {
                TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "map.fill")
                }

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                }
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
        .sheet(isPresented: Binding(
            get: { updateManager.updateInfo != nil && trackingManager.state == .idle },
            set: { _ in }
        )) {
            if let info = updateManager.updateInfo {
                // A force-update that hijacks a live ride would lose data and is exactly the failure mode we're trying to prevent.
                // Deliberate divergence from Android's unconditional dialog.
                AppUpdateView(updateInfo: info) {
                    updateManager.dismissUpdate(build: info.latestBuild)
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
    }
}

#Preview {
    ContentView()
}
