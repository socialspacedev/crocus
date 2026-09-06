import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Combine

/// Reports battery level and, for as long as Crocus is open, holds the display
/// awake so the screensaver / lock screen never interrupts a broadcast.
///
/// Two mechanisms, because one isn't enough. The power assertion stops the
/// *display* idling off, but the screen saver runs on its own idle timer and can
/// still engage on top of a display that was never allowed to sleep — and once it
/// does, "require password after screen saver begins" locks the machine. So we
/// also declare user activity on a repeating timer, which pushes that idle timer
/// back the same way a keypress would.
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
    /// Reused across calls so each declaration re-arms the same assertion rather
    /// than piling up a new one every tick.
    private var userActivityID: IOPMAssertionID = 0

    /// Re-declare activity comfortably inside the shortest screen-saver idle
    /// setting macOS offers (1 minute).
    private static let keepAwakeInterval: TimeInterval = 30

    init() {
        refresh()
        let t = Timer(timeInterval: Self.keepAwakeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.declareUserActivity()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Hold the display awake, or release the hold. Held for as long as Crocus is
    /// open — the music stopping at the end of a group is exactly when the host is
    /// mid-back-announce and touching nothing, so tying this to playback would
    /// drop the hold at the worst possible moment.
    func setKeepAwake(_ on: Bool) {
        if on, !assertionActive {
            var id: IOPMAssertionID = 0
            let reason = "Crocus is running a show" as CFString
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason, &id)
            if result == kIOReturnSuccess {
                assertionID = id
                assertionActive = true
                declareUserActivity()
            }
        } else if !on, assertionActive {
            IOPMAssertionRelease(assertionID)
            assertionActive = false
            assertionID = 0
        }
    }

    /// Tell macOS the user is active, resetting the screen-saver / lock idle
    /// timer that the display-sleep assertion alone doesn't cover.
    private func declareUserActivity() {
        guard assertionActive else { return }
        IOPMAssertionDeclareUserActivity("Crocus is running a show" as CFString,
                                         kIOPMUserActiveLocal,
                                         &userActivityID)
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
