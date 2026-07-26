import SwiftUI
import SwiftData
import UniformTypeIdentifiers
struct HistoryView: View {
    @Query(sort: \Ride.startTime, order: .reverse) private var rides: [Ride]
    @State private var showFileImporter = false
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var unitSettings = UnitSettings.shared
    
    // v1.6.0 Inline Filters
    @State private var selectedSyncStatus: String = "All"
    let syncStatusOptions = ["All", "Synced", "Unsynced"]
    
    @State private var selectedDistanceThresholdKm: Double = 0.0
    private var filteredRides: [Ride] {
        rides.filter { ride in
            let matchesSync: Bool
            switch selectedSyncStatus {
            case "Synced": matchesSync = ride.isSynced
            case "Unsynced": matchesSync = !ride.isSynced
            default: matchesSync = true
            }
            
            let rideDistanceKm = RideDistance.totalKm(ride.points ?? [])
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
        let distanceOptions: [(label: String, minKm: Double)] = [
            (LocalizationHelper.localized("All"), 0.0),
            (unitSettings.unit == .imperial ? "> 3 mi" : "> 5 km", 5.0),
            (unitSettings.unit == .imperial ? "> 12 mi" : "> 20 km", 20.0),
            (unitSettings.unit == .imperial ? "> 31 mi" : "> 50 km", 50.0)
        ]
        NavigationStack {
            VStack(spacing: 0) {
                // Inline Filter Chips
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
                                HStack {
                                    Text(bucket.localizedTitle())
                                        .font(.footnote.weight(.semibold))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    let totalKm = bucketRides.reduce(0.0) {
                                        $0 + RideDistance.totalKm($1.points ?? [])
                                    }
                                    Text(LocalizationHelper.formatted(
                                        "%d rides • %@",
                                        bucketRides.count,
                                        HistoryMetricFormat.km(totalKm)
                                    ))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                }
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
                    importGPX(from: url)
                case .failure:
                    ToastManager.shared.show(message: LocalizationHelper.localized("Failed to import. Please ensure the file is a valid GPX format."), style: .error)
                }
            }
        }
        .trackScreen("HistoryView")
    }

    private func importGPX(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            ToastManager.shared.show(message: LocalizationHelper.localized("Failed to import. Please ensure the file is a valid GPX format."), style: .error)
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let existingIds = Set(rides.flatMap { ride in
            [ride.id.uuidString.lowercased(), ride.firestoreId?.lowercased()].compactMap { $0 }
        })
        let parser = GPXParser()
        guard let ride = parser.parse(url: url) else {
            ToastManager.shared.show(message: LocalizationHelper.localized("Failed to import. Please ensure the file is a valid GPX format."), style: .error)
            return
        }
        if let importedId = parser.originalTrackMeId?.lowercased(), existingIds.contains(importedId) {
            ToastManager.shared.show(message: LocalizationHelper.localized("Identical ride already exists"), style: .info)
            return
        }
        modelContext.insert(ride)
        FirestoreSyncManager.shared.syncRide(ride)
        ToastManager.shared.show(message: LocalizationHelper.localized("GPX Imported Successfully"), style: .success)
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
                        .foregroundColor(ride.isSynced ? BrandColor.success : .orange)
                }

                HStack(spacing: 12) {
                    Label(ride.startTime.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                }
                .font(.caption2)
                .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Text(HistoryMetricFormat.km(metrics.distanceKm))
                        .font(.caption2.weight(.bold))
                        .foregroundColor(BrandColor.primary)
                    Text(HistoryMetricFormat.duration(metrics.duration))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(HistoryMetricFormat.kmh(metrics.avgSpeedKmh))
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                }
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
        let syncState = ride.isSynced
            ? LocalizationHelper.localized("Synced")
            : LocalizationHelper.localized("Not yet synced")
        return LocalizationHelper.formatted(
            "%@. %@. %@, %@, %@. %@",
            title,
            time,
            HistoryMetricFormat.km(metrics.distanceKm),
            HistoryMetricFormat.duration(metrics.duration),
            HistoryMetricFormat.kmh(metrics.avgSpeedKmh),
            syncState
        )
    }

    private var metrics: HistoryRideMetrics {
        HistoryRideMetrics(
            points: ride.points ?? [],
            startTime: ride.startTime,
            endTime: ride.endTime
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
                .background(isSelected ? BrandColor.primaryFill : Color(UIColor.tertiarySystemFill))
                .foregroundColor(isSelected ? BrandColor.onPrimary : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
