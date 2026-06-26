import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Combine

/// Reports battery level and, while a show is playing, holds the display awake so
/// the screensaver / lock screen never interrupts a broadcast.
@MainActor
final class PowerManager: ObservableObject {
    @Published private(set) var batteryPercent: Int? = nil
    @Published private(set) var isCharging = false
    @Published private(set) var hasBattery = false

    /// True when on battery and getting low — drives the on-screen warning.
    var isLow: Bool {
        guard let p = batteryPercent, hasBattery, !isCharging else { return false }
        return p <= 20
    }

    private var timer: Timer?
    private var assertionID: IOPMAssertionID = 0
    private var assertionActive = false

    init() {
        refresh()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Keep the display awake while playing; release the hold when stopped.
    func setKeepAwake(_ on: Bool) {
        if on, !assertionActive {
            var id: IOPMAssertionID = 0
            let reason = "Crocus is playing a show" as CFString
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason, &id)
            if result == kIOReturnSuccess {
                assertionID = id
                assertionActive = true
            }
        } else if !on, assertionActive {
            IOPMAssertionRelease(assertionID)
            assertionActive = false
            assertionID = 0
        }
    }

    private func refresh() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue()
                  as? [String: Any] else {
            hasBattery = false
            batteryPercent = nil
            return
        }
        if let cur = desc[kIOPSCurrentCapacityKey] as? Int,
           let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
            hasBattery = true
            batteryPercent = Int((Double(cur) / Double(max) * 100).rounded())
        }
        if let state = desc[kIOPSPowerSourceStateKey] as? String {
            isCharging = (state == kIOPSACPowerValue)
        }
    }
}
