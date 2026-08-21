/// Platform-neutral voice contract for SCOPE_1.8.4 TASK-192.
///
/// Platform intent adapters own invocation and spoken rendering. This layer only evaluates an
/// immutable snapshot that the caller already holds in memory. It performs no I/O, reads no clock,
/// and returns structures rather than catalogue text.
nonisolated enum VoiceAction: CaseIterable, Equatable {
    case start
    case pause
    case resume
    case end

    var intent: VoiceIntent {
        switch self {
        case .start: .start
        case .pause: .pause
        case .resume: .resume
        case .end: .end
        }
    }
}

nonisolated enum VoicePersonalQuery: CaseIterable, Equatable {
    case distance
    case paceOrSpeed
    case duration

    var intent: VoiceIntent {
        switch self {
        case .distance: .personalDistance
        case .paceOrSpeed: .personalPaceOrSpeed
        case .duration: .personalDuration
        }
    }

    var queryIntent: VoiceQueryIntent {
        switch self {
        case .distance: .personalDistance
        case .paceOrSpeed: .personalPaceOrSpeed
        case .duration: .personalDuration
        }
    }
}

nonisolated enum VoiceGroupQuery: CaseIterable, Equatable {
    case memberLocation
    case roster
    case safetyStatus

    var intent: VoiceIntent {
        switch self {
        case .memberLocation: .groupMemberLocation
        case .roster: .groupRoster
        case .safetyStatus: .groupSafetyStatus
        }
    }

    var queryIntent: VoiceQueryIntent {
        switch self {
        case .memberLocation: .groupMemberLocation
        case .roster: .groupRoster
        case .safetyStatus: .groupSafetyStatus
        }
    }
}

/// Values are the shared Android/iOS telemetry vocabulary, not user utterances.
nonisolated enum VoiceIntent: String, CaseIterable, Equatable {
    case start
    case pause
    case resume
    case end
    case personalDistance = "personal_distance"
    case personalPaceOrSpeed = "personal_pace_or_speed"
    case personalDuration = "personal_duration"
    case groupMemberLocation = "group_member_location"
    case groupRoster = "group_roster"
    case groupSafetyStatus = "group_safety_status"
}

/// The query-only subset accepted by `voice_query_answered`.
nonisolated enum VoiceQueryIntent: String, CaseIterable, Equatable {
    case personalDistance = "personal_distance"
    case personalPaceOrSpeed = "personal_pace_or_speed"
    case personalDuration = "personal_duration"
    case groupMemberLocation = "group_member_location"
    case groupRoster = "group_roster"
    case groupSafetyStatus = "group_safety_status"
}

nonisolated enum VoiceSurface: String, CaseIterable, Equatable {
    case assistant
    case appShortcut = "app_shortcut"
}

/// Closed failure vocabulary. Never replace this with exception or assistant prose.
nonisolated enum VoiceFailureReason: String, CaseIterable, Equatable {
    case noActiveRide = "no_active_ride"
    case invalidRideState = "invalid_ride_state"
    case noActiveGroup = "no_active_group"
    case emptyCache = "empty_cache"
    case degraded
    case locked
    case memberNotFound = "member_not_found"
    case ambiguousMember = "ambiguous_member"
    case unavailable
}

nonisolated enum VoiceFreshnessBucket: String, CaseIterable, Equatable {
    case now
    case seconds
    case minutes
    case hours
    case unknown
}

nonisolated enum VoiceFreshness: Equatable {
    case now
    case seconds(Int)
    case minutes(Int)
    case hours(Int)
    case unknown

    var bucket: VoiceFreshnessBucket {
        switch self {
        case .now: .now
        case .seconds: .seconds
        case .minutes: .minutes
        case .hours: .hours
        case .unknown: .unknown
        }
    }
}

nonisolated enum VoiceGroupConnection: Equatable {
    case current
    case degraded
}

/// The smallest member cache shape TASK-192 needs. The key is local routing identity and is never
/// admitted to telemetry. Position/direction/status facts are added by TASK-195 without changing
/// the availability and freshness contract established here.
nonisolated struct VoiceGroupMemberCache: Equatable {
    let cacheKey: String
    let displayName: String?
    let positionAgeAnchor: StatusAge.Anchor?
}

nonisolated struct VoiceGroupCacheSnapshot: Equatable {
    let isActive: Bool
    let isDegraded: Bool
    let syncIntervalSec: Int
    let members: [VoiceGroupMemberCache]

    static let noActiveGroup = VoiceGroupCacheSnapshot(
        isActive: false,
        isDegraded: false,
        syncIntervalSec: 1,
        members: []
    )
}

nonisolated struct VoiceGroupMemberFact: Equatable {
    let cacheKey: String
    let displayName: String?
    let freshness: VoiceFreshness
}

nonisolated enum VoiceGroupCacheResult: Equatable {
    case noActiveGroup
    case empty(connection: VoiceGroupConnection)
    case available(connection: VoiceGroupConnection, members: [VoiceGroupMemberFact])
}

nonisolated enum VoiceCommand: Equatable {
    case action(VoiceAction)
    case personalQuery(VoicePersonalQuery)
    case groupQuery(VoiceGroupQuery)

    var intent: VoiceIntent {
        switch self {
        case let .action(action): action.intent
        case let .personalQuery(query): query.intent
        case let .groupQuery(query): query.intent
        }
    }
}

nonisolated enum VoiceCommandResult: Equatable {
    /// END always confirms; adapters may not override `requiresConfirmation`.
    case actionReady(action: VoiceAction, requiresConfirmation: Bool)
    case personalQueryReady(VoicePersonalQuery)
    case groupQueryReady(query: VoiceGroupQuery, cache: VoiceGroupCacheResult)
}

nonisolated enum VoiceCommandController {
    ///
    /// Synchronous by construction. `nowElapsedMillis` is supplied by the platform adapter
    /// alongside the in-memory snapshot; this layer never reaches for wall or monotonic time.
    static func evaluate(
        _ command: VoiceCommand,
        groupSnapshot: VoiceGroupCacheSnapshot = .noActiveGroup,
        nowElapsedMillis: Int64 = 0
    ) -> VoiceCommandResult {
        switch command {
        case let .action(action):
            .actionReady(action: action, requiresConfirmation: action == .end)
        case let .personalQuery(query):
            .personalQueryReady(query)
        case let .groupQuery(query):
            .groupQueryReady(
                query: query,
                cache: evaluateGroupCache(groupSnapshot, nowElapsedMillis: nowElapsedMillis)
            )
        }
    }

    static func evaluateGroupCache(
        _ snapshot: VoiceGroupCacheSnapshot,
        nowElapsedMillis: Int64
    ) -> VoiceGroupCacheResult {
        guard snapshot.isActive else { return .noActiveGroup }
        let connection: VoiceGroupConnection = snapshot.isDegraded ? .degraded : .current
        guard !snapshot.members.isEmpty else { return .empty(connection: connection) }
        return .available(
            connection: connection,
            members: snapshot.members.map { member in
                VoiceGroupMemberFact(
                    cacheKey: member.cacheKey,
                    displayName: member.displayName,
                    freshness: member.positionAgeAnchor.map {
                        StatusAge.bucket(
                            anchor: $0,
                            nowElapsedMillis: nowElapsedMillis,
                            syncIntervalSec: snapshot.syncIntervalSec
                        ).voiceFreshness
                    } ?? .unknown
                )
            }
        )
    }
}

private nonisolated extension StatusAge.Bucket {
    var voiceFreshness: VoiceFreshness {
        switch self {
        case .now: .now
        case let .seconds(value): .seconds(value)
        case let .minutes(value): .minutes(value)
        case let .hours(value): .hours(value)
        case .unknown: .unknown
        }
    }
}

/// A pure event descriptor; TelemetryManager/PostHog integration belongs to the platform cards.
nonisolated struct VoiceTelemetryEvent: Equatable {
    let name: String
    let properties: [String: String]
}

nonisolated enum VoiceTelemetryContract {
    static func commandInvoked(intent: VoiceIntent, surface: VoiceSurface) -> VoiceTelemetryEvent {
        VoiceTelemetryEvent(
            name: "voice_command_invoked",
            properties: [
                "intent": intent.rawValue,
                "surface": surface.rawValue
            ]
        )
    }

    static func commandFailed(intent: VoiceIntent, reason: VoiceFailureReason) -> VoiceTelemetryEvent {
        VoiceTelemetryEvent(
            name: "voice_command_failed",
            properties: [
                "intent": intent.rawValue,
                "reason": reason.rawValue
            ]
        )
    }

    static func queryAnswered(intent: VoiceQueryIntent, freshness: VoiceFreshnessBucket) -> VoiceTelemetryEvent {
        VoiceTelemetryEvent(
            name: "voice_query_answered",
            properties: [
                "intent": intent.rawValue,
                "freshness_bucket": freshness.rawValue
            ]
        )
    }
}
