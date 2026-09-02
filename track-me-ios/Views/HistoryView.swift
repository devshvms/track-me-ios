import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Shared with Community (TASK-232) so its list is *this* card rather than a second one that
/// drifts from it. Still a projection: `propertiesToFetch` keeps route points out of the fetch.
struct HistoryRideSummary: Identifiable, Hashable {
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
    /// TASK-232: recorded during a group session, and how many rode. A count, never names.
    let wasGroupRide: Bool
    let groupRiderCount: Int?
    /// TASK-246: the card's route shape, on the row. Still no fetch of `points`.
    let routePolyline: String?

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
        wasGroupRide = ride.wasGroupRide
        groupRiderCount = ride.groupRiderCount.flatMap { $0 > 0 ? $0 : nil }
        routePolyline = ride.routePolyline
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
    @State private var searchExpanded = false
    @FocusState private var searchFieldFocused: Bool
    @State private var summaries: [HistoryRideSummary] = []
    @State private var showFileImporter = false
    /// TASK-275: shown when an import is refused as a duplicate. Silence would read as a no-op.
    @State private var importMessage: String?
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
                // TASK-243, Android parity. Search collapses to an icon in the filter row and
                // expands to a full field only while in use: a permanently open text field spent a
                // whole row of the list on a control that is empty almost always, and History is
                // scanned far more often than it is searched. Expanded state is held open by a
                // non-empty query so the field cannot collapse while it is still filtering.
                if searchExpanded || !searchText.isEmpty {
                    HStack(spacing: 8) {
                        TextField(LocalizationHelper.localized("Search rides"), text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .focused($searchFieldFocused)
                        Button {
                            searchText = ""
                            searchExpanded = false
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(LocalizationHelper.localized("Close"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    // Opening without the caret in the field would make the tap feel inert.
                    .onAppear { searchFieldFocused = true }
                }

                HStack(spacing: 8) {
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
                // Pinned outside the horizontal scroll so it never scrolls out of reach the way it
                // would as just another chip.
                if !(searchExpanded || !searchText.isEmpty) {
                    Button { searchExpanded = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .padding(.trailing, 16)
                    .accessibilityLabel(LocalizationHelper.localized("Search rides"))
                }
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
            // TASK-275: a refused import must say so. Dropping the file silently is
            // indistinguishable from the picker having failed.
            .alert(
                importMessage ?? "",
                isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })
            ) {
                Button(LocalizationHelper.localized("OK"), role: .cancel) { importMessage = nil }
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
            // A force-unwrapped optional inside #Predicate -- `$0.endTime != nil &&
            // $0.endTime! > $0.startTime` -- translates to a query that matches nothing, so this
            // screen showed "No rides recorded yet." for every rider regardless of their data.
            // The nil check is expressible; the ordering guard is applied in Swift below, which is
            // free here because the projection is already bounded.
            predicate: #Predicate { $0.endTime != nil },
            sortBy: [SortDescriptor(\Ride.startTime, order: .reverse)]
        )
        descriptor.propertiesToFetch = [
            \Ride.id, \Ride.startTime, \Ride.endTime, \Ride.isSynced, \Ride.pendingDelete,
            \Ride.title, \Ride.persona, \Ride.isSample, \Ride.distanceMeters,
            \Ride.movingDurationMillis, \Ride.avgSpeedMps, \Ride.pointCount,
            \Ride.wasGroupRide, \Ride.groupRiderCount, \Ride.routePolyline
        ]
        summaries = (try? modelContext.fetch(descriptor)
            .filter { ride in ride.endTime.map { $0 > ride.startTime } ?? false }
            .map(HistoryRideSummary.init(ride:))) ?? []
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
        // Both guards used to return silently, which the alert below exists to prevent: a rider who
        // picks a file and sees nothing happen cannot tell a rejected file from a broken picker.
        guard url.startAccessingSecurityScopedResource() else {
            importMessage = LocalizationHelper.localized("Could not open that file")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let ride = GPXParser().parse(url: url) else {
            importMessage = LocalizationHelper.localized("That file is not a readable GPX track")
            return
        }
        // TASK-275: the typed provenance fact. `sourceInfo` is free text for display and is not
        // safe to branch on; qualification reads this.
        ride.source = RideSource.imported
        // Computes the content hash alongside the route shape, so the duplicate check below has
        // something to compare.
        ride.refreshDashboardMetadata()

        // TASK-275: dedupe by track identity. This path previously had no duplicate check at all —
        // not even the id check Android had — so importing the same file twice produced two rides
        // and double-counted its minutes in every aggregate, with nobody acting in bad faith.
        if let hash = ride.contentHash {
            var descriptor = FetchDescriptor<Ride>(
                predicate: #Predicate { $0.contentHash == hash && $0.pendingDelete == false }
            )
            descriptor.fetchLimit = 1
            if let existing = try? modelContext.fetch(descriptor), existing.isEmpty == false {
                importMessage = LocalizationHelper.localized("This ride is already in your history")
                return
            }
        }
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

struct CompactRideSummaryRow: View {
    let summary: HistoryRideSummary
    /// TASK-232: an extra fact the caller wants on the metrics row. Community passes the group's
    /// rider count here. Nil on every other call site, which is every call site but one.
    var trailingLabel: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            // TASK-246: the ride's own route again, as in 1.8.4. The shape comes off the row, so
            // the projection still never fetches `points` -- which was the reason 1.8.5 replaced
            // this with a single glyph in the first place.
            RouteThumbnail(
                routePolyline: summary.routePolyline,
                pointCount: summary.pointCount,
                distanceMeters: summary.distanceMeters
            )
            .frame(width: 52, height: 52)
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
                Text(LocalizationHelper.mediumDateTime(summary.startTime, includeTime: true))
                    .font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(HistoryMetricFormat.km(summary.distanceMeters / 1000)).font(.caption2.weight(.bold)).foregroundStyle(BrandColor.primary)
                    Text(summary.movingDurationMillis.map { HistoryMetricFormat.duration(TimeInterval($0) / 1000) } ?? LocalizationHelper.localized("Unknown"))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(HistoryMetricFormat.kmh(summary.avgSpeedMps * 3.6)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if let trailingLabel {
                        Text(trailingLabel).font(.caption2).foregroundStyle(.secondary)
                    }
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
