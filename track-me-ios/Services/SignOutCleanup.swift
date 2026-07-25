import Foundation

enum SignOutCleanup {
    enum Plan: Equatable { case none, endLiveShare }
    static func plan(liveShareActive: Bool) -> Plan {
        liveShareActive ? .endLiveShare : .none
    }
}
