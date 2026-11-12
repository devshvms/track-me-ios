import Foundation

struct APIConfig {
    static let baseURL = "https://trackme.shvms.in"
    
    struct LiveShare {
        static let startSession = "\(APIConfig.baseURL)/api/track/start"
        
        static func locationPush(sessionId: String) -> String {
            return "\(APIConfig.baseURL)/api/track/\(sessionId)/location"
        }
        
        static func stopSession(sessionId: String) -> String {
            return "\(APIConfig.baseURL)/api/track/\(sessionId)/stop"
        }

        static func viewerPing(sessionId: String) -> String {
            return "\(APIConfig.baseURL)/api/track/\(sessionId)/ping"
        }

        static func watcherInviteLink(inviterUid: String, inviterName: String?) -> String {
            var components = URLComponents(string: "\(APIConfig.baseURL)/live/watcher")!
            var items = [URLQueryItem(name: "inviterUid", value: inviterUid)]
            if let cleanName = inviterName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cleanName.isEmpty {
                items.append(URLQueryItem(name: "inviterName", value: cleanName))
            }
            components.queryItems = items
            return components.url?.absoluteString ?? "\(APIConfig.baseURL)/live/watcher?inviterUid=\(inviterUid)"
        }
    }
}
