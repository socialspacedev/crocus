import SwiftUI

/// Compact battery readout; turns accent-coloured when low (and on battery).
struct BatteryView: View {
    @EnvironmentObject var power: PowerManager

    var body: some View {
        if power.hasBattery, let p = power.batteryPercent {
            HStack(spacing: 5) {
                Image(systemName: symbol(p, charging: power.isCharging))
                    .font(.system(size: 13))
                Text("\(p)%")
                    .font(Theme.mono(12, .medium))
                if power.isLow {
                    Text("· plug in")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(power.isLow ? Theme.accent : Theme.textSecondary)
            .help(power.isLow ? "Battery low — plug in before the show drops out"
                              : "Battery \(p)%")
        }
    }

    private func symbol(_ p: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch p {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }
}
