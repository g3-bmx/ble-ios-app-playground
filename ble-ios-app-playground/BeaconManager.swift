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
        case gatt = "gatt"
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

    /// GATT client for credential presentation
    @Published private(set) var gattClient: GATTClient?

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

    /// Tracks whether credential has been presented since entering region (prevents re-triggering)
    private var hasCredentialBeenPresented: Bool = false

    /// Cancellable for observing GATT client state changes
    private var gattStateCancellable: AnyCancellable?

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

    // MARK: - GATT Credential Presentation

    /// Presents credential via GATT if not already presented since entering region
    private func presentCredentialIfNeeded() {
        logger.log("┌─────────────────────────────────────────────────────────────┐")
        logger.log("│ presentCredentialIfNeeded()                                 │")
        logger.log("└─────────────────────────────────────────────────────────────┘")
        logger.log("hasCredentialBeenPresented: \(self.hasCredentialBeenPresented)")
        logger.log("isInsideRegion: \(self.isInsideRegion)")
        logger.log("Current gattClient: \(self.gattClient == nil ? "nil" : "exists")")

        guard !hasCredentialBeenPresented else {
            logger.log("⏭️ Credential already presented since entering region, skipping")
            logEvent(.gatt, "Skipped - credential already presented")
            return
        }

        hasCredentialBeenPresented = true
        logger.log("🚀 Starting GATT credential presentation")
        logEvent(.gatt, "Starting GATT credential presentation")

        // Cancel any existing GATT client before creating a new one
        if let existingClient = gattClient {
            logger.log("⚠️ Existing GATT client found - cancelling before creating new one")
            existingClient.cancel()
            gattStateCancellable?.cancel()
        }

        // Create GATT client with POC configuration
        logger.log("Creating new GATTClient with POC configuration")
        let client = GATTClient(config: .poc)
        gattClient = client

        // Observe state changes
        logger.log("Setting up state change observer")
        gattStateCancellable = client.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleGATTStateChange(state)
            }

        // Set completion handler for notifications
        logger.log("Setting up completion handler")
        client.completionHandler = { [weak self] result in
            self?.handleGATTCompletion(result)
        }

        // Start credential presentation
        logger.log("Calling client.presentCredential()")
        client.presentCredential()
    }

    /// Stops the GATT client and cleans up resources
    private func stopGATTClient() {
        logger.log("┌─────────────────────────────────────────────────────────────┐")
        logger.log("│ stopGATTClient()                                            │")
        logger.log("└─────────────────────────────────────────────────────────────┘")

        guard let client = gattClient else {
            logger.log("No GATT client to stop")
            return
        }

        logger.log("Current GATT client state: \(client.state.description)")
        logger.log("Cancelling GATT client...")
        client.cancel()

        logger.log("Cancelling state change subscription")
        gattStateCancellable?.cancel()
        gattStateCancellable = nil

        logger.log("Clearing gattClient reference")
        gattClient = nil
        logger.log("✅ GATT client stopped and cleaned up")
        logEvent(.gatt, "GATT client stopped (region exit)")
    }

    /// Handle GATT client state changes for logging
    private func handleGATTStateChange(_ state: GATTClientState) {
        logger.log("GATT state changed: \(state.description)")

        switch state {
        case .idle:
            logEvent(.gatt, "GATT client idle")
        case .scanning:
            logEvent(.gatt, "Scanning for credential reader...")
        case .connecting:
            logEvent(.gatt, "Connecting to reader...")
        case .discoveringServices:
            logEvent(.gatt, "Discovering services...")
        case .discoveringCharacteristics:
            logEvent(.gatt, "Discovering characteristics...")
        case .subscribing:
            logEvent(.gatt, "Subscribing to notifications...")
        case .authenticating:
            logEvent(.gatt, "Authenticating with reader...")
        case .sendingCredential:
            logEvent(.gatt, "Sending credential...")
        case .complete(let result):
            logEvent(.gatt, "Complete: \(result.message)")
        case .failed(let message):
            logEvent(.error, "GATT failed: \(message)")
        }
    }

    /// Handle GATT completion with notification
    private func handleGATTCompletion(_ result: CredentialResult) {
        logger.log("┌─────────────────────────────────────────────────────────────┐")
        logger.log("│ handleGATTCompletion                                        │")
        logger.log("└─────────────────────────────────────────────────────────────┘")
        logger.log("Success: \(result.success)")
        logger.log("Message: \(result.message)")

        if result.success {
            sendLocalNotification(
                title: "Access Granted",
                body: result.message
            )
            logEvent(.gatt, "Credential accepted: \(result.message)")
        } else {
            sendLocalNotification(
                title: "Access Denied",
                body: result.message
            )
            logEvent(.error, "Credential rejected: \(result.message)")
        }
    }

    /// Manually trigger credential presentation (for UI button)
    func manuallyPresentCredential() {
        logger.log("┌─────────────────────────────────────────────────────────────┐")
        logger.log("│ manuallyPresentCredential() - UI Button Pressed             │")
        logger.log("└─────────────────────────────────────────────────────────────┘")
        hasCredentialBeenPresented = false
        logger.log("Reset hasCredentialBeenPresented to false")
        presentCredentialIfNeeded()
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

        logger.log("┌═════════════════════════════════════════════════════════════┐")
        logger.log("│ didEnterRegion - BEACON REGION ENTRY                        │")
        logger.log("└═════════════════════════════════════════════════════════════┘")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        logger.log("🚨 Entered beacon region at: \(timestamp)")
        logger.log("Region identifier: \(region.identifier)")
        logger.log("Current isInsideRegion: \(self.isInsideRegion)")
        logger.log("Current hasCredentialBeenPresented: \(self.hasCredentialBeenPresented)")

        logEvent(.regionEnter, "WAKE-UP: Entered beacon region at \(timestamp)")

        // Send notification to alert user (screen stays dark, but this shows in notification center)
        logger.log("Sending local notification for region entry")
        sendLocalNotification(
            title: "Beacon Detected",
            body: "Entered iBeacon region"
        )

        isInsideRegion = true
        logger.log("Starting ranging")
        startRanging()

        // Trigger GATT credential presentation (only if not already presented since entering region)
        logger.log("Triggering GATT credential presentation")
        presentCredentialIfNeeded()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == beaconIdentifier else { return }

        logger.log("┌─────────────────────────────────────────────────────────────┐")
        logger.log("│ didExitRegion                                               │")
        logger.log("└─────────────────────────────────────────────────────────────┘")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        logger.log("Exited region at: \(timestamp)")
        logEvent(.regionExit, "WAKE-UP: Exited beacon region at \(timestamp)")

        sendLocalNotification(
            title: "Beacon Lost",
            body: "Exited iBeacon region"
        )

        isInsideRegion = false
        stopRanging()

        // Stop any active GATT client connection
        logger.log("Stopping GATT client due to region exit")
        stopGATTClient()

        // Reset credential presentation flag so it can be triggered again on next entry
        hasCredentialBeenPresented = false
        logger.log("Reset hasCredentialBeenPresented to false")
        logEvent(.gatt, "Credential presentation reset (exited region)")
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
