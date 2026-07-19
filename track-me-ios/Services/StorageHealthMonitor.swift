import Foundation

/// Guards against silent data loss when the device is almost out of disk.
/// Mirrors Android's `StorageHealthMonitor` (50 MiB threshold). Kept tiny and
/// pure so the policy is unit-testable without touching the filesystem.
enum StorageHealthMonitor {
    static let lowStorageThresholdBytes: Int64 = 50 * 1024 * 1024

    #if DEBUG
    /// Simulator/debug hook: force the "low" verdict without filling the disk,
    /// so the storage-low flow can be walked end-to-end. Compiled out of release.
    static var debugForceLow = false
    #endif

    static func isLowStorage() -> Bool {
        #if DEBUG
        if debugForceLow { return true }
        #endif
        let fm = FileManager.default
        // The volume that backs the SwiftData store (Application Support), with a
        // Documents fallback if it doesn't exist yet — same physical volume.
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let url,
              let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else {
            return false // fail open, like Android would if filesDir vanished
        }
        return isLowStorage(availableBytes: capacity)
    }

    /// Pure policy: `volumeAvailableCapacityForImportantUsage` accounts for
    /// purgeable space, so it's Apple's recommended "will a user-critical write
    /// succeed" signal.
    static func isLowStorage(availableBytes: Int64, threshold: Int64 = lowStorageThresholdBytes) -> Bool {
        availableBytes < threshold
    }
}
