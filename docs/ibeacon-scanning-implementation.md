# iBeacon Scanning Implementation

**Type:** Story
**Priority:** Medium
**Labels:** `ios`, `bluetooth`, `location-services`

---

## Context

The application requires the ability to detect and respond to iBeacon devices in the environment. When a registered iBeacon is detected, the app should wake (if in background) and display information about the detected beacon including its proximity and signal strength.

This feature will use Apple's CoreLocation framework to monitor and range iBeacon devices. The target beacon region uses the following UUID:

```
E7B2C021-5D07-4D0B-9C20-223488C8B012
```

Background scanning is required so the app can respond to beacon proximity even when not in the foreground.

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

### 3. Handle Region Events

- [ ] Implement `didEnterRegion` delegate method to start ranging
- [ ] Implement `didExitRegion` delegate method to stop ranging
- [ ] Implement `didRange` delegate method to update detected beacon list
- [ ] Handle monitoring/ranging failures gracefully

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

### 5. Testing

- [ ] Verify permission prompts appear correctly
- [ ] Verify beacon detection works in foreground
- [ ] Verify app wakes from background when entering beacon region
- [ ] Verify UI updates with beacon information

---

## Notes

### Authorization Flow Complexity

iOS requires a two-step authorization process for "Always" location access:

1. App requests authorization → user grants "When In Use"
2. App requests "Always" → iOS may show prompt or require user to manually upgrade in Settings

The implementation should handle all authorization states:
- `.notDetermined`
- `.restricted`
- `.denied`
- `.authorizedWhenInUse`
- `.authorizedAlways`

Consider displaying guidance to the user if they need to manually enable "Always" in Settings.

### Region Monitoring Limits

iOS allows a maximum of **20 monitored regions** per app. This implementation uses only 1 region, but this limit should be documented if future expansion is planned.

### Ranging vs Monitoring

| Aspect | Monitoring | Ranging |
|--------|------------|---------|
| Works in background | Yes | No |
| Battery impact | Low | Higher |
| Data provided | Enter/exit events only | Proximity, accuracy, RSSI |
| Use case | Wake app on region entry | Real-time distance tracking |

The implementation should start ranging only after entering a monitored region to balance battery usage with functionality.

### Simulator Limitations

iBeacon functionality **does not work in the iOS Simulator**. Testing requires:
- A physical iOS device running the app
- A separate device or hardware beacon advertising iBeacon packets

### UUID Flexibility

The UUID is currently hardcoded. Consider whether this should be:
- Configurable at runtime
- Stored in app configuration
- Support multiple UUIDs/regions

This decision affects architecture complexity.

### Proximity Accuracy

The `proximity` value (immediate/near/far) is Apple's interpretation of distance. The `accuracy` value in meters is an estimate and can fluctuate significantly based on:
- Environmental interference
- Beacon transmit power
- Obstacles between devices

UI should communicate that distance values are approximate.
