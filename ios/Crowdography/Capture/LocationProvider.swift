import CoreLocation
import Foundation

/// Where the phone is. Jeff 2026-11-15: the location is part of the proof, so it is kept, never stripped.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var latest: CLLocation?
    @Published private(set) var authorized = false
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    /// A usable fix: real accuracy and no older than two minutes.
    var currentFix: CLLocation? {
        guard let l = latest, l.horizontalAccuracy >= 0, Date().timeIntervalSince(l.timestamp) < 120 else { return nil }
        return l
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in self.latest = l }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.authorized = (s == .authorizedWhenInUse || s == .authorizedAlways)
            if self.authorized { manager.startUpdatingLocation() }
        }
    }
}
