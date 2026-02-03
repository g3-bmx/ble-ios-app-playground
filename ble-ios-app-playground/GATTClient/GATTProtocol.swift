//
//  GATTProtocol.swift
//  ble-ios-app-playground
//
//  BLE authentication protocol message definitions.
//  Message format: [Type (1 byte)][Payload (variable)]
//

import Foundation

// MARK: - Message Types

/// Protocol message types
enum MessageType: UInt8 {
    case authRequest = 0x01
    case authResponse = 0x02
    case credential = 0x03
    case credentialResponse = 0x04
    case error = 0xFF
}

// MARK: - Credential Status

/// Credential processing result codes from reader
enum CredentialStatus: UInt8 {
    case success = 0x00
    case rejected = 0x01
    case expired = 0x02
    case revoked = 0x03
    case invalidFormat = 0x04

    /// User-friendly message for the status
    var message: String {
        switch self {
        case .success: return "Access granted"
        case .rejected: return "Access denied"
        case .expired: return "Credential expired"
        case .revoked: return "Credential revoked"
        case .invalidFormat: return "Invalid credential"
        }
    }
}

// MARK: - Error Codes

/// Protocol error codes from reader
enum GATTErrorCode: UInt8 {
    case invalidMessage = 0x01
    case unknownDevice = 0x02
    case decryptionFailed = 0x03
    case invalidState = 0x04
    case authFailed = 0x05
    case timeout = 0x06

    /// User-friendly message for the error
    var message: String {
        switch self {
        case .invalidMessage: return "Communication error"
        case .unknownDevice: return "Device not recognized"
        case .decryptionFailed: return "Authentication failed"
        case .invalidState: return "Protocol error"
        case .authFailed: return "Authentication failed"
        case .timeout: return "Reader timeout"
        }
    }
}

// MARK: - Protocol Errors

enum GATTProtocolError: Error, LocalizedError {
    case emptyResponse
    case unexpectedMessageType(UInt8)
    case responseTooShort(expected: Int, actual: Int)
    case nonceMismatch
    case unknownStatus(UInt8)
    case unknownError(UInt8)
    case readerError(GATTErrorCode)
    case cryptoError(Error)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Empty response from reader"
        case .unexpectedMessageType(let type):
            return "Unexpected message type: 0x\(String(format: "%02x", type))"
        case .responseTooShort(let expected, let actual):
            return "Response too short: \(actual) bytes (expected \(expected))"
        case .nonceMismatch:
            return "Reader authentication failed - nonce mismatch"
        case .unknownStatus(let status):
            return "Unknown status code: 0x\(String(format: "%02x", status))"
        case .unknownError(let code):
            return "Unknown error code: 0x\(String(format: "%02x", code))"
        case .readerError(let errorCode):
            return errorCode.message
        case .cryptoError(let error):
            return "Crypto error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Auth Request Builder

/// Builds AUTH_REQUEST messages
/// Format: [0x01][DeviceID (16B)][IV (16B)][Enc_DK(Nonce_M) (32B)]
/// Total: 65 bytes (encrypted nonce is 32 bytes due to PKCS7 padding)
struct AuthRequestBuilder {
    let deviceId: Data
    let deviceKey: Data

    /// Build AUTH_REQUEST message
    /// - Returns: Tuple of (message bytes, nonce_m) - caller must save nonce_m for verification
    /// - Throws: GATTCryptoError on failure
    func build() throws -> (message: Data, nonceM: Data) {
        let nonceM = try generateNonce()
        let (iv, encryptedNonce) = try encrypt(key: deviceKey, plaintext: nonceM)

        var message = Data()
        message.append(MessageType.authRequest.rawValue)
        message.append(deviceId)
        message.append(iv)
        message.append(encryptedNonce)

        return (message, nonceM)
    }
}

// MARK: - Auth Response Parser

/// Parses AUTH_RESPONSE messages and verifies mutual authentication
/// Format: [0x02][IV (16B)][Enc_DK(Nonce_M || Nonce_R) (48B)]
/// Total: 65 bytes (encrypted nonces are 48 bytes due to PKCS7 padding on 32-byte plaintext)
struct AuthResponseParser {
    let deviceKey: Data

    /// Size of encrypted nonces: 32-byte plaintext + 16-byte PKCS7 padding = 48 bytes
    private let encryptedNoncesSize = 48

    /// Expected response length: 1 (type) + 16 (IV) + 48 (encrypted nonces) = 65
    private var expectedLength: Int { 1 + IV_SIZE + encryptedNoncesSize }

    /// Parse AUTH_RESPONSE and verify mutual authentication
    /// - Parameters:
    ///   - data: Raw response bytes
    ///   - expectedNonceM: The Nonce_M we sent, for verification
    /// - Returns: Nonce_R from the reader (if successful)
    /// - Throws: GATTProtocolError on failure
    func parse(_ data: Data, expectedNonceM: Data) throws -> Data {
        guard !data.isEmpty else {
            throw GATTProtocolError.emptyResponse
        }

        // Check for error response
        if data[0] == MessageType.error.rawValue {
            if data.count >= 2, let errorCode = GATTErrorCode(rawValue: data[1]) {
                throw GATTProtocolError.readerError(errorCode)
            }
            throw GATTProtocolError.unknownError(data.count >= 2 ? data[1] : 0)
        }

        // Verify message type
        guard data[0] == MessageType.authResponse.rawValue else {
            throw GATTProtocolError.unexpectedMessageType(data[0])
        }

        // Verify length
        guard data.count >= expectedLength else {
            throw GATTProtocolError.responseTooShort(expected: expectedLength, actual: data.count)
        }

        // Extract IV and encrypted nonces
        let iv = data[1..<(1 + IV_SIZE)]
        let encryptedNonces = data[(1 + IV_SIZE)..<(1 + IV_SIZE + encryptedNoncesSize)]

        // Decrypt
        let decrypted: Data
        do {
            decrypted = try decrypt(key: deviceKey, iv: Data(iv), ciphertext: Data(encryptedNonces))
        } catch {
            throw GATTProtocolError.cryptoError(error)
        }

        // Should be 32 bytes: Nonce_M (16) + Nonce_R (16)
        guard decrypted.count == 32 else {
            throw GATTProtocolError.responseTooShort(expected: 32, actual: decrypted.count)
        }

        let receivedNonceM = decrypted[0..<16]
        let nonceR = decrypted[16..<32]

        // Verify reader echoed our nonce correctly
        guard receivedNonceM == expectedNonceM else {
            throw GATTProtocolError.nonceMismatch
        }

        return Data(nonceR)
    }
}

// MARK: - Credential Builder

/// Builds CREDENTIAL messages
/// Format: [0x03][IV (16B)][Enc_DK(CredentialPayload) (variable)]
struct CredentialBuilder {
    let deviceKey: Data

    /// Build CREDENTIAL message
    /// - Parameter credential: Credential string to send
    /// - Returns: Message bytes
    /// - Throws: GATTCryptoError on failure
    func build(credential: String) throws -> Data {
        let payload = credential.data(using: .utf8)!
        let (iv, encryptedPayload) = try encrypt(key: deviceKey, plaintext: payload)

        var message = Data()
        message.append(MessageType.credential.rawValue)
        message.append(iv)
        message.append(encryptedPayload)

        return message
    }
}

// MARK: - Credential Response Parser

/// Result of credential presentation
struct CredentialResult {
    let success: Bool
    let message: String
}

/// Parse CREDENTIAL_RESPONSE message
/// - Parameter data: Raw response bytes
/// - Returns: CredentialResult with success status and message
/// - Throws: GATTProtocolError on failure
func parseCredentialResponse(_ data: Data) throws -> CredentialResult {
    guard !data.isEmpty else {
        throw GATTProtocolError.emptyResponse
    }

    // Check for error response
    if data[0] == MessageType.error.rawValue {
        if data.count >= 2, let errorCode = GATTErrorCode(rawValue: data[1]) {
            return CredentialResult(success: false, message: errorCode.message)
        }
        throw GATTProtocolError.unknownError(data.count >= 2 ? data[1] : 0)
    }

    // Verify message type
    guard data[0] == MessageType.credentialResponse.rawValue else {
        throw GATTProtocolError.unexpectedMessageType(data[0])
    }

    // Verify length
    guard data.count >= 2 else {
        throw GATTProtocolError.responseTooShort(expected: 2, actual: data.count)
    }

    // Parse status
    guard let status = CredentialStatus(rawValue: data[1]) else {
        throw GATTProtocolError.unknownStatus(data[1])
    }

    return CredentialResult(
        success: status == .success,
        message: status.message
    )
}
