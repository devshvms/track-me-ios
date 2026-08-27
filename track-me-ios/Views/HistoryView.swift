import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private struct HistoryRideSummary: Identifiable, Hashable {
    let id: UUID
    let startTime: Date
    let endTime: Date?
    let isSynced: Bool
    let pendingDelete: Bool
    let title: String?
    let persona: RidePersona
    let isSample: Bool
    let distanceMeters: Double
    let movingDurationMillis: Int64?
    let avgSpeedMps: Double
    let pointCount: Int

    init(ride: Ride) {
        id = ride.id
        startTime = ride.startTime
        endTime = ride.endTime
        isSynced = ride.isSynced
        pendingDelete = ride.pendingDelete
        title = ride.title
        persona = ride.ridePersona
        isSample = ride.isSample
        distanceMeters = max(0, ride.distanceMeters ?? 0)
        movingDurationMillis = ride.movingDurationMillis.map { max(0, $0) }
        avgSpeedMps = max(0, ride.avgSpeedMps ?? 0)
        pointCount = max(0, ride.pointCount ?? 0)
    }
}

private enum HistoryDateRange: Hashable {
    case any, thisMonth, last3Months, thisYear, custom
}

struct HistoryView: View {
    var scrollToTopRequest: Int = 0
    /// TASK-226: bumped when the rider double-taps this tab. Pops back to the list.
    var popToRootRequest: Int = 0
    @State private var navigationPath: [UUID] = []
    @State private var summaries: [HistoryRideSummary] = []
    @State private var showFileImporter = false
    @State private var showCustomRange = false
    @State private var searchText = ""
    @State private var selectedPersonas = Set(RidePersona.allCases)
    @State private var dateRange: HistoryDateRange = .any
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var selectedDistanceThresholdKm: Double = 0
    @State private var filterRevision = 0
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var unitSettings = UnitSettings.shared

    private var filteredSummaries: [HistoryRideSummary] {
        summaries.filter { summary in
            selectedPersonas.contains(summary.persona)
                && matchesSearch(summary.title ?? "")
                && matchesDate(summary.startTime)
                && summary.distanceMeters / 1000 >= selectedDistanceThresholdKm
        }
    }

    private var groupedSummaries: [DateBucket: [HistoryRideSummary]] {
        Dictionary(grouping: filteredSummaries) { LocalizationHelper.bucket(for: $0.startTime) }
    }

    private var hasActiveFilters: Bool {
        !searchText.isEmpty
            || selectedPersonas.count != RidePersona.allCases.count
            || dateRange != .any
            || selectedDistanceThresholdKm > 0
    }

    var body: some View {
        let distanceOptions: [(label: String, minKm: Double)] = [
            (LocalizationHelper.localized("Any Distance"), 0),
            (unitSettings.unit == .imperial ? "> 3 mi" : "> 5 km", 5),
            (unitSettings.unit == .imperial ? "> 12 mi" : "> 20 km", 20),
            (unitSettings.unit == .imperial ? "> 31 mi" : "> 50 km", 50)
        ]

        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                TextField(LocalizationHelper.localized("Search rides"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        personaMenu
                        dateRangeMenu
                        ForEach(distanceOptions, id: \.minKm) { option in
                            FilterChipView(
                                title: option.label,
                                isSelected: selectedDistanceThresholdKm == option.minKm
                            ) { selectedDistanceThresholdKm = option.minKm }
                        }
                        if hasActiveFilters {
                            Button(LocalizationHelper.localized("Reset"), action: resetFilters)
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground))

                List {
                    ForEach(DateBucket.allCases, id: \.self) { bucket in
                        if let bucketSummaries = groupedSummaries[bucket], !bucketSummaries.isEmpty {
                            Section {
                                ForEach(bucketSummaries) { summary in
                                    HStack(spacing: 8) {
                                        NavigationLink(value: summary.id) {
                                            CompactRideSummaryRow(summary: summary)
                                        }
                                        if summary.isSample {
                                            Button(role: .destructive) { deleteSampleRide(id: summary.id) } label: {
                                                Image(systemName: "trash").frame(width: 44, height: 44)
                                            }
                                            .buttonStyle(.borderless)
                                            .accessibilityLabel(LocalizationHelper.localized("Delete Ride"))
                                        }
                                    }
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                }
                            } header: {
                                HStack {
                                    Text(bucket.localizedTitle()).font(.footnote.weight(.semibold))
                                    Spacer()
                                    Text(LocalizationHelper.formatted(
                                        "%d rides • %@",
                                        bucketSummaries.count,
                                        HistoryMetricFormat.km(bucketSummaries.reduce(0) { $0 + $1.distanceMeters / 1000 })
                                    ))
                                    .font(.caption2)
                                }
                                .textCase(nil)
                            }
                        }
                    }
                }
                .id(scrollToTopRequest &+ filterRevision)
                .listStyle(.insetGrouped)
                .overlay {
                    if filteredSummaries.isEmpty {
                        ContentUnavailableView(
                            hasActiveFilters ? LocalizationHelper.localized("No rides match these filters.") : LocalizationHelper.localized("No rides recorded yet."),
                            systemImage: "bicycle",
                            description: hasActiveFilters ? Text(LocalizationHelper.localized("Reset")) : nil
                        )
                    }
                }
            }
            .navigationDestination(for: UUID.self) { rideId in
                detail(for: rideId)
            }
            .navigationTitle(LocalizationHelper.localized("History"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showFileImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.xml, .init(filenameExtension: "gpx")!]) { result in
                if case .success(let url) = result { importGPX(from: url) }
            }
            .task { loadSummaries() }
            .onChange(of: searchText) { _, _ in filterRevision += 1 }
            .onChange(of: selectedPersonas) { _, _ in filterRevision += 1 }
            .onChange(of: dateRange) { _, _ in filterRevision += 1 }
            .onChange(of: selectedDistanceThresholdKm) { _, _ in filterRevision += 1 }
        }
        // TASK-226: double-tapping the tab returns to the list. `removeAll` rather than a fresh
        // stack identity, so the search text, the filters and the scroll position all survive —
        // popping is not the same thing as starting over.
        .onChange(of: popToRootRequest) { _, _ in navigationPath.removeAll() }
        .trackScreen("HistoryView")
        .sheet(isPresented: $showCustomRange) {
            NavigationStack {
                Form {
                    DatePicker(LocalizationHelper.localized("Start date"), selection: $customStart, displayedComponents: .date)
                    DatePicker(LocalizationHelper.localized("End date"), selection: $customEnd, displayedComponents: .date)
                }
                .navigationTitle(LocalizationHelper.localized("Custom range…"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LocalizationHelper.localized("Done")) { showCustomRange = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private var personaMenu: some View {
        Menu {
            ForEach(RidePersona.allCases, id: \.self) { persona in
                Button {
                    if selectedPersonas.contains(persona) { selectedPersonas.remove(persona) }
                    else { selectedPersonas.insert(persona) }
                } label: {
                    Label(LocalizationHelper.localized(persona.displayName), systemImage: selectedPersonas.contains(persona) ? "checkmark" : persona.systemImage)
                }
            }
        } label: {
            Label(LocalizationHelper.localized("Activity"), systemImage: "figure.walk")
        }
        .buttonStyle(.bordered)
    }

    private var dateRangeMenu: some View {
        Menu {
            dateButton(.any, "Any time")
            dateButton(.thisMonth, "This month")
            dateButton(.last3Months, "Last 3 months")
            dateButton(.thisYear, "This year")
            Button(LocalizationHelper.localized("Custom range…")) {
                dateRange = .custom
                showCustomRange = true
            }
        } label: {
            Label(dateRangeTitle, systemImage: "calendar")
        }
        .buttonStyle(.bordered)
    }

    private func dateButton(_ range: HistoryDateRange, _ title: String) -> some View {
        Button {
            dateRange = range
            if range != .custom { showCustomRange = false }
        } label: {
            Label(LocalizationHelper.localized(title), systemImage: dateRange == range ? "checkmark" : "calendar")
        }
    }

    private var dateRangeTitle: String {
        switch dateRange {
        case .any: LocalizationHelper.localized("Any time")
        case .thisMonth: LocalizationHelper.localized("This month")
        case .last3Months: LocalizationHelper.localized("Last 3 months")
        case .thisYear: LocalizationHelper.localized("This year")
        case .custom: LocalizationHelper.localized("Custom range…")
        }
    }

    private func loadSummaries() {
        var descriptor = FetchDescriptor<Ride>(
            predicate: #Predicate { $0.endTime != nil && $0.endTime! > $0.startTime },
            sortBy: [SortDescriptor(\Ride.startTime, order: .reverse)]
        )
        descriptor.propertiesToFetch = [
            \Ride.id, \Ride.startTime, \Ride.endTime, \Ride.isSynced, \Ride.pendingDelete,
            \Ride.title, \Ride.persona, \Ride.isSample, \Ride.distanceMeters,
            \Ride.movingDurationMillis, \Ride.avgSpeedMps, \Ride.pointCount
        ]
        summaries = (try? modelContext.fetch(descriptor).map(HistoryRideSummary.init(ride:))) ?? []
    }

    private func detail(for id: UUID) -> some View {
        var descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let ride = try? modelContext.fetch(descriptor).first {
            return AnyView(RideDetailView(ride: ride))
        }
        return AnyView(ContentUnavailableView(LocalizationHelper.localized("Activity unavailable"), systemImage: "clock.badge.exclamationmark"))
    }

    private func matchesSearch(_ title: String) -> Bool {
        guard !searchText.isEmpty else { return true }
        let foldedTitle = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let foldedQuery = searchText.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return foldedTitle.contains(foldedQuery)
    }

    private func matchesDate(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let start: Date?
        switch dateRange {
        case .any: start = nil
        case .thisMonth: start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))
        case .last3Months: start = calendar.date(byAdding: .month, value: -3, to: Date())
        case .thisYear: start = calendar.date(from: calendar.dateComponents([.year], from: Date()))
        case .custom: start = customStart
        }
        guard let start else { return true }
        return date >= start && date <= (dateRange == .custom ? customEnd : Date())
    }

    private func resetFilters() {
        searchText = ""
        selectedPersonas = Set(RidePersona.allCases)
        dateRange = .any
        selectedDistanceThresholdKm = 0
    }

    private func importGPX(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let ride = GPXParser().parse(url: url) else { return }
        ride.refreshDashboardMetadata()
        modelContext.insert(ride)
        try? modelContext.save()
        loadSummaries()
        HomeDashboardRepository.shared.invalidate()
        FirestoreSyncManager.shared.syncRide(ride)
    }

    private func deleteSampleRide(id: UUID) {
        var descriptor = FetchDescriptor<Ride>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let rides = try? modelContext.fetch(descriptor),
              let ride = rides.first,
              ride.isSample else { return }
        modelContext.delete(ride)
        try? modelContext.save()
        loadSummaries()
        HomeDashboardRepository.shared.invalidate()
    }
}

private struct CompactRideSummaryRow: View {
    let summary: HistoryRideSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: summary.pointCount > 0 ? "point.topleft.down.to.point.bottomright.curvepath" : "location.slash")
                .font(.title3)
                .foregroundStyle(BrandColor.primary)
                .frame(width: 52, height: 52)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: summary.persona.systemImage).foregroundStyle(.secondary)
                    Text(summary.title ?? LocalizationHelper.localized("TrackMe Ride"))
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Image(systemName: summary.isSynced ? "checkmark.icloud.fill" : "exclamationmark.icloud")
                        .foregroundStyle(summary.isSynced ? BrandColor.success : .orange)
                }
                Text(summary.startTime.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(HistoryMetricFormat.km(summary.distanceMeters / 1000)).font(.caption2.weight(.bold)).foregroundStyle(BrandColor.primary)
                    Text(summary.movingDurationMillis.map { HistoryMetricFormat.duration(TimeInterval($0) / 1000) } ?? LocalizationHelper.localized("Unknown"))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(HistoryMetricFormat.kmh(summary.avgSpeedMps * 3.6)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CompactRideRowView: View {
    let ride: Ride

    var body: some View {
        CompactRideSummaryRow(summary: HistoryRideSummary(ride: ride))
    }
}

struct FilterChipView: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 6)
                .background(isSelected ? BrandColor.primaryFill : Color(uiColor: .tertiarySystemFill))
                .foregroundColor(isSelected ? BrandColor.onPrimary : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
