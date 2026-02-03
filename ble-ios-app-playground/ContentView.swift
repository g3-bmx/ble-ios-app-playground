//
//  ContentView.swift
//  ble-ios-app-playground
//
//  Created by gabriel almendarez on 2/2/26.
//

import SwiftUI
import CoreLocation

struct ContentView: View {
    @StateObject private var beaconManager = BeaconManager()

    var body: some View {
        NavigationView {
            List {
                statusSection
                gattClientSection
                beaconsSection
                eventLogSection
            }
            .navigationTitle("iBeacon Scanner")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear Log") {
                        beaconManager.clearEventLog()
                    }
                }
            }
            .onAppear {
                beaconManager.requestAuthorization()
            }
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Text("Authorization")
                Spacer()
                Text(authorizationStatusText)
                    .foregroundColor(authorizationStatusColor)
            }

            HStack {
                Text("Monitoring")
                Spacer()
                Text(beaconManager.isMonitoring ? "Active" : "Inactive")
                    .foregroundColor(beaconManager.isMonitoring ? .green : .secondary)
            }

            HStack {
                Text("Region Status")
                Spacer()
                Text(beaconManager.isInsideRegion ? "Inside" : "Outside")
                    .foregroundColor(beaconManager.isInsideRegion ? .green : .secondary)
            }

            HStack {
                Text("Ranging")
                Spacer()
                Text(beaconManager.isRanging ? "Active" : "Inactive")
                    .foregroundColor(beaconManager.isRanging ? .green : .secondary)
            }

            if let error = beaconManager.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - GATT Client Section

    private var gattClientSection: some View {
        Section("GATT Client") {
            HStack {
                Text("State")
                Spacer()
                Text(gattStateText)
                    .foregroundColor(gattStateColor)
            }

            if let client = beaconManager.gattClient {
                if let peripheralName = client.connectedPeripheralName {
                    HStack {
                        Text("Connected To")
                        Spacer()
                        Text(peripheralName)
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                if let serviceUUID = client.discoveredServiceUUID {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Service UUID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(serviceUUID)
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }

                if let charUUID = client.discoveredCharacteristicUUID {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Characteristic UUID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(charUUID)
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                }

                if let result = client.lastResult {
                    HStack {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(result.success ? .green : .red)
                        Text(result.message)
                            .font(.caption)
                            .foregroundColor(result.success ? .green : .red)
                    }
                }
            }

            Button(action: {
                beaconManager.manuallyPresentCredential()
            }) {
                HStack {
                    Image(systemName: "key.fill")
                    Text("Present Credential")
                }
            }
            .disabled(isGATTBusy)
        }
    }

    private var gattStateText: String {
        guard let client = beaconManager.gattClient else {
            return "Idle"
        }
        return client.state.description
    }

    private var gattStateColor: Color {
        guard let client = beaconManager.gattClient else {
            return .secondary
        }
        switch client.state {
        case .idle:
            return .secondary
        case .scanning, .connecting, .discoveringServices, .discoveringCharacteristics, .subscribing:
            return .blue
        case .authenticating, .sendingCredential:
            return .orange
        case .complete(let result):
            return result.success ? .green : .red
        case .failed:
            return .red
        }
    }

    private var isGATTBusy: Bool {
        guard let client = beaconManager.gattClient else {
            return false
        }
        switch client.state {
        case .idle, .complete, .failed:
            return false
        default:
            return true
        }
    }

    // MARK: - Beacons Section

    private var beaconsSection: some View {
        Section("Detected Beacons (\(beaconManager.detectedBeacons.count))") {
            if beaconManager.detectedBeacons.isEmpty {
                HStack {
                    Spacer()
                    if beaconManager.isRanging {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Scanning for beacons...")
                            .foregroundColor(.secondary)
                    } else {
                        Text("No beacons in range")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            } else {
                ForEach(beaconManager.detectedBeacons) { beacon in
                    BeaconRow(beacon: beacon)
                }
            }
        }
    }

    // MARK: - Event Log Section

    private var eventLogSection: some View {
        Section("Event Log (\(beaconManager.eventLog.count))") {
            if beaconManager.eventLog.isEmpty {
                Text("No events recorded")
                    .foregroundColor(.secondary)
            } else {
                ForEach(beaconManager.eventLog) { event in
                    EventLogRow(event: event)
                }
            }
        }
    }

    // MARK: - Helpers

    private var authorizationStatusText: String {
        switch beaconManager.authorizationStatus {
        case .notDetermined: return "Not Determined"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorizedWhenInUse: return "When In Use"
        case .authorizedAlways: return "Always"
        @unknown default: return "Unknown"
        }
    }

    private var authorizationStatusColor: Color {
        switch beaconManager.authorizationStatus {
        case .authorizedAlways: return .green
        case .authorizedWhenInUse: return .yellow
        case .denied, .restricted: return .red
        default: return .secondary
        }
    }
}

// MARK: - Beacon Row

struct BeaconRow: View {
    let beacon: CLBeacon

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(proximityColor)
                    .frame(width: 12, height: 12)
                Text(beacon.proximity.description)
                    .font(.headline)
                Spacer()
                Text("\(String(format: "%.2f", beacon.accuracy)) m")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("UUID: \(beacon.uuid.uuidString)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Major: \(beacon.major.intValue)")
                        .font(.caption)
                    Text("Minor: \(beacon.minor.intValue)")
                        .font(.caption)
                    Spacer()
                    Text("RSSI: \(beacon.rssi) dBm")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var proximityColor: Color {
        switch beacon.proximity {
        case .immediate: return .green
        case .near: return .yellow
        case .far: return .orange
        case .unknown: return .gray
        @unknown default: return .gray
        }
    }
}

// MARK: - Event Log Row

struct EventLogRow: View {
    let event: BeaconEvent

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            eventIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.message)
                    .font(.caption)
                    .foregroundColor(eventColor)

                Text("\(dateFormatter.string(from: event.timestamp)) \(timeFormatter.string(from: event.timestamp))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var eventIcon: some View {
        Group {
            switch event.type {
            case .regionEnter:
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.green)
            case .regionExit:
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundColor(.orange)
            case .stateChange:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.blue)
            case .authorization:
                Image(systemName: "lock.shield")
                    .foregroundColor(.purple)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            case .info:
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
            case .gatt:
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.cyan)
            }
        }
    }

    private var eventColor: Color {
        switch event.type {
        case .regionEnter: return .green
        case .regionExit: return .orange
        case .error: return .red
        case .gatt: return .cyan
        default: return .primary
        }
    }
}

#Preview {
    ContentView()
}
