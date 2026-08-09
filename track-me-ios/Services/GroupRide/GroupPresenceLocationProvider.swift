@preconcurrency import CoreLocation

/// Supplies lower-cost presence fixes when a member has joined a group but has
/// no active ride. Recording owns the high-accuracy stream whenever a ride id
/// exists, so the two modes never subscribe to Core Location at the same time.
@MainActor
final class GroupPresenceLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = GroupPresenceLocationProvider()

    private let locationManager = CLLocationManager()
    private var isRunning = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 10
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        guard !isRunning else { return }
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            break
        case .authorizedWhenInUse:
            // A joined member can be idle when the group begins. Ask for the
            // background upgrade here so presence does not disappear on lock.
            locationManager.requestAlwaysAuthorization()
        default:
            GroupRideManager.shared.updateLatestLocation(nil, moving: false, riding: false)
            return
        }
        isRunning = true
        locationManager.startUpdatingLocation()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        locationManager.stopUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRunning, let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        GroupRideManager.shared.updateLatestLocation(
            location,
            moving: location.speed >= 0 && location.speed > 0.5,
            riding: false
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isRunning else { return }
        GroupRideManager.shared.updateLatestLocation(nil, moving: false, riding: false)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !isRunning,
              GroupRideManager.shared.state.isActive,
              TrackingManager.shared.currentRideId == nil else { return }
        start()
    }
}
