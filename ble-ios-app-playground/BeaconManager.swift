//
//  BeaconManager.swift
//  ble-ios-app-playground
//

import Foundation
import CoreLocation
import Combine
import UserNotifications
import os.log

// MARK: - Event Log Entry

struct BeaconEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let type: EventType
    let message: String

    enum EventType: String, Codable {
        case regionEnter = "enter"
        case regionExit = "exit"
        case stateChange = "state"
        case authorization = "auth"
        case error = "error"
        case info = "info"
    }

    init(type: EventType, message: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.type = type
        self.message = message
    }
}

// MARK: - Beacon Manager

class BeaconManager: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isInsideRegion: Bool = false
    @Published var detectedBeacons: [CLBeacon] = []
    @Published var lastError: String?
    @Published var isMonitoring: Bool = false
    @Published var isRanging: Bool = false
    @Published var eventLog: [BeaconEvent] = []

    // MARK: - Private Properties

    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BeaconApp", category: "BeaconManager")

    private let beaconUUID = UUID(uuidString: "E7B2C021-5D07-4D0B-9C20-223488C8B012")!
    private let beaconIdentifier = "com.playground.ibeacon-region"

    private let eventLogKey = "BeaconEventLog"
    private let maxLogEntries = 100

    private lazy var beaconRegion: CLBeaconRegion = {
        CLBeaconRegion(uuid: beaconUUID, identifier: beaconIdentifier)
    }()

    private lazy var beaconIdentityConstraint: CLBeaconIdentityConstraint = {
        CLBeaconIdentityConstraint(uuid: beaconUUID)
    }()

    // MARK: - Initialization

    override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = locationManager.authorizationStatus
        loadEventLog()
        requestNotificationPermission()
    }

    // MARK: - Public Methods

    func requestAuthorization() {
        switch authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            startMonitoring()
        case .denied, .restricted:
            lastError = "Location access denied. Please enable in Settings."
        @unknown default:
            break
        }
    }

    func startMonitoring() {
        guard CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) else {
            lastError = "Beacon monitoring is not available on this device."
            return
        }

        beaconRegion.notifyOnEntry = true
        beaconRegion.notifyOnExit = true
        beaconRegion.notifyEntryStateOnDisplay = true

        locationManager.startMonitoring(for: beaconRegion)
        isMonitoring = true
        lastError = nil

        logEvent(.info, "Started monitoring for beacon region")
        locationManager.requestState(for: beaconRegion)
    }

    func stopMonitoring() {
        locationManager.stopMonitoring(for: beaconRegion)
        stopRanging()
        isMonitoring = false
        isInsideRegion = false
        logEvent(.info, "Stopped monitoring")
    }

    func startRanging() {
        guard CLLocationManager.isRangingAvailable() else {
            lastError = "Beacon ranging is not available on this device."
            return
        }

        locationManager.startRangingBeacons(satisfying: beaconIdentityConstraint)
        isRanging = true
    }

    func stopRanging() {
        locationManager.stopRangingBeacons(satisfying: beaconIdentityConstraint)
        isRanging = false
        detectedBeacons = []
    }

    func clearEventLog() {
        eventLog = []
        saveEventLog()
    }

    // MARK: - Logging

    private func logEvent(_ type: BeaconEvent.EventType, _ message: String) {
        let event = BeaconEvent(type: type, message: message)

        DispatchQueue.main.async {
            self.eventLog.insert(event, at: 0)
            if self.eventLog.count > self.maxLogEntries {
                self.eventLog = Array(self.eventLog.prefix(self.maxLogEntries))
            }
            self.saveEventLog()
        }

        // Also log to system console (viewable in Console.app)
        logger.log("[\(type.rawValue)] \(message)")
    }

    private func saveEventLog() {
        if let data = try? JSONEncoder().encode(eventLog) {
            UserDefaults.standard.set(data, forKey: eventLogKey)
        }
    }

    private func loadEventLog() {
        if let data = UserDefaults.standard.data(forKey: eventLogKey),
           let log = try? JSONDecoder().decode([BeaconEvent].self, from: data) {
            eventLog = log
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                self.logger.log("Notification permission granted")
            }
        }
    }

    private func sendLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - CLLocationManagerDelegate

extension BeaconManager: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let oldStatus = authorizationStatus
        authorizationStatus = manager.authorizationStatus

        if oldStatus != authorizationStatus {
            logEvent(.authorization, "Authorization changed: \(authorizationStatusDescription)")
        }

        switch authorizationStatus {
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            startMonitoring()
        case .denied, .restricted:
            lastError = "Location access denied. Please enable in Settings."
            stopMonitoring()
        default:
            break
        }
    }

    private var authorizationStatusDescription: String {
        switch authorizationStatus {
        case .notDetermined: return "Not Determined"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorizedWhenInUse: return "When In Use"
        case .authorizedAlways: return "Always"
        @unknown default: return "Unknown"
        }
    }

    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        logEvent(.info, "Monitoring started for: \(region.identifier)")
        locationManager.requestState(for: region)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == beaconIdentifier else { return }

        let stateStr: String
        switch state {
        case .inside: stateStr = "inside"
        case .outside: stateStr = "outside"
        case .unknown: stateStr = "unknown"
        }
        logEvent(.stateChange, "Region state determined: \(stateStr)")

        switch state {
        case .inside:
            isInsideRegion = true
            startRanging()
        case .outside:
            isInsideRegion = false
            stopRanging()
        case .unknown:
            isInsideRegion = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == beaconIdentifier else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        logEvent(.regionEnter, "WAKE-UP: Entered beacon region at \(timestamp)")

        // Send notification to alert user (screen stays dark, but this shows in notification center)
        sendLocalNotification(
            title: "Beacon Detected",
            body: "Entered iBeacon region"
        )

        isInsideRegion = true
        startRanging()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == beaconIdentifier else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        logEvent(.regionExit, "WAKE-UP: Exited beacon region at \(timestamp)")

        sendLocalNotification(
            title: "Beacon Lost",
            body: "Exited iBeacon region"
        )

        isInsideRegion = false
        stopRanging()
    }

    func locationManager(_ manager: CLLocationManager, didRange beacons: [CLBeacon], satisfying beaconConstraint: CLBeaconIdentityConstraint) {
        // Deduplicate beacons by uuid-major-minor, keeping the one with best accuracy
        var uniqueBeacons: [String: CLBeacon] = [:]
        for beacon in beacons {
            let key = "\(beacon.uuid.uuidString)-\(beacon.major)-\(beacon.minor)"
            if let existing = uniqueBeacons[key] {
                // Keep the one with better (lower) accuracy, ignoring negative values
                if beacon.accuracy >= 0 && (existing.accuracy < 0 || beacon.accuracy < existing.accuracy) {
                    uniqueBeacons[key] = beacon
                }
            } else {
                uniqueBeacons[key] = beacon
            }
        }
        detectedBeacons = Array(uniqueBeacons.values).sorted { $0.accuracy < $1.accuracy }
    }

    func locationManager(_ manager: CLLocationManager, didFailRangingFor beaconConstraint: CLBeaconIdentityConstraint, error: Error) {
        let msg = "Ranging failed: \(error.localizedDescription)"
        lastError = msg
        logEvent(.error, msg)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let msg = "Monitoring failed: \(error.localizedDescription)"
        lastError = msg
        logEvent(.error, msg)
        isMonitoring = false
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let msg = "Location manager error: \(error.localizedDescription)"
        lastError = msg
        logEvent(.error, msg)
    }
}

// MARK: - Helper Extensions

extension CLProximity {
    var description: String {
        switch self {
        case .immediate: return "Immediate"
        case .near: return "Near"
        case .far: return "Far"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    var color: String {
        switch self {
        case .immediate: return "green"
        case .near: return "yellow"
        case .far: return "orange"
        case .unknown: return "gray"
        @unknown default: return "gray"
        }
    }
}

extension CLBeacon: Identifiable {
    public var id: String {
        "\(uuid.uuidString)-\(major)-\(minor)"
    }
}
