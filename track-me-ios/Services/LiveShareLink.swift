import Foundation

/// TASK-368 / SCOPE_1.9.3: cross-platform `/live` deep-link parser for Universal Links
/// (`https://trackme.shvms.in/live/...`), custom-scheme links (`trackme://live/...` or
/// `trackme://live?sessionId=...`), and `live_share_started` push notification payloads.
enum LiveShareDeepLink: Equatable {
    case session(String)
    case watcherInvite(ParsedWatcherInviteLink)
}

enum LiveShareLink {
    private static let allowedHttpsHosts: Set<String> = ["trackme.shvms.in", "www.trackme.shvms.in"]

    static func parse(url: URL) -> LiveShareDeepLink? {
        if let invite = TrustedWatchersManager.parseWatcherInviteLink(url) {
            return .watcherInvite(invite)
        }
        if let sessionId = parseSessionURL(url) {
            return .session(sessionId)
        }
        return nil
    }

    static func parse(
        urlString: String?,
        extraSessionId: String? = nil,
        extraType: String? = nil,
        extraShareUrl: String? = nil
    ) -> LiveShareDeepLink? {
        if let urlString, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
           let parsed = parse(url: url) {
            return parsed
        }

        if extraType == "live_share_started" {
            if let fromExtra = extraSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
               isValidSessionId(fromExtra) {
                return .session(fromExtra)
            }
            if let extraShareUrl,
               let url = URL(string: extraShareUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
               let parsed = parseSessionURL(url) {
                return .session(parsed)
            }
        }

        return nil
    }

    static func parseSessionURL(_ url: URL) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let segments = url.pathComponents.filter { $0 != "/" }

        if (scheme == "https" || scheme == "http"), allowedHttpsHosts.contains(host) {
            guard segments.count >= 2, segments[0].lowercased() == "live" else {
                return nil
            }
            let candidate = segments[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.lowercased() != "watcher", isValidSessionId(candidate) else {
                return nil
            }
            return candidate
        }

        if scheme == "trackme", host == "live" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let querySession = components.queryItems?.first(where: { $0.name == "sessionId" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               isValidSessionId(querySession) {
                return querySession
            }
            if let firstSegment = segments.first?.trimmingCharacters(in: .whitespacesAndNewlines),
               firstSegment.lowercased() != "watcher",
               isValidSessionId(firstSegment) {
                return firstSegment
            }
        }

        return nil
    }

    static func isValidSessionId(_ value: String) -> Bool {
        guard value.count >= 4, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)     // 0-9
                || (scalar.value >= 65 && scalar.value <= 90)  // A-Z
                || (scalar.value >= 97 && scalar.value <= 122) // a-z
                || scalar == "_" || scalar == "-"
        }
    }
}
