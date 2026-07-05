import Foundation
import CoreLocation

/// Skeleton for real-time-ish visit detection. Uses CLVisit which is battery-friendly
/// but delayed. For MVP, the primary trigger for visit discovery is the manual scan;
/// this class simply notifies the app when the OS reports a visit so we can nudge a scan.
final class LocationVisitMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    /// Called when a CLVisit begins (user arrived somewhere). Post-MVP: kick off
    /// on-the-spot restaurant lookup + a "you're at X, log a visit?" notification.
    var onVisitDetected: ((CLVisit) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func startVisitMonitoring() {
        manager.startMonitoringVisits()
    }

    func stopVisitMonitoring() {
        manager.stopMonitoringVisits()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        onVisitDetected?(visit)
    }
}
