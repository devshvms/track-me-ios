import SwiftUI

struct HomeDashboardDeck: View {
    let summary: HomeDashboardSummary?
    let isReconciling: Bool
    let routePoints: [HomeDashboardRoutePoint]
    let groupActive: Bool
    let groupMemberCount: Int
    let syncNeedsAction: Bool
    let isOffline: Bool
    let isVisible: Bool
    let onOpenRecent: (HomeRecentActivity) -> Void
    let onOpenHistory: () -> Void
    let onOpenCommunity: () -> Void
    let onOpenGroupMap: () -> Void
    let scrollToTopRequest: Int

    @ObservedObject private var unitSettings = UnitSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if let summary, !isReconciling || summary.lifetimeActivityCount > 0 {
                    contextualCard
                        .dashboardCardMotion(
                            orderFromTop: 0,
                            total: 4,
                            isVisible: isVisible,
                            reduceMotion: reduceMotion
                        )

                    Group {
                        if summary.lifetimeActivityCount == 0 {
                            EmptyDashboardCard()
                        } else {
                            WeeklySummaryCard(summary: summary, unit: unitSettings.unit)
                        }
                    }
                    .dashboardCardMotion(
                        orderFromTop: 1,
                        total: 4,
                        isVisible: isVisible,
                        reduceMotion: reduceMotion
                    )

                    if isReconciling, summary.lifetimeActivityCount > 0 {
                        Text(LocalizationHelper.localized("Preparing your activity history…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }

                    if let insight = summary.insight {
                        InsightCard(insight: insight)
                            .dashboardCardMotion(
                                orderFromTop: 2,
                                total: 4,
                                isVisible: isVisible,
                                reduceMotion: reduceMotion
                            )
                    }

                    if let recent = summary.latestActivity {
                        RecentActivityCard(
                            recent: recent,
                            routePoints: routePoints,
                            unit: unitSettings.unit,
                            onOpen: { onOpenRecent(recent) },
                            onOpenHistory: onOpenHistory
                        )
                        .dashboardCardMotion(
                            orderFromTop: 3,
                            total: 4,
                            isVisible: isVisible,
                            reduceMotion: reduceMotion
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            // The bottom radial control is fixed outside this scroll surface and remains
            // actionable at every Dynamic Type size.
            .padding(.bottom, 340)
        }
        .id(scrollToTopRequest)
        .scrollIndicators(.hidden)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
    }

    @ViewBuilder
    private var contextualCard: some View {
        if groupActive {
            DashboardCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label(
                        "\(LocalizationHelper.localized("Group session active")) • "
                            + LocalizationHelper.formatted("%@ members", String(groupMemberCount)),
                        systemImage: "person.2.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(BrandColor.primary)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { groupActions }
                        VStack(alignment: .leading, spacing: 8) { groupActions }
                    }
                }
            }
        } else if syncNeedsAction {
            Button(action: onOpenHistory) {
                DashboardCard {
                    Label(
                        LocalizationHelper.localized("Some history could not sync. Open History to retry."),
                        systemImage: "icloud.slash"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
        } else if isOffline {
            DashboardCard {
                Label(
                    LocalizationHelper.localized("Your dashboard and recording stay available offline."),
                    systemImage: "checkmark.shield"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var groupActions: some View {
        Button(LocalizationHelper.localized("Open Community"), action: onOpenCommunity)
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        Button(LocalizationHelper.localized("View live map"), action: onOpenGroupMap)
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
    }
}

private struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct EmptyDashboardCard: View {
    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 13) {
                Label(
                    LocalizationHelper.localized("Private by default • Works offline"),
                    systemImage: "lock.shield"
                )
                .font(.headline)
                .foregroundStyle(BrandColor.primary)

                preview("See weekly distance", icon: "chart.bar.fill")
                preview("See how this week compares", icon: "chart.line.uptrend.xyaxis")
                preview("Revisit recent routes", icon: "point.topleft.down.to.point.bottomright.curvepath")

                Text(LocalizationHelper.localized(
                    "Location is requested after Start so TrackMe can record your route."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func preview(_ key: String, icon: String) -> some View {
        Label(LocalizationHelper.localized(key), systemImage: icon)
            .font(.subheadline)
    }
}

private struct WeeklySummaryCard: View {
    let summary: HomeDashboardSummary
    let unit: UnitSystem

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(LocalizationHelper.localized("This week"))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) { metrics }
                    VStack(alignment: .leading, spacing: 10) { metrics }
                }

                if summary.displayStreakWeeks > 1 {
                    Text(LocalizationHelper.formatted(
                        "%@-week streak",
                        String(summary.displayStreakWeeks)
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                WeeklyDistanceChart(buckets: Array(summary.weeklyBuckets.suffix(4)), unit: unit)
            }
        }
    }

    @ViewBuilder
    private var metrics: some View {
        DashboardMetric(
            value: LocalizationHelper.formatted(
                "%@ activities",
                String(summary.currentWeek.activityCount)
            ),
            label: LocalizationHelper.localized("This week")
        )
        DashboardMetric(
            value: UnitFormatter.distance(
                meters: summary.currentWeek.distanceMeters,
                unit: unit
            ),
            label: LocalizationHelper.localized("Distance")
        )
        DashboardMetric(
            value: dashboardDuration(summary.currentWeek.activeDurationMillis),
            label: LocalizationHelper.localized("Duration")
        )
    }
}

private struct DashboardMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WeeklyDistanceChart: View {
    let buckets: [HomeWeeklyBucket]
    let unit: UnitSystem

    private var normalizedBuckets: [HomeWeeklyBucket] {
        let missing = max(0, 4 - buckets.count)
        let empty = HomeWeeklyBucket(
            weekStartEpochDay: 0,
            activityCount: 0,
            distanceMeters: 0,
            activeDurationMillis: 0
        )
        return Array(repeating: empty, count: missing) + buckets
    }

    private var accessibilityText: String {
        let values = normalizedBuckets.map {
            UnitFormatter.distance(meters: $0.distanceMeters, unit: unit)
        }
        return LocalizationHelper.formatted(
            "Four-week distance: %@, %@, %@, and %@",
            values[0], values[1], values[2], values[3]
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let maximum = max(1, normalizedBuckets.map(\.distanceMeters).max() ?? 1)
            let gap: CGFloat = 12
            let width = max(4, (proxy.size.width - gap * 3) / 4)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(normalizedBuckets.enumerated()), id: \.offset) { index, bucket in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(BrandColor.primary.opacity(index == 3 ? 1 : 0.45))
                        .frame(
                            width: width,
                            height: max(3, proxy.size.height * bucket.distanceMeters / maximum)
                        )
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

private struct InsightCard: View {
    let insight: HomeInsight

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(LocalizationHelper.localized("Insights"), systemImage: "lightbulb.max.fill")
                    .font(.headline)
                    .foregroundStyle(BrandColor.primary)
                Text(message).font(.body)
                Text(basis).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var message: String {
        switch insight {
        case let .returning(persona, inactiveDays):
            LocalizationHelper.formatted(
                "Welcome back to %@ after %@ days.",
                LocalizationHelper.localized(persona.displayName),
                String(inactiveDays)
            )
        case let .periodComparison(_, direction, _, _, _, _, _):
            switch direction {
            case .higher:
                LocalizationHelper.localized("You recorded more distance in the recent period.")
            case .stable:
                LocalizationHelper.localized("Your recent distance was steady.")
            case .lower:
                LocalizationHelper.localized("A lighter recent period.")
            }
        case let .dominantPersona(persona, _, _, _, _):
            LocalizationHelper.formatted(
                "%@ led your recent activities.",
                LocalizationHelper.localized(persona.displayName)
            )
        }
    }

    private var basis: String {
        switch insight {
        case let .periodComparison(_, _, current, comparison, _, _, _):
            return LocalizationHelper.localized("Based on comparable active weeks")
                + ": \(period(current)) · \(period(comparison))"
        case .returning, .dominantPersona:
            return LocalizationHelper.localized("Based on your qualifying activity history")
        }
    }

    private func period(_ period: HomeInsightPeriod) -> String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(
            from: HomeCalendar.date(fromEpochDay: period.startEpochDay),
            to: HomeCalendar.date(fromEpochDay: period.endEpochDay)
        )
    }
}

private struct RecentActivityCard: View {
    let recent: HomeRecentActivity
    let routePoints: [HomeDashboardRoutePoint]
    let unit: UnitSystem
    let onOpen: () -> Void
    let onOpenHistory: () -> Void

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizationHelper.localized("Recent activity"))
                    .font(.headline)

                Button(action: onOpen) {
                    HStack(spacing: 14) {
                        DashboardRouteThumbnail(points: routePoints)
                            .frame(width: 88, height: 88)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                LocalizationHelper.localized(recent.persona.displayName),
                                systemImage: recent.persona.systemImage
                            )
                            .font(.subheadline.bold())
                            Text(startedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(
                                "\(UnitFormatter.distance(meters: recent.distanceMeters, unit: unit))"
                                    + " • \(dashboardDuration(recent.activeDurationMillis))"
                            )
                            .font(.subheadline)
                            Text(movementValue)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(LocalizationHelper.localized("Open activity details"))

                Button(LocalizationHelper.localized("View all history"), action: onOpenHistory)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(minHeight: 44)
            }
        }
    }

    private var startedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(recent.startedAtEpochMillis) / 1_000)
    }

    private var movementValue: String {
        if recent.persona == .walk || recent.persona == .run {
            return UnitFormatter.pace(mps: recent.avgSpeedMps, unit: unit)
        }
        return UnitFormatter.speed(mps: recent.avgSpeedMps, unit: unit)
    }
}

private struct DashboardRouteThumbnail: View {
    let points: [HomeDashboardRoutePoint]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                if points.count < 2 {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .foregroundStyle(.secondary)
                } else {
                    Path { path in
                        let minLat = points.map(\.latitude).min() ?? 0
                        let maxLat = points.map(\.latitude).max() ?? 0
                        let minLng = points.map(\.longitude).min() ?? 0
                        let maxLng = points.map(\.longitude).max() ?? 0
                        let latSpan = max(0.001, maxLat - minLat)
                        let lngSpan = max(0.001, maxLng - minLng)
                        for (index, point) in points.enumerated() {
                            let x = 10 + (point.longitude - minLng) / lngSpan * (proxy.size.width - 20)
                            let y = 10 + (1 - (point.latitude - minLat) / latSpan) * (proxy.size.height - 20)
                            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(BrandColor.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
        }
    }
}

struct DashboardPersonaDock: View {
    let selectedPersona: RidePersona
    let suggestedPersonas: [RidePersona]
    let onSelectPersona: (RidePersona) -> Void
    let onOpenAll: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(LocalizationHelper.formatted(
                "Start %@",
                LocalizationHelper.localized(selectedPersona.displayName)
            ))
            .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(suggestedPersonas.prefix(3)), id: \.self) { persona in
                        Button {
                            onSelectPersona(persona)
                        } label: {
                            Label(
                                LocalizationHelper.localized(persona.displayName),
                                systemImage: persona.systemImage
                            )
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                    }
                    Button(LocalizationHelper.localized("Change activity"), action: onOpenAll)
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 380)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

struct DashboardPersonaPicker: View {
    let selectedPersona: RidePersona
    let onSelect: (RidePersona) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(RidePersona.allCases, id: \.self) { persona in
                Button {
                    onSelect(persona)
                    dismiss()
                } label: {
                    HStack {
                        Label(
                            LocalizationHelper.localized(persona.displayName),
                            systemImage: persona.systemImage
                        )
                        Spacer()
                        if persona == selectedPersona {
                            Image(systemName: "checkmark").foregroundStyle(BrandColor.primary)
                        }
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(LocalizationHelper.localized("Change activity"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizationHelper.localized("Close")) { dismiss() }
                }
            }
        }
    }
}

private struct DashboardCardMotionModifier: ViewModifier {
    let orderFromTop: Int
    let total: Int
    let isVisible: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let exitOrder = max(0, total - 1 - orderFromTop)
        let delay = Double(isVisible ? orderFromTop : exitOrder) * 0.04
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : -72)
            .animation(
                reduceMotion
                    ? nil
                    : .timingCurve(0.4, 0, 0.2, 1, duration: 0.42).delay(delay),
                value: isVisible
            )
    }
}

private extension View {
    func dashboardCardMotion(
        orderFromTop: Int,
        total: Int,
        isVisible: Bool,
        reduceMotion: Bool
    ) -> some View {
        modifier(DashboardCardMotionModifier(
            orderFromTop: orderFromTop,
            total: total,
            isVisible: isVisible,
            reduceMotion: reduceMotion
        ))
    }
}

private func dashboardDuration(_ millis: Int64) -> String {
    let minutesTotal = max(0, millis) / 60_000
    let hours = minutesTotal / 60
    let minutes = minutesTotal % 60
    if hours > 0 {
        return LocalizationHelper.formatted("%@h %@m", String(hours), String(minutes))
    }
    return LocalizationHelper.formatted("%@m", String(minutes))
}
