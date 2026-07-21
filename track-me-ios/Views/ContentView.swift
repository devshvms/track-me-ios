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
            }
        }
    }
}

#Preview {
    ContentView()
}
