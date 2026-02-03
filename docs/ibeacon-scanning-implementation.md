# iBeacon Scanning Implementation

**Type:** Story
**Priority:** Medium
**Labels:** `ios`, `bluetooth`, `location-services`

---

## Context

The application requires the ability to detect and respond to iBeacon devices in the environment (intercom / reader devices). When a registered iBeacon is detected, the app should wake (if in background).

This feature uses Apple's CoreLocation framework to monitor and range iBeacon devices. The target beacon region uses the following UUID:

```
GET THE UUID FROM FAISAL :)
```

Background scanning is enabled so the app can respond to beacon proximity even when not in the foreground or when the device is locked.

---

## Acceptance Criteria

### 1. Configure App Permissions

- [ ] Add `NSLocationAlwaysAndWhenInUseUsageDescription` to Info.plist with user-facing explanation
- [ ] Add `NSLocationWhenInUseUsageDescription` to Info.plist with user-facing explanation
- [ ] Enable "Background Modes" capability in project settings
- [ ] Enable "Location updates" under Background Modes

### 2. Implement BeaconManager

- [ ] Create `BeaconManager.swift` as an `ObservableObject`
- [ ] Initialize `CLLocationManager` with appropriate delegate
- [ ] Implement location authorization request flow (When In Use → Always)
- [ ] Define `CLBeaconRegion` with UUID `E7B2C021-5D07-4D0B-9C20-223488C8B012`
- [ ] Implement region monitoring (start/stop)
- [ ] Implement beacon ranging (start/stop)
- [ ] Expose detected beacons and their properties to the UI
- [ ] Implement event logging with persistence
- [ ] Implement local notifications for wake-up events

### 3. Handle Region Events

- [ ] Implement `didEnterRegion` delegate method to start ranging
- [ ] Implement `didExitRegion` delegate method to stop ranging
- [ ] Implement `didRange` delegate method to update detected beacon list
- [ ] Handle monitoring/ranging failures gracefully
- [ ] Deduplicate beacons in ranging results

### 4. Update UI

- [ ] Modify `ContentView.swift` to observe `BeaconManager`
- [ ] Display current authorization status
- [ ] Display region monitoring state (inside/outside region)
- [ ] Display list of detected beacons with:
  - UUID
  - Major/Minor values
  - Proximity (immediate/near/far/unknown)
  - Accuracy (meters)
  - RSSI (signal strength)
- [ ] Display event log with timestamps
- [ ] Add "Clear Log" functionality

### 5. Testing

- [ ] Verify permission prompts appear correctly
- [ ] Verify beacon detection works in foreground
- [ ] Verify app wakes from background when entering beacon region
- [ ] Verify UI updates with beacon information
- [ ] Verify local notifications appear on lock screen

---

## Implementation Details

### Files

| File | Description |
|------|-------------|
| `Info.plist` | Contains location permission strings and background mode configuration |
| `BeaconManager.swift` | Core beacon monitoring/ranging logic, event logging, and notifications |
| `ContentView.swift` | SwiftUI view displaying status, detected beacons, and event log |

### Info.plist Configuration

```xml
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>This app needs location access to detect nearby iBeacons even when running in the background or when the device is locked.</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>This app needs location access to detect nearby iBeacons.</string>

<key>UIBackgroundModes</key>
<array>
    <string>location</string>
</array>
```

### BeaconManager Architecture

```
BeaconManager (ObservableObject)
├── Published Properties
│   ├── authorizationStatus: CLAuthorizationStatus
│   ├── isInsideRegion: Bool
│   ├── detectedBeacons: [CLBeacon]
│   ├── lastError: String?
│   ├── isMonitoring: Bool
│   ├── isRanging: Bool
│   └── eventLog: [BeaconEvent]
├── CLLocationManagerDelegate
│   ├── locationManagerDidChangeAuthorization
│   ├── didStartMonitoringFor
│   ├── didDetermineState
│   ├── didEnterRegion → logs + notification + starts ranging
│   ├── didExitRegion → logs + notification + stops ranging
│   ├── didRange → deduplicates and updates beacon list
│   └── error handlers
├── Event Logging
│   ├── Persisted to UserDefaults
│   ├── System logging via os.log
│   └── Max 100 entries retained
└── Local Notifications
    ├── "Beacon Detected" on region enter
    └── "Beacon Lost" on region exit
```

### Event Types

| Type | Icon | Description |
|------|------|-------------|
| `regionEnter` | ↓ (green) | App woke up due to entering beacon region |
| `regionExit` | ↑ (orange) | App woke up due to exiting beacon region |
| `stateChange` | ⟳ (blue) | Region state was determined |
| `authorization` | 🛡 (purple) | Location authorization changed |
| `error` | ⚠ (red) | An error occurred |
| `info` | ℹ (gray) | General information |

### Beacon Deduplication

The `didRange` callback can return multiple entries for the same physical beacon. The implementation deduplicates by `uuid-major-minor` key and keeps the entry with the best (lowest positive) accuracy value.

---

## Background Behavior

### What Happens When Phone is Locked

1. Device detects beacon → iOS wakes the app in background
2. App receives `didEnterRegion` or `didExitRegion` callback
3. App logs the event with timestamp (persisted to UserDefaults)
4. App sends a local notification (appears on lock screen/notification center)
5. **Screen stays dark** - iOS does not turn on the display
6. App gets ~10 seconds of background execution time
7. When user unlocks and opens app, event log shows the wake-up events

### Ranging Limitation

Ranging (getting proximity/RSSI data) **only works in foreground**. When the app is woken in background:
- Region monitoring events work ✓
- Ranging does not start until app comes to foreground

---

## Notes

### Authorization Flow Complexity

iOS requires a two-step authorization process for "Always" location access:

1. App requests authorization → user grants "When In Use"
2. App requests "Always" → iOS may show prompt or require user to manually upgrade in Settings

The implementation handles all authorization states:
- `.notDetermined` → requests "When In Use"
- `.authorizedWhenInUse` → requests "Always"
- `.authorizedAlways` → starts monitoring
- `.restricted` / `.denied` → shows error

### Region Monitoring Limits

iOS allows a maximum of **20 monitored regions** per app. This implementation uses only 1 region.

### Ranging vs Monitoring

| Aspect | Monitoring | Ranging |
|--------|------------|---------|
| Works in background | Yes | No |
| Battery impact | Low | Higher |
| Data provided | Enter/exit events only | Proximity, accuracy, RSSI |
| Use case | Wake app on region entry | Real-time distance tracking |

### Simulator Limitations

iBeacon functionality **does not work in the iOS Simulator**. Testing requires:
- A physical iOS device running the app
- A separate device or hardware beacon advertising iBeacon packets

### UUID Configuration

The UUID is currently hardcoded in `BeaconManager.swift`:
```swift
private let beaconUUID = UUID(uuidString: "E7B2C021-5D07-4D0B-9C20-223488C8B012")!
```

### Proximity Accuracy

The `proximity` value (immediate/near/far) is Apple's interpretation of distance. The `accuracy` value in meters is an estimate and can fluctuate significantly based on:
- Environmental interference
- Beacon transmit power
- Obstacles between devices

---

## Xcode Setup (Manual Steps Required)

The following steps must be completed manually in Xcode:

### 1. Add Info.plist to Target

If the `Info.plist` file is not automatically recognized:

1. Open the project in Xcode
2. Select the target **ble-ios-app-playground**
3. Go to **Build Settings**
4. Search for "Info.plist"
5. Set **Info.plist File** to `ble-ios-app-playground/Info.plist`

### 2. Enable Background Modes Capability

1. Select the project in the Navigator
2. Select the **ble-ios-app-playground** target
3. Go to **Signing & Capabilities** tab
4. Click **+ Capability**
5. Search for and add **Background Modes**
6. Check **Location updates**

This enables the app to receive location updates (including beacon region events) while in the background.

### 3. Verify Signing

Ensure the app has a valid signing configuration with a Development Team selected, as background modes and location services require proper code signing to function on physical devices.

### 4. Allow Notifications

When the app launches, it will request notification permission. Grant this to receive alerts when beacons are detected while the phone is locked.

---

## Device Permissions Checklist

On the iOS device, verify these settings:

| Setting | Path | Required Value |
|---------|------|----------------|
| Location Services | Settings → Privacy & Security → Location Services | On |
| App Location | Settings → Privacy & Security → Location Services → ble-ios-app-playground | **Always** |
| Notifications | Settings → Notifications → ble-ios-app-playground | Allow Notifications: On |
