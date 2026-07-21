import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation
struct HistoryView: View {
    @Query(sort: \Ride.startTime, order: .reverse) private var rides: [Ride]
    @State private var showFileImporter = false
    @Environment(\.modelContext) private var modelContext
    
    // Horizon v1.2.0 Inline Filters
    @State private var selectedSyncStatus: String = "All"
    let syncStatusOptions = ["All", "Synced", "Unsynced"]
    
    @State private var selectedDistanceThresholdKm: Double = 0.0
    let distanceOptions: [(label: String, minKm: Double)] = [
        ("All", 0.0),
        ("> 5 km", 5.0),
        ("> 20 km", 20.0),
        ("> 50 km", 50.0)
    ]
    
    private var filteredRides: [Ride] {
        rides.filter { ride in
            let matchesSync: Bool
            switch selectedSyncStatus {
            case "Synced": matchesSync = ride.isSynced
            case "Unsynced": matchesSync = !ride.isSynced
            default: matchesSync = true
            }
            
            let rideDistanceKm = (ride.points ?? []).count > 1 ? estimateDistanceKm(points: ride.points ?? []) : 0.0
            let matchesDistance = rideDistanceKm >= selectedDistanceThresholdKm
            
            return matchesSync && matchesDistance
        }
    }
    
    private var groupedRides: [DateBucket: [Ride]] {
        Dictionary(grouping: filteredRides) { ride in
            LocalizationHelper.bucket(for: ride.startTime)
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Horizon Inline Filter Chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(syncStatusOptions, id: \.self) { option in
                            FilterChipView(
                                title: LocalizationHelper.syncStatusTitle(option),
                                isSelected: selectedSyncStatus == option
                            ) {
                                selectedSyncStatus = option
                            }
                        }
                        
                        Divider().frame(height: 20)
                        
                        ForEach(distanceOptions, id: \.minKm) { option in
                            FilterChipView(
                                title: option.label,
                                isSelected: selectedDistanceThresholdKm == option.minKm
                            ) {
                                selectedDistanceThresholdKm = option.minKm
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                
                // Sticky Date-Grouped List
                List {
                    ForEach(DateBucket.allCases, id: \.self) { bucket in
                        if let bucketRides = groupedRides[bucket], !bucketRides.isEmpty {
                            Section {
                                ForEach(bucketRides) { ride in
                                    NavigationLink(destination: RideDetailView(ride: ride)) {
                                        CompactRideRowView(ride: ride)
                                    }
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                }
                            } header: {
                                Text(bucket.localizedTitle())
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(.secondary)
                                    .textCase(nil)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .overlay {
                    if filteredRides.isEmpty {
                        ContentUnavailableView(
                            "No Rides Found",
                            systemImage: "bicycle",
                            description: Text("No rides match your selected filter criteria or no rides recorded yet.")
                        )
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showFileImporter = true
                    }) {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.xml, .init(filenameExtension: "gpx")!]) { result in
                switch result {
                case .success(let url):
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        let parser = GPXParser()
                        if let ride = parser.parse(url: url) {
                            modelContext.insert(ride)
                        }
                    }
                case .failure(let error):
                    print("Error reading file: \(error.localizedDescription)")
                }
            }
        }
        .trackScreen("HistoryView")
    }
    
    private func estimateDistanceKm(points: [GPSPoint]) -> Double {
        var totalMeters = 0.0
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        for i in 1..<sorted.count {
            let p1 = sorted[i-1]
            let p2 = sorted[i]
            let loc1 = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
            let loc2 = CLLocation(latitude: p2.latitude, longitude: p2.longitude)
            totalMeters += loc2.distance(from: loc1)
        }
        return totalMeters / 1000.0
    }
}

// MARK: - Compact Ride Row (80x60pt Thumbnail + High-Density Layout)
struct CompactRideRowView: View {
    let ride: Ride

    var body: some View {
        HStack(spacing: 12) {
            RoutePreviewThumbnail(points: ride.points ?? [])
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(ride.title ?? "TrackMe Ride")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: ride.isSynced ? "checkmark.icloud.fill" : "exclamationmark.icloud")
                        .font(.caption)
                        .foregroundColor(ride.isSynced ? .green : .orange)
                }

                HStack(spacing: 12) {
                    Label(ride.startTime.formatted(date: .omitted, time: .shortened), systemImage: "clock")

                    let pointsCount = (ride.points ?? []).count
                    Label("\(pointsCount) pts", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        // Read the whole row as one sentence; the sync state is otherwise
        // conveyed only by the cloud icon's color, which VoiceOver cannot see.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(LocalizationHelper.localized("Shows ride details"))
    }

    private var accessibilityDescription: String {
        let title = ride.title ?? LocalizationHelper.localized("TrackMe Ride")
        let time = ride.startTime.formatted(date: .abbreviated, time: .shortened)
        let pointsCount = (ride.points ?? []).count
        let syncState = ride.isSynced
            ? LocalizationHelper.localized("Synced")
            : LocalizationHelper.localized("Not yet synced")
        return LocalizationHelper.formatted(
            "%@. %@. %@ points. %@",
            title, time, String(pointsCount), syncState
        )
    }
}

// MARK: - Filter Chip Component
struct FilterChipView: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? BrandColor.primary : Color(UIColor.tertiarySystemFill))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
