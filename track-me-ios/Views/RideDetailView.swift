import SwiftUI
import MapKit
import SwiftData

struct RideDetailView: View {
    @Bindable var ride: Ride
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var unitSettings = UnitSettings.shared
    
    // UI States
    @State private var isEditingTitle = false
    @State private var editTitleText = ""
    @State private var mapStyle: TrackMeMapStyle = .standard
    
    // Scrubber
    @State private var scrubIndex: Int?
    
    // Export/Share States
    @State private var snapshotImage: UIImage?
    @State private var gpxURL: URL?
    
    // Dialogs
    @State private var showDeleteConfirm = false
    @State private var showImagePreview = false
    @State private var isDeletingRide = false
    @State private var showRecordingDetails = false
    
    private var sortedPoints: [GPSPoint] {
        guard let points = ride.points, !points.isEmpty else { return [] }
        return points.sorted { $0.timestamp < $1.timestamp }
    }
    
    private var cumulativeDistances: [Double] {
        let pts = sortedPoints
        guard !pts.isEmpty else { return [] }
        var distances = [Double](repeating: 0, count: pts.count)
        var totalDist = 0.0
        for i in 1..<pts.count {
            let p1 = CLLocation(latitude: pts[i-1].latitude, longitude: pts[i-1].longitude)
            let p2 = CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude)
            totalDist += p1.distance(from: p2)
            distances[i] = totalDist
        }
        return distances
    }
    
    private var maxGForce: Double {
        let pts = sortedPoints
        guard pts.count > 1 else { return 0.0 }
        var maxAccel = 0.0
        for i in 1..<pts.count {
            let dt = pts[i].timestamp.timeIntervalSince(pts[i-1].timestamp)
            if dt > 0 {
                let dv = abs(pts[i].speed - pts[i-1].speed)
                let accel = dv / dt
                maxAccel = max(maxAccel, accel)
            }
        }
        return maxAccel / 9.81
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Summary Section
                rideSummaryCard
                    .padding(.horizontal)
                    .padding(.top, 16)

                // Map Section
                mapView
                    .frame(height: 320)
                    .frame(maxWidth: .infinity)
                
                if !sortedPoints.isEmpty {
                    // Analytics Section
                    VStack(spacing: 16) {
                        CombinedMetricLineChart(
                            points: sortedPoints,
                            scrubIndex: scrubIndex
                        )
                            .padding(.horizontal)
                            .padding(.top, 16)
                        
                        // Scrubber Details
                        let index = scrubIndex ?? (sortedPoints.count - 1)
                        let elapsed = sortedPoints[index].timestamp.timeIntervalSince(ride.startTime)
                        Text(LocalizationHelper.formatted(
                            "Time: %@  |  Dist: %@",
                            formatDuration(elapsed),
                            UnitFormatter.distance(meters: cumulativeDistances[index], unit: unitSettings.unit)
                        ))
                            .font(.system(.subheadline, design: .default, weight: .bold))
                            .foregroundColor(.secondary)

                        if ride.ridePersona != .auto {
                            Text("\(ride.ridePersona.emoji) \(ride.ridePersona.displayName)")
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundColor(.secondary)
                                .accessibilityLabel(ride.ridePersona.displayName)
                        }
                        
                        if sortedPoints.count > 1 {
                            Slider(
                                value: Binding(
                                    get: { Double(scrubIndex ?? (sortedPoints.count - 1)) },
                                    set: { scrubIndex = Int($0) }
                                ),
                                in: 0...Double(sortedPoints.count - 1),
                                step: 1
                            )
                            .tint(BrandColor.primary)
                            .padding(.horizontal, 24)
                            .accessibilityLabel(LocalizationHelper.localized("Timeline scrubber"))
                            .accessibilityHint(LocalizationHelper.localized(
                                "Adjust to inspect speed, altitude, and route position"))
                            .accessibilityValue(scrubberAccessibilityValue(index: index))
                        } else {
                            Slider(value: .constant(0), in: 0...1)
                                .disabled(true)
                                .tint(.gray)
                                .padding(.horizontal, 24)
                                .accessibilityHidden(true)
                        }
                        
                        // Recording details stay after the route and chart so diagnostics remain
                        // available without competing with the summary a rider reads first.
                        recordingDetailsCard
                            .padding(.horizontal)
                        
                        // Action Buttons
                        actionButtons
                            .padding(.vertical, 24)
                    }
                } else {
                    Text("No GPS Data Available")
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                }
            }
        }
        .edgesIgnoringSafeArea(.top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    if isEditingTitle {
                        TextField("Ride Name", text: $editTitleText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(minWidth: 150)
                    } else {
                        Text(ride.title ?? "Ride Details")
                            .font(.headline)
                    }
                    if ride.isSample {
                        Text(LocalizationHelper.localized("Sample"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BrandColor.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(BrandColor.primary.opacity(0.12), in: Capsule())
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditingTitle {
                    Button("Done") {
                        isEditingTitle = false
                        if !editTitleText.isEmpty {
                            ride.title = editTitleText
                            try? modelContext.save()
                            ToastManager.shared.show(message: LocalizationHelper.localized("Ride updated"), style: .success)
                        }
                    }
                } else {
                    Button(action: {
                        editTitleText = ride.title ?? ""
                        isEditingTitle = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                            Text("Edit")
                        }
                    }
                }
            }
        }
        .background(Color(UIColor.systemBackground).edgesIgnoringSafeArea(.all))
        .onAppear {
            if snapshotImage == nil {
                ImageExporter.generateSnapshot(for: ride) { img in
                    self.snapshotImage = img
                }
            }
            if gpxURL == nil {
                gpxURL = GPXExporter.generateGPX(from: ride)
            }
        }
        .trackScreen("RideDetailView")
        .alert(isPresented: $showDeleteConfirm) {
            Alert(
                title: Text("Delete Ride"),
                message: Text("Are you sure you want to delete this ride? This action cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    deleteRide()
                },
                secondaryButton: .cancel()
            )
        }
    }

    @MainActor
    private func deleteRide() {
        guard !isDeletingRide else { return }
        isDeletingRide = true

        Task { @MainActor in
            do {
                let outcome = try await FirestoreSyncManager.shared.deleteRideFromCloudIfNeeded(ride)
                if outcome == .queued {
                    isDeletingRide = false
                    ToastManager.shared.show(
                        message: LocalizationHelper.localized("This ride will be removed when you're back online."),
                        style: .info
                    )
                    dismiss()
                    return
                }
            } catch let error as RideCloudDeletionError {
                isDeletingRide = false
                let message: String
                switch error {
                case .signInRequired:
                    message = "Sign in to delete this synced ride from all devices."
                case .rejected:
                    message = "Couldn't delete this ride from the cloud. Check your connection and try again."
                }
                ToastManager.shared.show(
                    message: LocalizationHelper.localized(message),
                    style: .error
                )
                return
            } catch {
                isDeletingRide = false
                ToastManager.shared.show(
                    message: LocalizationHelper.localized("Couldn't delete this ride from the cloud. Check your connection and try again."),
                    style: .error
                )
                return
            }

            modelContext.delete(ride)
            do {
                try modelContext.save()
                HomeDashboardRepository.shared.invalidate()
                dismiss()
            } catch {
                modelContext.rollback()
                isDeletingRide = false
                ToastManager.shared.show(
                    message: LocalizationHelper.localized(
                        "Couldn't delete this ride from this device. Please try again."
                    ),
                    style: .error
                )
            }
        }
    }
    
    @ViewBuilder
    var mapView: some View {
        if !sortedPoints.isEmpty {
            let coordinates = sortedPoints.map { $0.coordinate }
            let minLat = coordinates.map { $0.latitude }.min() ?? 0
            let maxLat = coordinates.map { $0.latitude }.max() ?? 0
            let minLng = coordinates.map { $0.longitude }.min() ?? 0
            let maxLng = coordinates.map { $0.longitude }.max() ?? 0
            
            let center = CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLng + maxLng) / 2
            )
            let span = MKCoordinateSpan(
                latitudeDelta: (maxLat - minLat) * 1.5 + 0.005,
                longitudeDelta: (maxLng - minLng) * 1.5 + 0.005
            )
            
            Map(initialPosition: .region(MKCoordinateRegion(center: center, span: span))) {
                MapPolyline(coordinates: coordinates)
                    .stroke(BrandColor.primary, lineWidth: 5)
                
                Marker("Start", coordinate: coordinates.first!)
                    .tint(BrandColor.primary)
                
                Marker("Finish", coordinate: coordinates.last!)
                    .tint(BrandColor.destructive)
                
                if let idx = scrubIndex, idx < coordinates.count {
                    Annotation("Scrubber", coordinate: coordinates[idx]) {
                        Circle()
                            .fill(BrandColor.primary)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white, lineWidth: 3))
                            .shadow(radius: 3)
                    }
                }
            }
            .mapStyle(mapStyle.mapKitStyle)
            .frame(minWidth: 1) // Prevents zero-width CAMetalLayer initialization warnings
            .overlay(alignment: .topTrailing) {
                MapStyleMenu(selection: $mapStyle) {
                    Image(systemName: "map")
                        .font(.title2)
                        .foregroundColor(.primary)
                        .padding(12)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                        .shadow(radius: 4)
                }
                .padding()
            }
        } else {
            Rectangle()
                .fill(Color(UIColor.secondarySystemBackground))
                .overlay(Text("No GPS Data").foregroundColor(.secondary))
        }
    }
    
    /// Spoken value for the timeline scrubber at the given sample index.
    private func scrubberAccessibilityValue(index: Int) -> String {
        guard index >= 0, index < sortedPoints.count else { return "" }
        let elapsed = sortedPoints[index].timestamp.timeIntervalSince(ride.startTime)
        let speed = UnitFormatter.speed(mps: sortedPoints[index].speed, unit: unitSettings.unit)
        return LocalizationHelper.formatted(
            "Time %@, speed %@",
            formatDuration(elapsed),
            speed
        )
    }
    
    @ViewBuilder
    var rideSummaryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            let aggregate = ride.aggregateSnapshot
            let totalDistMeters = aggregate.distanceMeters
            let duration = Double(aggregate.movingDurationMillis) / 1_000
            let avgSpeedMps = aggregate.avgSpeedMps
            let dateStr = DateFormatter.localizedString(from: ride.startTime, dateStyle: .medium, timeStyle: .short)
            let usesPace = ride.ridePersona == .walk || ride.ridePersona == .run

            VStack(alignment: .leading, spacing: 2) {
                Text("Ride Stats")
                    .font(.title2).bold()
                    .foregroundColor(.white)
                    .accessibilityAddTraits(.isHeader)

                // TASK-229: start time reads as a caption under the heading, not as a grid cell. In
                // a third of a row a date plus a time was always truncated to "Aug 23, 2026 - ...",
                // which drops the half a rider is looking for and says less than 1.8.4 did.
                Text(dateStr)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                statItem(title: "Distance", value: UnitFormatter.distance(meters: totalDistMeters, unit: unitSettings.unit))
                Spacer()
                // TASK-230/235: the pause-excluded figure keeps the label "Duration" — §5.1 only
                // forbids *wall* time being labelled simply that — and "Total" below restores its
                // pair. Those are the two words the HUD already uses mid-ride, which is where a
                // rider learns the distinction; a single unlabelled figure was the defect.
                statItem(title: "Duration", value: formatDuration(duration))
                Spacer()
                statItem(title: usesPace ? "Average Pace" : "Average Speed", value: usesPace ? UnitFormatter.pace(mps: avgSpeedMps, unit: unitSettings.unit) : UnitFormatter.speed(mps: avgSpeedMps, unit: unitSettings.unit))
            }
            
            HStack {
                statItem(title: usesPace ? "Best Pace" : "Max Speed", value: usesPace ? UnitFormatter.pace(mps: aggregate.maxSpeedMps, unit: unitSettings.unit) : UnitFormatter.speed(mps: aggregate.maxSpeedMps, unit: unitSettings.unit))
                if let elevation = ride.elevationGainMeters {
                    Spacer()
                    statItem(title: "Elevation Gain", value: formatElevation(elevation))
                }
                Spacer()
                // The cell TASK-229 freed. Always rendered, never suppressed when it equals moving
                // time: a ride with no pause showing both figures equal is the fact, and it is what
                // makes the pair readable without a legend.
                statItem(title: "Total", value: RideDurations.totalElapsedSeconds(for: ride).map(formatDuration) ?? LocalizationHelper.localized("Unknown"))
            }
        }
        .padding(20)
        .background(Color(UIColor.darkGray))
        .cornerRadius(16)
    }

    @ViewBuilder
    var recordingDetailsCard: some View {
        let aggregate = ride.aggregateSnapshot
        let gapCount = ChartAccessibility.signalGaps(points: sortedPoints).count

        VStack(alignment: .leading, spacing: 16) {
            DisclosureGroup(isExpanded: $showRecordingDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        statItem(title: "GPS Points", value: "\(aggregate.pointCount)")
                        statItem(title: "Max G-Force", value: String(format: "%.2f G", maxGForce))
                        statItem(title: "GPS signal gaps", value: "\(gapCount)")
                    }
                    Text(LocalizationHelper.syncStatusTitle(ride.isSynced ? "Synced" : "Unsynced"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            } label: {
                Text(LocalizationHelper.localized("Recording details"))
                    .font(.headline)
            }
        }
        .padding(20)
        .background(Color(UIColor.darkGray))
        .cornerRadius(16)
    }
    
    @ViewBuilder
    func statItem(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(LocalizationHelper.localized(title))
                .font(.caption.weight(.semibold))
                .foregroundColor(.gray)
                // TASK-240, Android parity. Two lines, always: without a reserved second line a
                // cell whose label wraps pushes its value out of line with its neighbours', and
                // the row reads as misaligned. Sizing for English is not enough — "GPS signal
                // gaps" is 27 characters in French, "Elevation Gain" 19 in Spanish.
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
            Text(value)
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalizationHelper.localized(title))
        .accessibilityValue(value)
    }

    private func formatElevation(_ meters: Double) -> String {
        let value = unitSettings.unit == .imperial ? meters * 3.28084 : meters
        return String(format: "%.0f %@", value, unitSettings.unit == .imperial ? "ft" : "m")
    }
    
    @ViewBuilder
    var actionButtons: some View {
        HStack {
            if snapshotImage != nil {
                Button(action: {
                    showImagePreview = true
                }) {
                    actionButton(icon: "square.and.arrow.up", text: "Share", color: BrandColor.primary)
                }
            }
            
            if let url = gpxURL {
                ShareLink(item: url) {
                    actionButton(icon: "arrow.down.doc", text: "GPX", color: BrandColor.primary)
                }
            }
            
            Button(action: {
                showDeleteConfirm = true
            }) {
                actionButton(icon: "trash", text: "Delete", color: BrandColor.destructive, textColor: BrandColor.destructiveText)
            }
            .disabled(isDeletingRide)
        }
        .padding(.horizontal)
        .sheet(isPresented: $showImagePreview) {
            if let image = snapshotImage {
                ExportPreviewView(ride: ride, snapshotImage: image)
            }
        }
    }
    
    @ViewBuilder
    func actionButton(icon: String, text: String, color: Color, textColor: Color? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text(text)
                .font(.caption)
                .foregroundColor(textColor ?? color)   // adaptive for destructive labels
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalizationHelper.localized(text))
    }
    
    private func formatDuration(_ timeInterval: TimeInterval) -> String {
        let totalSeconds = Int(timeInterval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d:%02d", 0, minutes, seconds)
        }
    }
}
