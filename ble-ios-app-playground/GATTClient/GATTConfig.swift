//
//  GATTConfig.swift
//  ble-ios-app-playground
//
//  GATT Client configuration - UUIDs, POC values, and timeouts.
//  This file contains all configurable constants for the GATT client.
//

import Foundation
import CoreBluetooth

// MARK: - GATT Service & Characteristic UUIDs

/// UUID for the Credential Service advertised by the reader
let CREDENTIAL_SERVICE_UUID = CBUUID(string: "a1b2c3d4-e5f6-7890-abcd-ef1234567890")

/// UUID for the Data Transfer characteristic used for bidirectional communication
let DATA_TRANSFER_CHAR_UUID = CBUUID(string: "b2c3d4e5-f678-90ab-cdef-234567890abc")

// MARK: - Cryptographic Constants

/// Size of encryption key in bytes (AES-128)
let KEY_SIZE = 16

/// Size of initialization vector in bytes
let IV_SIZE = 16

/// Size of nonce in bytes
let NONCE_SIZE = 16

/// Size of device ID in bytes
let DEVICE_ID_SIZE = 16

// MARK: - Timeouts

/// Timeout for BLE scanning (seconds)
let SCAN_TIMEOUT: TimeInterval = 30.0

/// Timeout for waiting for protocol responses (seconds)
let RESPONSE_TIMEOUT: TimeInterval = 3.0

/// Timeout for BLE connection (seconds)
let CONNECTION_TIMEOUT: TimeInterval = 5.0

/// Maximum number of retry attempts for credential presentation
let MAX_RETRIES = 3

// MARK: - POC Configuration

/// POC Device ID (must match server configuration)
/// In production, this would be assigned during device enrollment
let POC_DEVICE_ID = Data(hexString: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4")!

/// POC Device Key (derived from MasterKey + DeviceID using HKDF-SHA256)
/// Master Key: 00112233445566778899aabbccddeeff
/// Device ID:  a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4
/// This was pre-computed using the server's key derivation
let POC_DEVICE_KEY = Data(hexString: "13f75379273f324d31335278a66062af")!

/// POC Credential string to present to the reader
let POC_CREDENTIAL = "prod-pin_access_tool-7603489"

// MARK: - Data Extension for Hex String

extension Data {
    /// Initialize Data from a hex string
    /// - Parameter hexString: Hex string (e.g., "deadbeef")
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex

        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    /// Convert Data to hex string
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
