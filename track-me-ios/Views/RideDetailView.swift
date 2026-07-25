import SwiftUI
import MapKit
import Charts
import SwiftData

struct NormalizedPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let speedNormalized: Double
    let altitudeNormalized: Double
    let rawSpeed: Double
    let rawAltitude: Double
}

struct RideDetailView: View {
    @Bindable var ride: Ride
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    // UI States
    @State private var isEditingTitle = false
    @State private var editTitleText = ""
    @State private var mapStyle: MapStyle = .standard
    
    // Scrubber
    @State private var scrubIndex: Int?
    
    // Export/Share States
    @State private var snapshotImage: UIImage?
    @State private var gpxURL: URL?
    
    // Dialogs
    @State private var showDeleteConfirm = false
    @State private var showImagePreview = false
    
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
    
    private var normalizedPoints: [NormalizedPoint] {
        let pts = sortedPoints
        guard !pts.isEmpty else { return [] }
        
        let speeds = pts.map { $0.speed * 3.6 } // km/h
        let alts = pts.map { $0.altitude }
        
        let rawMinSpeed = speeds.min() ?? 0
        let rawMaxSpeed = speeds.max() ?? 0
        let speedRange = rawMaxSpeed > rawMinSpeed ? (rawMaxSpeed - rawMinSpeed) : 1.0
        let minSpeed = rawMinSpeed - speedRange * 0.1
        let maxSpeed = rawMaxSpeed + speedRange * 0.1
        
        let rawMinAlt = alts.min() ?? 0
        let rawMaxAlt = alts.max() ?? 0
        let altRange = rawMaxAlt > rawMinAlt ? (rawMaxAlt - rawMinAlt) : 1.0
        let minAlt = rawMinAlt - altRange * 0.1
        let maxAlt = rawMaxAlt + altRange * 0.1
        
        return pts.enumerated().map { (index, pt) in
            let s = speeds[index]
            let a = alts[index]
            return NormalizedPoint(
                timestamp: pt.timestamp,
                speedNormalized: (s - minSpeed) / (maxSpeed - minSpeed),
                altitudeNormalized: (a - minAlt) / (maxAlt - minAlt),
                rawSpeed: s,
                rawAltitude: a
            )
        }
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
                // Map Section
                mapView
                    .frame(height: 320)
                    .frame(maxWidth: .infinity)
                
                if !sortedPoints.isEmpty {
                    // Analytics Section
                    VStack(spacing: 16) {
                        combinedChart
                            .padding(.horizontal)
                            .padding(.top, 16)
                        
                        // Scrubber Details
                        let index = scrubIndex ?? (sortedPoints.count - 1)
                        let elapsed = sortedPoints[index].timestamp.timeIntervalSince(ride.startTime)
                        let dist = cumulativeDistances[index] / 1000.0
                        
                        Text(LocalizationHelper.formatted(
                            "Time: %@  |  Dist: %@ km",
                            formatDuration(elapsed),
                            String(format: "%.2f", dist)
                        ))
                            .font(.system(.subheadline, design: .default, weight: .bold))
                            .foregroundColor(.secondary)
                        
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
                        
                        // Ride Stats Card
                        rideStatsCard
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
                if isEditingTitle {
                    TextField("Ride Name", text: $editTitleText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(minWidth: 150)
                } else {
                    Text(ride.title ?? "Ride Details")
                        .font(.headline)
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
                    modelContext.delete(ride)
                    try? modelContext.save()
                    dismiss()
                },
                secondaryButton: .cancel()
            )
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
                    .tint(BrandColor.sos)
                
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
            .mapStyle(mapStyle)
            .frame(minWidth: 1) // Prevents zero-width CAMetalLayer initialization warnings
            .overlay(alignment: .topTrailing) {
                Menu {
                    Button("Normal") { mapStyle = .standard }
                    Button("Satellite") { mapStyle = .imagery }
                    Button("Hybrid") { mapStyle = .hybrid }
                } label: {
                    Image(systemName: "map")
                        .font(.title2)
                        .foregroundColor(.primary)
                        .padding(12)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                        .shadow(radius: 4)
                }
                .accessibilityLabel(LocalizationHelper.localized("Map style"))
                .padding()
            }
        } else {
            Rectangle()
                .fill(Color(UIColor.secondarySystemBackground))
                .overlay(Text("No GPS Data").foregroundColor(.secondary))
        }
    }
    
    @ViewBuilder
    var combinedChart: some View {
        let pts = normalizedPoints
        Chart {
            ForEach(pts) { pt in
                LineMark(
                    x: .value("Time", pt.timestamp),
                    y: .value("Value", pt.speedNormalized)
                )
                .foregroundStyle(by: .value("Metric", "Speed"))
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            
            ForEach(pts) { pt in
                LineMark(
                    x: .value("Time", pt.timestamp),
                    y: .value("Value", pt.altitudeNormalized)
                )
                .foregroundStyle(by: .value("Metric", "Altitude"))
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            
            if let idx = scrubIndex, idx < pts.count {
                RuleMark(x: .value("Selected", pts[idx].timestamp))
                    .foregroundStyle(Color.gray.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5]))
                
                PointMark(
                    x: .value("Selected", pts[idx].timestamp),
                    y: .value("Value", pts[idx].speedNormalized)
                )
                .foregroundStyle(by: .value("Metric", "Speed"))
                .annotation(position: .top, alignment: .center) {
                    Text(String(format: "%.1f m/s", pts[idx].rawSpeed))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(BrandColor.chartSpeed)
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
                
                PointMark(
                    x: .value("Selected", pts[idx].timestamp),
                    y: .value("Value", pts[idx].altitudeNormalized)
                )
                .foregroundStyle(by: .value("Metric", "Altitude"))
                .annotation(position: .bottom, alignment: .center) {
                    Text(String(format: "%.1f m", pts[idx].rawAltitude))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(BrandColor.chartAltitude)
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
            }
        }
        .chartForegroundStyleScale([
            "Speed": BrandColor.chartSpeed,
            "Altitude": BrandColor.chartAltitude
        ])
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: 200)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .padding()
        .background(Color(UIColor.darkGray))
        .cornerRadius(12)
        // Swift Charts' default per-point audio graph is meaningless with
        // hundreds of points; speak a single summary sentence instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChartAccessibility.description(points: sortedPoints))
    }

    /// Spoken value for the timeline scrubber at the given sample index.
    private func scrubberAccessibilityValue(index: Int) -> String {
        guard index >= 0, index < sortedPoints.count else { return "" }
        let elapsed = sortedPoints[index].timestamp.timeIntervalSince(ride.startTime)
        let speedKmh = sortedPoints[index].speed * 3.6
        return LocalizationHelper.formatted(
            "Time %@, speed %@ kilometers per hour",
            formatDuration(elapsed),
            String(format: "%.1f", speedKmh)
        )
    }
    
    @ViewBuilder
    var rideStatsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ride Stats")
                .font(.title2).bold()
                .foregroundColor(.white)
                .accessibilityAddTraits(.isHeader)
            
            let totalDist = (cumulativeDistances.last ?? 0) / 1000.0
            let duration = (ride.endTime ?? ride.startTime).timeIntervalSince(ride.startTime)
            let avgSpeed = duration > 0 ? (totalDist / (duration / 3600.0)) : 0.0
            let dateStr = DateFormatter.localizedString(from: ride.startTime, dateStyle: .medium, timeStyle: .short)
            
            HStack {
                statItem(title: "Distance", value: String(format: "%.2f km", totalDist))
                Spacer()
                statItem(title: "Duration", value: formatDuration(duration))
                Spacer()
                statItem(title: "GPS Tag", value: "\(sortedPoints.count)")
            }
            
            HStack {
                statItem(title: "Start Time", value: dateStr)
                Spacer()
                statItem(title: "Max G-Force", value: String(format: "%.2f G", maxGForce))
                Spacer()
                statItem(title: "Avg Speed", value: String(format: "%.1f km/h", avgSpeed))
            }
        }
        .padding(20)
        .background(Color(UIColor.darkGray))
        .cornerRadius(16)
    }
    
    @ViewBuilder
    func statItem(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
            Text(value)
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocalizationHelper.localized(title))
        .accessibilityValue(value)
    }
    
    @ViewBuilder
    var actionButtons: some View {
        HStack {
            if let image = snapshotImage {
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
                actionButton(icon: "trash", text: "Delete", color: BrandColor.sos, textColor: BrandColor.sosText)
            }
        }
        .padding(.horizontal)
        .sheet(isPresented: $showImagePreview) {
            ImagePreviewView(image: snapshotImage)
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

struct ImagePreviewView: View {
    @Environment(\.dismiss) var dismiss
    let image: UIImage?
    
    var body: some View {
        NavigationStack {
            VStack {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let image = image {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Ride Snapshot", image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }
}
