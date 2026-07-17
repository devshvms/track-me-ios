import SwiftUI
import MapKit
import FirebaseAuth

struct HomeView: View {
    @Bindable var trackingManager = TrackingManager.shared
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var mapStyle: MapStyle = .standard
    @Namespace private var mapScope
    
    @Bindable var networkMonitor = NetworkMonitor.shared
    @State private var liveSharingManager = LiveSharingManager.shared
    @State private var showLiveShareDialog = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $position, scope: mapScope) {
                UserAnnotation()
                if !trackingManager.points.isEmpty {
                    let coordinates = trackingManager.points.map { $0.coordinate }
                    MapPolyline(coordinates: coordinates)
                        .stroke(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                        )
                }
            }
            .mapStyle(mapStyle)
            .mapControls {
                MapUserLocationButton()
            }
            .mapScope(mapScope)
            .ignoresSafeArea(edges: .top)
            
            // Top UI (Map Style, GPS Warning & Offline Tracking Shield)
            VStack(spacing: 8) {
                if trackingManager.state == .gpsLost || (trackingManager.state == .tracking && trackingManager.timeSinceLastGps > 10.0) {
                    let seconds = Int(trackingManager.timeSinceLastGps)
                    let timeString = seconds > 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
                    Text("No GPS signal for \(timeString)")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .padding(.top, 50)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                if !networkMonitor.isConnected {
                    let shieldText = trackingManager.state != .idle
                        ? "🛡️ Offline Tracking Shield Active • Route Safely Recording"
                        : "🛡️ Offline Tracking Shield • Ready to Record Locally"
                    
                    Text(shieldText)
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color(red: 0.11, green: 0.37, blue: 0.13).opacity(0.95))
                        .overlay(
                            Capsule()
                                .stroke(Color(red: 0.51, green: 0.78, blue: 0.52), lineWidth: 1)
                        )
                        .clipShape(Capsule())
                        .padding(.top, (trackingManager.state == .gpsLost || trackingManager.timeSinceLastGps > 10.0) ? 0 : 50)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                HStack {
                    MapCompass(scope: mapScope)
                        .padding(.leading, 16)
                        .padding(.top, trackingManager.state == .gpsLost ? 16 : 50)
                    
                    Spacer()
                    
                    VStack(spacing: 16) {
                        Menu {
                            Button("Normal") { mapStyle = .standard }
                            Button("Satellite") { mapStyle = .imagery }
                            Button("Hybrid") { mapStyle = .hybrid }
                        } label: {
                            Image(systemName: "map")
                                .font(.title2)
                                .foregroundColor(.primary)
                                .frame(width: 48, height: 48)
                                .background(.regularMaterial)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }
                        
                        Button(action: { showLiveShareDialog = true }) {
                            if liveSharingManager.isActive {
                                VStack(spacing: 2) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: 16, weight: .bold))
                                    Text(formatDuration(TimeInterval(liveSharingManager.remainingSeconds)))
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                }
                                .foregroundColor(.white)
                                .frame(width: 48, height: 48)
                                .background(Color.green.gradient)
                                .clipShape(Circle())
                                .shadow(color: .green.opacity(0.5), radius: 6)
                            } else {
                                Image(systemName: "location.viewfinder")
                                    .font(.title2)
                                    .foregroundColor(.primary)
                                    .frame(width: 48, height: 48)
                                    .background(.regularMaterial)
                                    .clipShape(Circle())
                                    .shadow(radius: 4)
                            }
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.top, trackingManager.state == .gpsLost ? 16 : 50)
                }
                Spacer()
            }
            
            VStack(spacing: 20) {
                // Glassmorphic Stats Card
                VStack(spacing: 20) {
                    if trackingManager.state != .idle {
                        VStack(alignment: .center, spacing: 4) {
                            Text("TIME")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.secondary)
                            Text(formatDuration(trackingManager.durationInMillis / 1000))
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .contentTransition(.numericText())
                        }
                        
                        Divider()
                            .padding(.horizontal, 20)
                    }
                    
                    HStack(spacing: 40) {
                        VStack(alignment: .center, spacing: 4) {
                            Text("SPEED")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(String(format: "%.1f", trackingManager.currentSpeed))
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .contentTransition(.numericText())
                                Text("m/s")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Divider()
                            .frame(height: 40)
                        
                        VStack(alignment: .center, spacing: 4) {
                            Text("DISTANCE")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(String(format: "%.2f", trackingManager.totalDistance / 1000))
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .contentTransition(.numericText())
                                Text("km")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 30)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Color.black.opacity(0.15), radius: 15, x: 0, y: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                
                // SOS Component
                if trackingManager.state != .idle && Auth.auth().currentUser != nil {
                    SwipeToTriggerSlider(onTriggered: {
                        EmergencyManager.shared.startBroadcast()
                    })
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                // Main Action Buttons
                HStack(spacing: 24) {
                    switch trackingManager.state {
                    case .idle:
                        TrackingButton(icon: "play.fill", color: .green) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                trackingManager.startTracking()
                            }
                        }
                    case .tracking, .gpsLost:
                        TrackingButton(icon: "pause.fill", color: .orange) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                trackingManager.pauseTracking()
                            }
                        }
                    case .paused:
                        TrackingButton(icon: "play.fill", color: .green) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                trackingManager.resumeTracking()
                            }
                        }
                        TrackingButton(icon: "stop.fill", color: .red) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                trackingManager.stopTracking()
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: trackingManager.state)
            }
            .padding(.bottom, 30)
        }
        .sheet(isPresented: $showLiveShareDialog) {
            LiveShareDialog()
        }
        .alert("Location access for safe tracking", isPresented: $trackingManager.showLocationPermissionExplanation) {
            Button("Continue") {
                trackingManager.continueAfterLocationExplanation()
            }
            Button("Not now", role: .cancel) {
                trackingManager.cancelPendingTrackingStart()
            }
        } message: {
            Text("TrackMe records your route locally first and needs location access while you are moving. Allowing Always access lets an active track continue when your phone is locked.")
        }
        .trackScreen("HomeView")
    }
    
    private func formatDuration(_ timeInterval: TimeInterval) -> String {
        let totalSeconds = Int(timeInterval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

struct TrackingButton: View {
    var icon: String
    var color: Color
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 72, height: 72)
                .background(color.gradient)
                .clipShape(Circle())
                .shadow(color: color.opacity(0.4), radius: 10, x: 0, y: 5)
        }
    }
}
