import Foundation

nonisolated enum StatusSeverity: Character, Codable, CaseIterable, Comparable {
    case alert = "1"
    case caution = "2"
    case info = "3"

    static func < (lhs: StatusSeverity, rhs: StatusSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated enum StatusPersona: Character, Codable, CaseIterable {
    case generic = "G"
    case bikeDrive = "M"
    case carDrive = "C"
    case cycling = "B"
    case walk = "W"
    case run = "R"
    case auto = "A"

    init(ridePersona: RidePersona?) {
        switch ridePersona {
        case .bikeDrive: self = .bikeDrive
        case .carDrive: self = .carDrive
        case .cycling: self = .cycling
        case .walk: self = .walk
        case .run: self = .run
        case .auto: self = .auto
        case nil: self = .generic
        }
    }
}

nonisolated struct RiderStatus: Codable, Equatable, Identifiable {
    var id: String { raw }

    let code: String
    let severity: StatusSeverity
    let persona: StatusPersona?
    let message: String
    let extensionValue: String?
    let raw: String

    var isAlert: Bool { severity == .alert }
    var isKnown: Bool { RiderStatusCatalog.knownCodes.contains(code) }
    var labelKey: String { "groupStatus\(code)" }
}

nonisolated enum RiderStatusCodec {
    private static let pattern = #"^[0-9][A-Z][A-Z]{2}(:[A-Za-z0-9]{1,8})?$"#

    static func parse(_ raw: String?) -> RiderStatus? {
        guard let value = raw,
              !value.isEmpty,
              value.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(parts[0])
        let characters = Array(code)
        guard characters.count == 4 else { return nil }

        return RiderStatus(
            code: code,
            // Protocol invariant: 0 is reserved for a future tier above Alert, but every
            // unknown tier (including 0) must fail quiet to Info on a 1.7.2 client.
            // Do not derive priority by comparing or converting the wire digit.
            severity: StatusSeverity(rawValue: characters[0]) ?? .info,
            persona: StatusPersona(rawValue: characters[1]),
            message: String(characters[2...3]),
            extensionValue: parts.count == 2 ? String(parts[1]) : nil,
            raw: value
        )
    }

    static func encode(code: String, extensionValue: String? = nil) -> String {
        guard let extensionValue,
              !extensionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return code
        }
        return "\(code):\(extensionValue)"
    }
}

nonisolated enum RiderStatusCatalog {
    static let shortBreak = "3GBR"
    static let tired = "3GTI"
    static let vehicleIssue = "2GVI"
    static let needHelp = "1GNH"
    static let crashed = "1GCR"

    static let fuelStopBike = "3MFS"
    static let engineHeat = "2MEH"
    static let fuelStopCar = "3CFS"
    static let onACall = "3CIC"
    static let waterBreakCycle = "3BWA"
    static let puncture = "2BPU"
    static let waterBreakWalk = "3WWA"
    static let waterBreakRun = "3RWA"

    static func options(for persona: StatusPersona?) -> [RiderStatus] {
        let codes: [String] = switch persona {
        case .bikeDrive:
            [fuelStopBike, shortBreak, engineHeat, vehicleIssue, needHelp]
        case .carDrive:
            [fuelStopCar, shortBreak, onACall, vehicleIssue, needHelp]
        case .cycling:
            [waterBreakCycle, shortBreak, puncture, vehicleIssue, needHelp]
        case .walk:
            [waterBreakWalk, shortBreak, tired, needHelp]
        case .run:
            [waterBreakRun, shortBreak, tired, needHelp]
        case .auto, .generic, nil:
            [shortBreak, tired, vehicleIssue, needHelp]
        }
        return codes.compactMap(RiderStatusCodec.parse)
    }

    static let knownCodes: Set<String> = [
        shortBreak, tired, vehicleIssue, needHelp, crashed,
        fuelStopBike, engineHeat, fuelStopCar, onACall,
        waterBreakCycle, puncture, waterBreakWalk, waterBreakRun
    ]
}
