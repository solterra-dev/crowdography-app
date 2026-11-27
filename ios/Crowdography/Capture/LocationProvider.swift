import CoreLocation
import Foundation

/// Where the phone is. Jeff 2026-11-15: the location is part of the proof, so it is kept, never stripped.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var latest: CLLocation?
    @Published private(set) var authorized = false
    private let manager = CLLocationManager()
    /// Build 21: every reading, for the camera path while filming (latest only keeps the newest one).
    var onEachLocation: ((CLLocation) -> Void)?
    var onHeading: ((CLHeading) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone   // keep fresh fixes coming even when standing still
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    /// The compass, only while filming (it uses a little battery).
    func startHeading() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.headingOrientation = .portrait
        manager.headingFilter = 1
        manager.startUpdatingHeading()
    }
    func stopHeading() { manager.stopUpdatingHeading() }

    /// A usable fix: real accuracy and no older than two minutes.
    var currentFix: CLLocation? {
        guard let l = latest, l.horizontalAccuracy >= 0, Date().timeIntervalSince(l.timestamp) < 120 else { return nil }
        return l
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in
            self.latest = l
            for each in locations { self.onEachLocation?(each) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in self.onHeading?(newHeading) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.authorized = (s == .authorizedWhenInUse || s == .authorizedAlways)
            if self.authorized { manager.startUpdatingLocation() }
        }
    }
}
