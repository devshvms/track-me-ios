import Foundation
import SwiftData

@Model
final class Ride {
    @Attribute(.unique) var id: UUID
    var startTime: Date
    var endTime: Date?
    var sourceInfo: String
    var isBroadcasted: Bool
    var isSynced: Bool
    var firestoreId: String?
    var title: String?
    
    @Relationship(deleteRule: .cascade, inverse: \GPSPoint.ride)
    var points: [GPSPoint]?
    
    init(id: UUID = UUID(), startTime: Date = Date(), sourceInfo: String = "iOS Device", isBroadcasted: Bool = false, isSynced: Bool = false, title: String? = nil) {
        self.id = id
        self.startTime = startTime
        self.sourceInfo = sourceInfo
        self.isBroadcasted = isBroadcasted
        self.isSynced = isSynced
        self.title = title
    }
}
