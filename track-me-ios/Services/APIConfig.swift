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
    }
}
