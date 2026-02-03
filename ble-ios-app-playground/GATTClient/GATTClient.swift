//
//  GATTClient.swift
//  ble-ios-app-playground
//
//  BLE GATT Client for symmetric key authentication and credential presentation.
//  Uses CoreBluetooth to connect to a credential reader and perform the authentication protocol.
//

import Foundation
import CoreBluetooth
import Combine
import os.log

// MARK: - Client State

/// States of the GATT client state machine
enum GATTClientState: Equatable {
    case idle
    case scanning
    case connecting
    case discoveringServices
    case discoveringCharacteristics
    case subscribing
    case authenticating
    case sendingCredential
    case complete(CredentialResult)
    case failed(String)

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .discoveringServices: return "Discovering Services"
        case .discoveringCharacteristics: return "Discovering Characteristics"
        case .subscribing: return "Subscribing"
        case .authenticating: return "Authenticating"
        case .sendingCredential: return "Sending Credential"
        case .complete(let result): return result.success ? "Complete - \(result.message)" : "Failed - \(result.message)"
        case .failed(let message): return "Failed - \(message)"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .complete, .failed: return true
        default: return false
        }
    }

    static func == (lhs: GATTClientState, rhs: GATTClientState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.scanning, .scanning),
             (.connecting, .connecting),
             (.discoveringServices, .discoveringServices),
             (.discoveringCharacteristics, .discoveringCharacteristics),
             (.subscribing, .subscribing),
             (.authenticating, .authenticating),
             (.sendingCredential, .sendingCredential):
            return true
        case (.complete(let lResult), .complete(let rResult)):
            return lResult.success == rResult.success && lResult.message == rResult.message
        case (.failed(let lMsg), .failed(let rMsg)):
            return lMsg == rMsg
        default:
            return false
        }
    }
}

// MARK: - Client Configuration

/// Configuration for the GATT client
struct GATTClientConfig {
    let deviceId: Data
    let deviceKey: Data
    let credential: String

    /// POC configuration with hardcoded values
    static var poc: GATTClientConfig {
        GATTClientConfig(
            deviceId: POC_DEVICE_ID,
            deviceKey: POC_DEVICE_KEY,
            credential: POC_CREDENTIAL
        )
    }
}

// MARK: - GATT Client

/// BLE GATT Client for credential communication
class GATTClient: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var state: GATTClientState = .idle
    @Published private(set) var connectedPeripheralName: String?
    @Published private(set) var discoveredServiceUUID: String?
    @Published private(set) var discoveredCharacteristicUUID: String?
    @Published private(set) var lastResult: CredentialResult?

    // MARK: - Private Properties

    private let config: GATTClientConfig
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GATTClient", category: "GATTClient")

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var dataTransferCharacteristic: CBCharacteristic?

    private var nonceM: Data?
    private var notificationData: Data?
    private var notificationContinuation: CheckedContinuation<Data?, Never>?

    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var responseTimeoutWorkItem: DispatchWorkItem?

    private var retryCount = 0
    private var isRetrying = false

    /// Tracks if we're waiting for Bluetooth to power on before starting
    private var isPendingStart = false

    /// Completion handler called when credential presentation finishes
    var completionHandler: ((CredentialResult) -> Void)?

    // MARK: - Initialization

    init(config: GATTClientConfig = .poc) {
        self.config = config
        super.init()
        logger.info("╔══════════════════════════════════════════════════════════════╗")
        logger.info("║           GATT Client Initialized                            ║")
        logger.info("╚══════════════════════════════════════════════════════════════╝")
        logger.info("Config - Device ID: \(config.deviceId.hexString)")
        logger.info("Config - Credential: \(config.credential)")
        logger.info("Config - Service UUID: \(CREDENTIAL_SERVICE_UUID.uuidString)")
        logger.info("Config - Characteristic UUID: \(DATA_TRANSFER_CHAR_UUID.uuidString)")

        // Initialize CBCentralManager with background restoration
        centralManager = CBCentralManager(
            delegate: self,
            queue: DispatchQueue.main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.playground.gatt-client"]
        )
        logger.info("CBCentralManager created with restore identifier: com.playground.gatt-client")
    }

    // MARK: - Public Methods

    /// Start the credential presentation flow
    func presentCredential() {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ presentCredential() called                                  │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("Current state: \(self.state.description)")
        logger.info("Is terminal state: \(self.state.isTerminal)")
        logger.info("Is retrying: \(self.isRetrying)")
        logger.info("Retry count: \(self.retryCount)")

        guard !state.isTerminal || isRetrying else {
            logger.warning("⚠️ Cannot start: already in terminal state \(self.state.description)")
            return
        }

        if !isRetrying {
            retryCount = 0
            logger.info("Fresh start - retry count reset to 0")
        }
        isRetrying = false

        logger.info("🚀 Starting credential presentation (attempt \(self.retryCount + 1)/\(MAX_RETRIES))")

        // Reset state
        nonceM = nil
        notificationData = nil
        connectedPeripheralName = nil
        discoveredServiceUUID = nil
        discoveredCharacteristicUUID = nil
        logger.info("Internal state reset complete")

        // Check Bluetooth state
        let btState = centralManager.state
        logger.info("Bluetooth state: \(self.bluetoothStateDescription(btState))")

        if btState == .poweredOn {
            logger.info("✅ Bluetooth is powered on - starting scan")
            isPendingStart = false
            startScanning()
        } else {
            logger.warning("⏳ Bluetooth not ready (state: \(self.bluetoothStateDescription(btState))) - setting pending start flag")
            isPendingStart = true
            state = .idle
            logger.info("Will start scanning when Bluetooth becomes powered on")
        }
    }

    /// Human-readable Bluetooth state description
    private func bluetoothStateDescription(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "Unknown"
        case .resetting: return "Resetting"
        case .unsupported: return "Unsupported"
        case .unauthorized: return "Unauthorized"
        case .poweredOff: return "Powered Off"
        case .poweredOn: return "Powered On"
        @unknown default: return "Unknown (\(state.rawValue))"
        }
    }

    /// Cancel the current operation
    func cancel() {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ cancel() called                                             │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("Current state before cancel: \(self.state.description)")
        logger.info("Peripheral: \(self.peripheral?.name ?? "none")")
        logger.info("Has characteristic: \(self.dataTransferCharacteristic != nil)")
        logger.info("isPendingStart: \(self.isPendingStart)")

        isPendingStart = false
        cleanup()
        state = .idle
        logger.info("✅ Operation cancelled, state set to idle")
    }

    // MARK: - Private Methods - Scanning

    private func startScanning() {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ startScanning()                                             │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("🔍 Scanning for credential service: \(CREDENTIAL_SERVICE_UUID.uuidString)")
        logger.info("Scan timeout: \(SCAN_TIMEOUT) seconds")
        state = .scanning

        // Set scan timeout
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.handleScanTimeout()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + SCAN_TIMEOUT, execute: scanTimeoutWorkItem!)
        logger.info("Scan timeout scheduled for \(SCAN_TIMEOUT)s from now")

        centralManager.scanForPeripherals(
            withServices: [CREDENTIAL_SERVICE_UUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        logger.info("scanForPeripherals() called - scan is active")
    }

    private func handleScanTimeout() {
        guard state == .scanning else {
            logger.info("Scan timeout fired but state is \(self.state.description) - ignoring")
            return
        }
        logger.error("❌ Scan timeout after \(SCAN_TIMEOUT)s - no reader found")
        centralManager.stopScan()
        handleFailure("No reader found")
    }

    // MARK: - Private Methods - Connection

    private func connect(to peripheral: CBPeripheral) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ connect(to:)                                                │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("Peripheral name: \(peripheral.name ?? "Unknown")")
        logger.info("Peripheral identifier: \(peripheral.identifier.uuidString)")
        logger.info("Peripheral state: \(self.peripheralStateDescription(peripheral.state))")

        scanTimeoutWorkItem?.cancel()
        logger.info("Scan timeout cancelled")
        centralManager.stopScan()
        logger.info("Scanning stopped")

        self.peripheral = peripheral
        peripheral.delegate = self
        connectedPeripheralName = peripheral.name ?? "Unknown"

        logger.info("📡 Connecting to \(peripheral.name ?? "Unknown")...")
        state = .connecting

        centralManager.connect(peripheral, options: nil)
        logger.info("connect() called on CBCentralManager")
    }

    /// Human-readable peripheral state description
    private func peripheralStateDescription(_ state: CBPeripheralState) -> String {
        switch state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting"
        @unknown default: return "Unknown (\(state.rawValue))"
        }
    }

    // MARK: - Private Methods - Service Discovery

    private func discoverServices() {
        guard let peripheral = peripheral else {
            logger.error("❌ discoverServices() called but peripheral is nil")
            return
        }

        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ discoverServices()                                          │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("🔎 Discovering services on \(peripheral.name ?? "Unknown")")
        logger.info("Looking for service: \(CREDENTIAL_SERVICE_UUID.uuidString)")
        state = .discoveringServices

        peripheral.discoverServices([CREDENTIAL_SERVICE_UUID])
        logger.info("discoverServices() called on peripheral")
    }

    private func discoverCharacteristics(for service: CBService) {
        guard let peripheral = peripheral else {
            logger.error("❌ discoverCharacteristics() called but peripheral is nil")
            return
        }

        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ discoverCharacteristics(for:)                               │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("Service UUID: \(service.uuid.uuidString)")
        logger.info("🔎 Looking for characteristic: \(DATA_TRANSFER_CHAR_UUID.uuidString)")
        state = .discoveringCharacteristics
        discoveredServiceUUID = service.uuid.uuidString

        peripheral.discoverCharacteristics([DATA_TRANSFER_CHAR_UUID], for: service)
        logger.info("discoverCharacteristics() called on peripheral")
    }

    // MARK: - Private Methods - Notifications

    private func subscribeToNotifications() {
        guard let peripheral = peripheral,
              let characteristic = dataTransferCharacteristic else {
            logger.error("❌ subscribeToNotifications() failed - peripheral or characteristic is nil")
            logger.error("Peripheral: \(self.peripheral?.name ?? "nil")")
            logger.error("Characteristic: \(self.dataTransferCharacteristic?.uuid.uuidString ?? "nil")")
            handleFailure("Characteristic not found")
            return
        }

        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ subscribeToNotifications()                                  │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("📨 Subscribing to notifications on \(characteristic.uuid.uuidString)")
        logger.info("Characteristic properties: \(characteristic.properties.rawValue)")
        state = .subscribing
        discoveredCharacteristicUUID = characteristic.uuid.uuidString

        peripheral.setNotifyValue(true, for: characteristic)
        logger.info("setNotifyValue(true) called")
    }

    // MARK: - Private Methods - Authentication

    private func authenticate() {
        logger.info("Starting authentication...")
        state = .authenticating

        do {
            let builder = AuthRequestBuilder(deviceId: config.deviceId, deviceKey: config.deviceKey)
            let (message, nonceM) = try builder.build()
            self.nonceM = nonceM

            logger.debug("Device ID: \(self.config.deviceId.hexString)")
            logger.debug("Nonce_M: \(nonceM.hexString)")
            logger.debug("AUTH_REQUEST (\(message.count) bytes)")

            sendMessage(message) { [weak self] response in
                self?.handleAuthResponse(response)
            }
        } catch {
            handleFailure("Failed to build auth request: \(error.localizedDescription)")
        }
    }

    private func handleAuthResponse(_ response: Data?) {
        guard let response = response else {
            handleFailure("Authentication timeout")
            return
        }

        logger.debug("AUTH_RESPONSE (\(response.count) bytes)")

        guard let nonceM = nonceM else {
            handleFailure("Internal error: nonce not saved")
            return
        }

        do {
            let parser = AuthResponseParser(deviceKey: config.deviceKey)
            let nonceR = try parser.parse(response, expectedNonceM: nonceM)
            logger.info("Authentication successful. Nonce_R: \(nonceR.hexString)")
            sendCredential()
        } catch {
            handleFailure(error.localizedDescription)
        }
    }

    // MARK: - Private Methods - Credential

    private func sendCredential() {
        logger.info("Sending credential...")
        state = .sendingCredential

        do {
            let builder = CredentialBuilder(deviceKey: config.deviceKey)
            let message = try builder.build(credential: config.credential)

            logger.debug("CREDENTIAL (\(message.count) bytes)")

            sendMessage(message) { [weak self] response in
                self?.handleCredentialResponse(response)
            }
        } catch {
            handleFailure("Failed to build credential: \(error.localizedDescription)")
        }
    }

    private func handleCredentialResponse(_ response: Data?) {
        guard let response = response else {
            handleFailure("Credential response timeout")
            return
        }

        logger.debug("CREDENTIAL_RESPONSE (\(response.count) bytes)")

        do {
            let result = try parseCredentialResponse(response)
            logger.info("Credential result: \(result.message)")
            handleSuccess(result)
        } catch {
            handleFailure(error.localizedDescription)
        }
    }

    // MARK: - Private Methods - Message Sending

    private func sendMessage(_ data: Data, completion: @escaping (Data?) -> Void) {
        guard let peripheral = peripheral,
              let characteristic = dataTransferCharacteristic else {
            completion(nil)
            return
        }

        // Clear any pending notification
        notificationData = nil

        // Set response timeout
        responseTimeoutWorkItem?.cancel()
        responseTimeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.logger.error("Response timeout")
            completion(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + RESPONSE_TIMEOUT, execute: responseTimeoutWorkItem!)

        // Store completion for notification handler
        notificationContinuation = nil
        Task {
            let response = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                self.notificationContinuation = continuation
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            }
            DispatchQueue.main.async {
                completion(response)
            }
        }
    }

    private func handleNotification(_ data: Data) {
        responseTimeoutWorkItem?.cancel()
        if let continuation = notificationContinuation {
            notificationContinuation = nil
            continuation.resume(returning: data)
        }
    }

    // MARK: - Private Methods - Result Handling

    private func handleSuccess(_ result: CredentialResult) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ handleSuccess                                               │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("🎉 SUCCESS: \(result.message)")
        cleanup()
        lastResult = result
        state = .complete(result)
        logger.info("Calling completion handler...")
        completionHandler?(result)
    }

    private func handleFailure(_ message: String) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ handleFailure                                               │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.error("❌ FAILURE: \(message)")
        logger.info("Current retry count: \(self.retryCount)")

        cleanup()

        retryCount += 1
        if retryCount < MAX_RETRIES {
            logger.info("🔄 Will retry (\(self.retryCount)/\(MAX_RETRIES)) in 1 second...")
            isRetrying = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.logger.info("Retry timer fired - calling presentCredential()")
                self?.presentCredential()
            }
        } else {
            logger.error("💀 Max retries (\(MAX_RETRIES)) reached - giving up")
            let result = CredentialResult(success: false, message: message)
            lastResult = result
            state = .failed(message)
            logger.info("Calling completion handler with failure...")
            completionHandler?(result)
        }
    }

    private func cleanup() {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ cleanup()                                                   │")
        logger.info("└─────────────────────────────────────────────────────────────┘")

        logger.info("Cancelling scan timeout work item")
        scanTimeoutWorkItem?.cancel()
        logger.info("Cancelling response timeout work item")
        responseTimeoutWorkItem?.cancel()

        if let peripheral = peripheral {
            logger.info("Cleaning up peripheral: \(peripheral.name ?? "Unknown")")
            if let characteristic = dataTransferCharacteristic {
                logger.info("Unsubscribing from notifications on \(characteristic.uuid.uuidString)")
                peripheral.setNotifyValue(false, for: characteristic)
            }
            logger.info("Cancelling peripheral connection")
            centralManager.cancelPeripheralConnection(peripheral)
        } else {
            logger.info("No peripheral to clean up")
        }

        logger.info("Clearing references")
        peripheral = nil
        dataTransferCharacteristic = nil
        nonceM = nil
        notificationContinuation = nil
        isPendingStart = false
        logger.info("✅ Cleanup complete")
    }
}

// MARK: - CBCentralManagerDelegate

extension GATTClient: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ centralManagerDidUpdateState                                │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("🔵 Bluetooth state changed: \(self.bluetoothStateDescription(central.state))")
        logger.info("Current GATT client state: \(self.state.description)")

        switch central.state {
        case .poweredOn:
            logger.info("✅ Bluetooth is powered on")
            logger.info("isPendingStart: \(self.isPendingStart)")
            if isPendingStart {
                logger.info("🚀 Pending start detected - starting scan now!")
                isPendingStart = false
                startScanning()
            } else if state == .idle && !state.isTerminal {
                logger.info("Client is idle - ready to start scanning when presentCredential() is called")
            }
        case .poweredOff:
            logger.error("❌ Bluetooth is powered off")
            handleFailure("Bluetooth is powered off")
        case .unauthorized:
            logger.error("❌ Bluetooth access not authorized")
            handleFailure("Bluetooth access not authorized")
        case .unsupported:
            logger.error("❌ Bluetooth not supported on this device")
            handleFailure("Bluetooth not supported on this device")
        case .resetting:
            logger.warning("⚠️ Bluetooth is resetting")
        case .unknown:
            logger.warning("⚠️ Bluetooth state is unknown")
        @unknown default:
            logger.warning("⚠️ Unknown Bluetooth state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ willRestoreState (Background Restoration)                   │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("🔄 Restoring state from background")
        logger.info("Restoration dict keys: \(dict.keys.joined(separator: ", "))")

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            logger.info("Restored \(peripherals.count) peripheral(s)")
            for peripheral in peripherals {
                logger.info("  - \(peripheral.name ?? "Unknown") (\(peripheral.identifier.uuidString))")
            }
        }

        if let scanServices = dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] {
            logger.info("Restored scan services: \(scanServices.map { $0.uuidString }.joined(separator: ", "))")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ didDiscover peripheral                                      │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("🎯 Discovered peripheral!")
        logger.info("Name: \(peripheral.name ?? "Unknown")")
        logger.info("Identifier: \(peripheral.identifier.uuidString)")
        logger.info("RSSI: \(RSSI) dBm")
        logger.info("Advertisement data keys: \(advertisementData.keys.map { String(describing: $0) }.joined(separator: ", "))")

        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            logger.info("Advertised services: \(serviceUUIDs.map { $0.uuidString }.joined(separator: ", "))")
        }
        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            logger.info("Local name: \(localName)")
        }
        if let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool {
            logger.info("Is connectable: \(isConnectable)")
        }

        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ didConnect                                                  │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("✅ Connected to \(peripheral.name ?? "Unknown")")
        logger.info("Peripheral identifier: \(peripheral.identifier.uuidString)")
        logger.info("Peripheral state: \(self.peripheralStateDescription(peripheral.state))")
        discoverServices()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ didFailToConnect                                            │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        let message = error?.localizedDescription ?? "Unknown error"
        logger.error("❌ Failed to connect to \(peripheral.name ?? "Unknown")")
        logger.error("Error: \(message)")
        handleFailure("Connection failed: \(message)")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ didDisconnectPeripheral                                     │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("🔌 Disconnected from \(peripheral.name ?? "Unknown")")
        if let error = error {
            logger.error("Disconnect error: \(error.localizedDescription)")
        }
        logger.info("Current GATT client state: \(self.state.description)")
        logger.info("Is terminal state: \(self.state.isTerminal)")

        if !state.isTerminal {
            logger.warning("⚠️ Unexpected disconnection - not in terminal state")
            handleFailure("Connection lost")
        } else {
            logger.info("Disconnection expected (terminal state)")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension GATTClient: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ didDiscoverServices                                         │")
        logger.info("└─────────────────────────────────────────────────────────────┘")

        if let error = error {
            logger.error("❌ Service discovery failed: \(error.localizedDescription)")
            handleFailure("Service discovery failed: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else {
            logger.error("❌ No services found on peripheral")
            handleFailure("No services found")
            return
        }

        logger.info("✅ Discovered \(services.count) service(s):")
        for (index, service) in services.enumerated() {
            logger.info("  [\(index)] \(service.uuid.uuidString)")
            if service.uuid == CREDENTIAL_SERVICE_UUID {
                logger.info("       ^ This is our credential service!")
            }
        }

        for service in services {
            if service.uuid == CREDENTIAL_SERVICE_UUID {
                logger.info("🎯 Found credential service - proceeding to discover characteristics")
                discoverCharacteristics(for: service)
                return
            }
        }

        logger.error("❌ Credential service \(CREDENTIAL_SERVICE_UUID.uuidString) not found in service list")
        handleFailure("Credential service not found")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ didDiscoverCharacteristicsFor                               │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("Service: \(service.uuid.uuidString)")

        if let error = error {
            logger.error("❌ Characteristic discovery failed: \(error.localizedDescription)")
            handleFailure("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else {
            logger.error("❌ No characteristics found for service")
            handleFailure("No characteristics found")
            return
        }

        logger.info("✅ Discovered \(characteristics.count) characteristic(s):")
        for (index, char) in characteristics.enumerated() {
            logger.info("  [\(index)] \(char.uuid.uuidString)")
            logger.info("       Properties: \(self.characteristicPropertiesDescription(char.properties))")
            if char.uuid == DATA_TRANSFER_CHAR_UUID {
                logger.info("       ^ This is our data transfer characteristic!")
            }
        }

        for characteristic in characteristics {
            if characteristic.uuid == DATA_TRANSFER_CHAR_UUID {
                logger.info("🎯 Found data transfer characteristic - saving reference")
                dataTransferCharacteristic = characteristic
                subscribeToNotifications()
                return
            }
        }

        logger.error("❌ Data transfer characteristic \(DATA_TRANSFER_CHAR_UUID.uuidString) not found")
        handleFailure("Data transfer characteristic not found")
    }

    /// Human-readable characteristic properties description
    private func characteristicPropertiesDescription(_ properties: CBCharacteristicProperties) -> String {
        var props: [String] = []
        if properties.contains(.broadcast) { props.append("Broadcast") }
        if properties.contains(.read) { props.append("Read") }
        if properties.contains(.writeWithoutResponse) { props.append("WriteWithoutResponse") }
        if properties.contains(.write) { props.append("Write") }
        if properties.contains(.notify) { props.append("Notify") }
        if properties.contains(.indicate) { props.append("Indicate") }
        if properties.contains(.authenticatedSignedWrites) { props.append("AuthSignedWrites") }
        return props.isEmpty ? "None" : props.joined(separator: ", ")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ didUpdateNotificationStateFor                               │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("Characteristic: \(characteristic.uuid.uuidString)")

        if let error = error {
            logger.error("❌ Notification subscription failed: \(error.localizedDescription)")
            handleFailure("Notification subscription failed: \(error.localizedDescription)")
            return
        }

        logger.info("Is notifying: \(characteristic.isNotifying)")

        if characteristic.isNotifying {
            logger.info("✅ Successfully subscribed to notifications")
            logger.info("⏳ Waiting 100ms before starting authentication...")
            // Small delay to ensure subscription is active
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.logger.info("Starting authentication after delay")
                self?.authenticate()
            }
        } else {
            logger.info("Unsubscribed from notifications")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ didUpdateValueFor (Notification Received)                   │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("Characteristic: \(characteristic.uuid.uuidString)")

        if let error = error {
            logger.error("❌ Notification error: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else {
            logger.warning("⚠️ Received empty notification")
            return
        }

        logger.info("📥 Notification received (\(data.count) bytes)")
        logger.debug("Data (hex): \(data.hexString)")
        if data.count > 0 {
            logger.info("First byte (message type): 0x\(String(format: "%02X", data[0]))")
        }
        handleNotification(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        logger.info("┌─────────────────────────────────────────────────────────────┐")
        logger.info("│ didWriteValueFor                                            │")
        logger.info("└─────────────────────────────────────────────────────────────┘")
        logger.info("Characteristic: \(characteristic.uuid.uuidString)")

        if let error = error {
            logger.error("❌ Write error: \(error.localizedDescription)")
        } else {
            logger.info("✅ Write completed successfully")
        }
    }
}
