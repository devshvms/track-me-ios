//
//  ContentView.swift
//  track-me-ios
//
//  Created by Shivam Singh on 22/06/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    // B2: shared foreground trigger (scenePhase) — parity with Android MainActivity.onResume.
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var recapCoordinator = WeeklyRecapCoordinator.shared
    @ObservedObject private var updateManager = AppUpdateManager.shared
    private var trackingManager = TrackingManager.shared

    var body: some View {
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
        .sheet(item: $recapCoordinator.pending) { recap in
            WeeklyRecapView(recap: recap) {
                Task { await recapCoordinator.acknowledge() }
            }
        }
        .task { await recapCoordinator.check() }
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
    }
}

#Preview {
    ContentView()
}
