# GATT Client Implementation

**Type:** Feature
**Priority:** High
**Labels:** `ios`, `bluetooth`, `gatt`, `security`, `authentication`

---

## Context

The application requires the ability to authenticate with credential readers (GATT servers) and present encrypted credentials over BLE. When the device enters an iBeacon region, the app automatically connects to a nearby credential reader, performs mutual authentication using symmetric key cryptography, and transmits an encrypted credential.

This feature uses Apple's CoreBluetooth framework to implement a GATT central (client) role. The implementation follows the WaveLynx LEAF SDK pattern of using a single characteristic for bidirectional communication via Write (commands) and Notify (responses).

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         System Architecture                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Mobile Device (Central)              Reader (Peripheral)           │
│   ┌─────────────────────┐              ┌─────────────────────┐      │
│   │                     │              │                     │      │
│   │  Device ID (16B)    │              │  Master Key (16B)   │      │
│   │  Device Key (DK)    │              │                     │      │
│   │                     │              │                     │      │
│   │  (DK provisioned    │              │  On AUTH_REQUEST:   │      │
│   │   to device during  │              │  1. Extract DeviceID│      │
│   │   enrollment -      │              │  2. Derive DK:      │      │
│   │   device never      │              │     DK = HKDF(      │      │
│   │   knows MasterKey)  │              │       MasterKey,    │      │
│   │                     │              │       DeviceID      │      │
│   └─────────┬───────────┘              └──────────┬──────────┘      │
│             │                                     │                  │
│             │         BLE Connection              │                  │
│             │◄───────────────────────────────────►│                  │
│             │                                     │                  │
│             │  Write ──────────────────────────►  │                  │
│             │  (Commands)                         │                  │
│             │                                     │                  │
│             │  ◄────────────────────────── Notify │                  │
│             │                         (Responses) │                  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Module Structure

```
ble-ios-app-playground/
└── GATTClient/
    ├── GATTConfig.swift      # UUIDs, POC values, timeouts, constants
    ├── GATTCrypto.swift      # AES-128-CBC encryption/decryption
    ├── GATTProtocol.swift    # Message types, builders, parsers
    └── GATTClient.swift      # CoreBluetooth central, state machine
```

### File Descriptions

| File | Description |
|------|-------------|
| `GATTConfig.swift` | Service/characteristic UUIDs, cryptographic constants, timeouts, and POC configuration values |
| `GATTCrypto.swift` | AES-128-CBC encryption/decryption using CommonCrypto, PKCS7 padding, secure random generation |
| `GATTProtocol.swift` | Protocol message types, builders (AuthRequest, Credential), and parsers (AuthResponse, CredentialResponse) |
| `GATTClient.swift` | Main client class with CoreBluetooth delegates, state machine, retry logic, and timeout handling |

---

## GATT Service Specification

### Service Discovery

| Property | Value |
|----------|-------|
| **Service Name** | Credential Service |
| **Service UUID** | `a1b2c3d4-e5f6-7890-abcd-ef1234567890` |

### Data Transfer Characteristic

| Property | Value |
|----------|-------|
| **Characteristic Name** | Data Transfer |
| **Characteristic UUID** | `b2c3d4e5-f678-90ab-cdef-234567890abc` |
| **Properties Used** | Write Without Response, Notify |
| **Descriptors** | CCCD (0x2902) |

---

## Authentication Protocol

### Message Types

| Type | Code | Direction | Description |
|------|------|-----------|-------------|
| AUTH_REQUEST | `0x01` | Mobile → Reader | Initiate authentication |
| AUTH_RESPONSE | `0x02` | Reader → Mobile | Authentication challenge response |
| CREDENTIAL | `0x03` | Mobile → Reader | Send encrypted credential |
| CREDENTIAL_RESPONSE | `0x04` | Reader → Mobile | Credential processing result |
| ERROR | `0xFF` | Reader → Mobile | Error notification |

### AUTH_REQUEST (0x01)

Sent by the mobile device to initiate authentication.

```
┌──────┬────────────┬────────────┬─────────────────────┐
│ 0x01 │ Device ID  │     IV     │   Enc_DK(Nonce_M)   │
│  1B  │    16B     │    16B     │        32B          │
└──────┴────────────┴────────────┴─────────────────────┘
Total: 65 bytes
```

**Build Process:**
1. Generate `Nonce_M`: 16 cryptographically random bytes
2. **Save `Nonce_M` in memory** (needed for verification)
3. Generate `IV_M`: 16 cryptographically random bytes
4. Encrypt: `Ciphertext = AES-128-CBC-Encrypt(DK, IV_M, Nonce_M)`
5. Build: `[0x01] + DeviceID + IV_M + Ciphertext`

### AUTH_RESPONSE (0x02)

Sent by the reader to prove it has the correct Device Key.

```
┌──────┬────────────┬─────────────────────────────┐
│ 0x02 │     IV     │  Enc_DK(Nonce_M || Nonce_R) │
│  1B  │    16B     │            48B              │
└──────┴────────────┴─────────────────────────────┘
Total: 65 bytes
```

**Parse Process:**
1. Verify message type: `response[0] == 0x02`
2. Extract `IV_R`: `response[1:17]`
3. Extract `Encrypted_Nonces`: `response[17:65]`
4. Decrypt: `Decrypted = AES-128-CBC-Decrypt(DK, IV_R, Encrypted_Nonces)`
5. Extract `Received_Nonce_M`: `Decrypted[0:16]`
6. Extract `Nonce_R`: `Decrypted[16:32]`
7. **VERIFY**: `Received_Nonce_M == Nonce_M` (saved earlier)

### CREDENTIAL (0x03)

Sent after successful authentication to transmit the credential.

```
┌──────┬────────────┬─────────────────────────────┐
│ 0x03 │     IV     │   Enc_DK(CredentialPayload) │
│  1B  │    16B     │         Variable            │
└──────┴────────────┴─────────────────────────────┘
Total: 17 + len(encrypted_credential) bytes
```

### CREDENTIAL_RESPONSE (0x04)

```
┌──────┬────────┐
│ 0x04 │ Status │
│  1B  │   1B   │
└──────┴────────┘
Total: 2 bytes
```

**Status Codes:**

| Code | Name | User Message |
|------|------|--------------|
| `0x00` | SUCCESS | "Access granted" |
| `0x01` | REJECTED | "Access denied" |
| `0x02` | EXPIRED | "Credential expired" |
| `0x03` | REVOKED | "Credential revoked" |
| `0x04` | INVALID_FORMAT | "Invalid credential" |

### ERROR (0xFF)

```
┌──────┬────────────┐
│ 0xFF │ Error Code │
│  1B  │     1B     │
└──────┴────────────┘
Total: 2 bytes
```

**Error Codes:**

| Code | Name | User Message |
|------|------|--------------|
| `0x01` | INVALID_MESSAGE | "Communication error" |
| `0x02` | UNKNOWN_DEVICE | "Device not recognized" |
| `0x03` | DECRYPTION_FAILED | "Authentication failed" |
| `0x04` | INVALID_STATE | "Protocol error" |
| `0x05` | AUTH_FAILED | "Authentication failed" |
| `0x06` | TIMEOUT | "Reader timeout" |

---

## State Machine

```
         ┌──────────────┐
         │     IDLE     │◄─────────────────────────────────┐
         └──────┬───────┘                                  │
                │ presentCredential()                      │
                ▼                                          │
         ┌──────────────┐                                  │
         │   SCANNING   │──── Timeout (30s) ────► IDLE     │
         └──────┬───────┘     "No reader found"            │
                │ Found reader                             │
                ▼                                          │
         ┌──────────────┐                                  │
         │  CONNECTING  │──── Fail ────► IDLE              │
         └──────┬───────┘     "Connection failed"          │
                │ Connected                                │
                ▼                                          │
         ┌──────────────┐                                  │
         │  DISCOVERING │──── Fail ────► IDLE              │
         │   SERVICES   │     "Service not found"          │
         └──────┬───────┘                                  │
                │ Service found                            │
                ▼                                          │
         ┌──────────────┐                                  │
         │  DISCOVERING │──── Fail ────► IDLE              │
         │    CHARS     │     "Characteristic not found"   │
         └──────┬───────┘                                  │
                │ Characteristic found                     │
                ▼                                          │
         ┌──────────────┐                                  │
         │  SUBSCRIBING │──── Fail ────► IDLE              │
         └──────┬───────┘     "Subscription failed"        │
                │ CCCD written, notifications enabled      │
                ▼                                          │
         ┌──────────────┐                                  │
         │AUTHENTICATING│──── Timeout (3s) ────► RETRY?    │
         └──────┬───────┘     "Authentication timeout"     │
                │ AUTH_RESPONSE valid                      │
                ▼                                          │
         ┌──────────────┐                                  │
         │ SENDING_CRED │──── Timeout (3s) ────► RETRY?    │
         └──────┬───────┘     "Response timeout"           │
                │ CREDENTIAL_RESPONSE received             │
                ▼                                          │
         ┌──────────────┐                                  │
         │   COMPLETE   │──── Show result ────► IDLE       │
         └──────────────┘     Disconnect                   │
```

### State Descriptions

| State | Description |
|-------|-------------|
| `idle` | Not active, waiting for trigger |
| `scanning` | Scanning for credential service UUID |
| `connecting` | Establishing BLE connection to peripheral |
| `discoveringServices` | Discovering GATT services on peripheral |
| `discoveringCharacteristics` | Discovering characteristics on credential service |
| `subscribing` | Writing CCCD to enable notifications |
| `authenticating` | Sent AUTH_REQUEST, awaiting AUTH_RESPONSE |
| `sendingCredential` | Sent CREDENTIAL, awaiting CREDENTIAL_RESPONSE |
| `complete` | Protocol completed (success or failure) |
| `failed` | Unrecoverable failure after retries |

---

## Cryptographic Specification

### Algorithm Parameters

| Parameter | Value |
|-----------|-------|
| **Encryption Algorithm** | AES-128-CBC |
| **Key Size** | 128 bits (16 bytes) |
| **Block Size** | 16 bytes |
| **IV Size** | 16 bytes |
| **Padding** | PKCS7 |
| **Nonce Size** | 16 bytes |

### Implementation

The `GATTCrypto.swift` module uses Apple's CommonCrypto framework (`CCCrypt`) for AES operations. Key functions:

```swift
// Generate cryptographically secure random bytes
func generateRandomBytes(count: Int) throws -> Data

// AES-128-CBC encryption with PKCS7 padding
func encrypt(key: Data, plaintext: Data, iv: Data? = nil) throws -> (iv: Data, ciphertext: Data)

// AES-128-CBC decryption with PKCS7 unpadding
func decrypt(key: Data, iv: Data, ciphertext: Data) throws -> Data
```

### Security Notes

- Random bytes generated via `SecRandomCopyBytes` (cryptographically secure)
- IV is generated fresh for each encryption operation
- PKCS7 padding is validated during decryption
- Keys should be stored in iOS Keychain (not implemented in POC)

---

## Configuration

### POC Values

Located in `GATTConfig.swift`:

```swift
// Service & Characteristic UUIDs
let CREDENTIAL_SERVICE_UUID = CBUUID(string: "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
let DATA_TRANSFER_CHAR_UUID = CBUUID(string: "b2c3d4e5-f678-90ab-cdef-234567890abc")

// POC Device Identity
let POC_DEVICE_ID = Data(hexString: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4")!
let POC_DEVICE_KEY = Data(hexString: "13f75379273f324d31335278a66062af")!
let POC_CREDENTIAL = "prod-pin_access_tool-7603489"

// Timeouts
let SCAN_TIMEOUT: TimeInterval = 30.0
let RESPONSE_TIMEOUT: TimeInterval = 3.0
let MAX_RETRIES = 3
```

### Key Derivation (Reference)

The POC Device Key was derived using HKDF-SHA256:

```
Master Key: 00112233445566778899aabbccddeeff
Device ID:  a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4
Info:       "device-key"
Salt:       Device ID

Device Key: 13f75379273f324d31335278a66062af
```

---

## Integration with BeaconManager

### Trigger Flow

1. iBeacon region entry detected (`didEnterRegion`)
2. BeaconManager checks `hasCredentialBeenPresented` flag
3. If not presented, creates `GATTClient` instance
4. Calls `gattClient.presentCredential()`
5. Observes state changes for logging
6. Handles completion with local notification
7. On region exit, resets `hasCredentialBeenPresented` flag

### Code Example

```swift
// In BeaconManager.swift
private func presentCredentialIfNeeded() {
    guard !hasCredentialBeenPresented else { return }

    hasCredentialBeenPresented = true

    let client = GATTClient(config: .poc)
    gattClient = client

    client.completionHandler = { [weak self] result in
        self?.handleGATTCompletion(result)
    }

    client.presentCredential()
}
```

---

## UI Integration

### GATT Client Section in ContentView

The UI displays:
- Current state (Idle, Scanning, Connecting, etc.)
- Connected peripheral name (when connected)
- Discovered Service UUID
- Discovered Characteristic UUID
- Last result (Access Granted/Denied)
- Manual "Present Credential" button

### Event Log Types

| Type | Icon | Color | Description |
|------|------|-------|-------------|
| `gatt` | 📡 | Cyan | GATT client state changes and results |

---

## Info.plist Configuration

```xml
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
    <string>bluetooth-central</string>
</array>

<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to communicate with credential readers for door access.</string>
```

---

## Error Handling

### Timeout Configuration

| Operation | Timeout | On Timeout |
|-----------|---------|------------|
| BLE Scan | 30 seconds | "No reader found" |
| AUTH_RESPONSE wait | 3 seconds | "Authentication timeout" |
| CREDENTIAL_RESPONSE wait | 3 seconds | "Response timeout" |

### Retry Logic

- Maximum 3 retry attempts on failure
- 1 second delay between retries
- Failures include: timeouts, connection drops, authentication failures
- After 3 failures, state transitions to `.failed`

### Nonce Verification Failure

If the reader's `Nonce_M` doesn't match what we sent:
1. **Do not send any more messages**
2. Disconnect immediately
3. Display "Authentication failed - reader verification failed"
4. Return to idle state

---

## Background Behavior

### Requirements

- `bluetooth-central` background mode enabled
- App must be woken by iBeacon region entry first
- CoreBluetooth state restoration enabled

### What Happens When App is Woken

1. iBeacon region entry wakes the app
2. `BeaconManager.didEnterRegion` is called
3. GATTClient is created and starts scanning
4. BLE operations proceed in background
5. Local notification sent on completion
6. App has ~10 seconds of background execution time

### State Restoration

The GATTClient is initialized with a restoration identifier:

```swift
centralManager = CBCentralManager(
    delegate: self,
    queue: DispatchQueue.main,
    options: [CBCentralManagerOptionRestoreIdentifierKey: "com.playground.gatt-client"]
)
```

---

## Testing

### Prerequisites

- Physical iOS device (BLE doesn't work in Simulator)
- GATT server running the credential service
- iBeacon broadcasting the configured UUID

### Manual Test Flow

1. Launch app, verify GATT section shows "Idle"
2. Start GATT server with credential service
3. Press "Present Credential" button manually
4. Verify state progression: Scanning → Connecting → Discovering → Subscribing → Authenticating → Sending → Complete
5. Verify "Access granted" result (with valid server)

### Background Test Flow

1. Lock device
2. Bring device near iBeacon
3. Verify notification appears ("Access Granted" or "Access Denied")
4. Open app, verify event log shows the credential presentation

### Test with Invalid Key

1. Modify `POC_DEVICE_KEY` to an incorrect value
2. Attempt credential presentation
3. Verify "Authentication failed" error
4. Verify retries occur (up to 3 attempts)

---

## Security Considerations

### Implemented

- **Mutual authentication**: Both parties prove possession of shared key
- **Replay protection**: Random nonces per session
- **Encryption**: All sensitive data encrypted with AES-128-CBC
- **Nonce verification**: Client verifies reader's response

### POC Limitations (Not Production-Ready)

| Feature | Status | Production Recommendation |
|---------|--------|---------------------------|
| Key Storage | Hardcoded | Use iOS Keychain |
| Key Rotation | Not implemented | Implement key refresh protocol |
| Message Integrity | CBC (confidentiality only) | Use AES-GCM for authenticated encryption |
| Certificate Pinning | Not implemented | Add PKI infrastructure |
| Secure Pairing | Pre-provisioned keys | Implement secure enrollment |

### Security Checklist

- [ ] Device Key stored in iOS Keychain (not hardcoded)
- [ ] Nonce_M kept only in memory during auth, cleared after
- [ ] IV generated fresh for each encryption operation
- [ ] Verify Nonce_M match before trusting reader
- [ ] Clear sensitive data from memory after disconnect
- [ ] Do not log sensitive data (keys, nonces, credentials)

---

## API Reference

### GATTClient

```swift
class GATTClient: NSObject, ObservableObject {
    // Published state
    @Published private(set) var state: GATTClientState
    @Published private(set) var connectedPeripheralName: String?
    @Published private(set) var discoveredServiceUUID: String?
    @Published private(set) var discoveredCharacteristicUUID: String?
    @Published private(set) var lastResult: CredentialResult?

    // Completion callback
    var completionHandler: ((CredentialResult) -> Void)?

    // Initialize with configuration
    init(config: GATTClientConfig = .poc)

    // Start credential presentation
    func presentCredential()

    // Cancel current operation
    func cancel()
}
```

### GATTClientConfig

```swift
struct GATTClientConfig {
    let deviceId: Data      // 16 bytes
    let deviceKey: Data     // 16 bytes
    let credential: String  // Credential string

    static var poc: GATTClientConfig  // POC configuration
}
```

### CredentialResult

```swift
struct CredentialResult {
    let success: Bool
    let message: String
}
```

---

## References

- [BLE GATT Server Specification](../../../ble-door-unlock-demo/src/ble_symmetric_key/server/README.md)
- [BLE GATT Client Specification](../../../ble-door-unlock-demo/src/ble_symmetric_key/client/README.md)
- [Apple CoreBluetooth Documentation](https://developer.apple.com/documentation/corebluetooth)
- [AES-CBC NIST SP 800-38A](https://csrc.nist.gov/publications/detail/sp/800-38a/final)
