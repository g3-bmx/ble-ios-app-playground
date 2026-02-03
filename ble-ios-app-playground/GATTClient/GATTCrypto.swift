//
//  GATTCrypto.swift
//  ble-ios-app-playground
//
//  Cryptographic utilities for BLE symmetric key authentication.
//  Provides AES-128-CBC encryption/decryption with PKCS7 padding.
//

import Foundation
import CommonCrypto

// MARK: - Crypto Errors

enum GATTCryptoError: Error, LocalizedError {
    case invalidKeySize
    case invalidIVSize
    case invalidCiphertextSize
    case encryptionFailed(CCCryptorStatus)
    case decryptionFailed(CCCryptorStatus)
    case paddingError
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .invalidKeySize:
            return "Key must be \(KEY_SIZE) bytes"
        case .invalidIVSize:
            return "IV must be \(IV_SIZE) bytes"
        case .invalidCiphertextSize:
            return "Ciphertext length must be a multiple of block size"
        case .encryptionFailed(let status):
            return "Encryption failed with status: \(status)"
        case .decryptionFailed(let status):
            return "Decryption failed with status: \(status)"
        case .paddingError:
            return "Invalid PKCS7 padding"
        case .randomGenerationFailed:
            return "Failed to generate random bytes"
        }
    }
}

// MARK: - Random Generation

/// Generate cryptographically secure random bytes
/// - Parameter count: Number of bytes to generate
/// - Returns: Random data
/// - Throws: GATTCryptoError.randomGenerationFailed if generation fails
func generateRandomBytes(count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    guard status == errSecSuccess else {
        throw GATTCryptoError.randomGenerationFailed
    }
    return Data(bytes)
}

/// Generate a random 16-byte nonce
/// - Returns: 16-byte nonce
func generateNonce() throws -> Data {
    return try generateRandomBytes(count: NONCE_SIZE)
}

/// Generate a random 16-byte IV for AES-CBC
/// - Returns: 16-byte IV
func generateIV() throws -> Data {
    return try generateRandomBytes(count: IV_SIZE)
}

// MARK: - PKCS7 Padding

/// Apply PKCS7 padding to data for AES block size (16 bytes)
/// - Parameter data: Data to pad
/// - Returns: Padded data
func applyPKCS7Padding(_ data: Data) -> Data {
    let blockSize = kCCBlockSizeAES128
    let paddingLength = blockSize - (data.count % blockSize)
    var paddedData = data
    paddedData.append(contentsOf: [UInt8](repeating: UInt8(paddingLength), count: paddingLength))
    return paddedData
}

/// Remove PKCS7 padding from data
/// - Parameter data: Padded data
/// - Returns: Unpadded data
/// - Throws: GATTCryptoError.paddingError if padding is invalid
func removePKCS7Padding(_ data: Data) throws -> Data {
    guard !data.isEmpty else {
        throw GATTCryptoError.paddingError
    }

    let paddingLength = Int(data[data.count - 1])

    // Validate padding length
    guard paddingLength > 0 && paddingLength <= kCCBlockSizeAES128 else {
        throw GATTCryptoError.paddingError
    }

    guard data.count >= paddingLength else {
        throw GATTCryptoError.paddingError
    }

    // Validate all padding bytes have the correct value
    let paddingStart = data.count - paddingLength
    for i in paddingStart..<data.count {
        guard data[i] == UInt8(paddingLength) else {
            throw GATTCryptoError.paddingError
        }
    }

    return data.prefix(paddingStart)
}

// MARK: - AES-128-CBC Encryption

/// Encrypt data using AES-128-CBC with PKCS7 padding
/// - Parameters:
///   - key: 16-byte encryption key
///   - plaintext: Data to encrypt
///   - iv: Optional 16-byte IV (generated if not provided)
/// - Returns: Tuple of (iv, ciphertext)
/// - Throws: GATTCryptoError on failure
func encrypt(key: Data, plaintext: Data, iv: Data? = nil) throws -> (iv: Data, ciphertext: Data) {
    guard key.count == KEY_SIZE else {
        throw GATTCryptoError.invalidKeySize
    }

    let actualIV: Data
    if let providedIV = iv {
        guard providedIV.count == IV_SIZE else {
            throw GATTCryptoError.invalidIVSize
        }
        actualIV = providedIV
    } else {
        actualIV = try generateIV()
    }

    // Apply PKCS7 padding
    let paddedData = applyPKCS7Padding(plaintext)

    // Allocate buffer for ciphertext
    let ciphertextSize = paddedData.count
    var ciphertext = Data(count: ciphertextSize)
    var numBytesEncrypted: size_t = 0

    let status = ciphertext.withUnsafeMutableBytes { ciphertextPtr in
        paddedData.withUnsafeBytes { plaintextPtr in
            key.withUnsafeBytes { keyPtr in
                actualIV.withUnsafeBytes { ivPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(0), // No padding - we handle it ourselves
                        keyPtr.baseAddress, KEY_SIZE,
                        ivPtr.baseAddress,
                        plaintextPtr.baseAddress, paddedData.count,
                        ciphertextPtr.baseAddress, ciphertextSize,
                        &numBytesEncrypted
                    )
                }
            }
        }
    }

    guard status == kCCSuccess else {
        throw GATTCryptoError.encryptionFailed(status)
    }

    ciphertext.count = numBytesEncrypted
    return (actualIV, ciphertext)
}

// MARK: - AES-128-CBC Decryption

/// Decrypt data using AES-128-CBC and remove PKCS7 padding
/// - Parameters:
///   - key: 16-byte decryption key
///   - iv: 16-byte IV used during encryption
///   - ciphertext: Encrypted data
/// - Returns: Decrypted plaintext
/// - Throws: GATTCryptoError on failure
func decrypt(key: Data, iv: Data, ciphertext: Data) throws -> Data {
    guard key.count == KEY_SIZE else {
        throw GATTCryptoError.invalidKeySize
    }

    guard iv.count == IV_SIZE else {
        throw GATTCryptoError.invalidIVSize
    }

    guard !ciphertext.isEmpty && ciphertext.count % kCCBlockSizeAES128 == 0 else {
        throw GATTCryptoError.invalidCiphertextSize
    }

    // Allocate buffer for plaintext
    let plaintextSize = ciphertext.count
    var plaintext = Data(count: plaintextSize)
    var numBytesDecrypted: size_t = 0

    let status = plaintext.withUnsafeMutableBytes { plaintextPtr in
        ciphertext.withUnsafeBytes { ciphertextPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(0), // No padding - we handle it ourselves
                        keyPtr.baseAddress, KEY_SIZE,
                        ivPtr.baseAddress,
                        ciphertextPtr.baseAddress, plaintextSize,
                        plaintextPtr.baseAddress, plaintextSize,
                        &numBytesDecrypted
                    )
                }
            }
        }
    }

    guard status == kCCSuccess else {
        throw GATTCryptoError.decryptionFailed(status)
    }

    plaintext.count = numBytesDecrypted

    // Remove PKCS7 padding
    return try removePKCS7Padding(plaintext)
}
