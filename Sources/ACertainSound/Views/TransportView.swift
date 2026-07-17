import SwiftUI

/// Bottom control bar: transport, fade-to-talk, and the crossfade / voiceover
/// settings. Designed to be driven by single keys during a show.
struct TransportView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var power: PowerManager

    private var ducking: Bool { engine.isDucked || engine.isFadingToTalk }

    var body: some View {
        VStack(spacing: 0) {
            if let err = engine.lastError {
                banner(err, icon: "exclamationmark.triangle.fill")
            }
            if power.isLow {
                banner("Battery low (\(power.batteryPercent ?? 0)%) — plug in before the show drops out",
                       icon: "battery.25")
            }

            HStack(spacing: 18) {
                HStack(spacing: 14) {
                    TransportButton(system: "stop.fill", hint: ".") { app.stop() }
                        .disabled(engine.state == .stopped)

                    TransportButton(system: "backward.fill", hint: "P") { app.previousSong() }
                        .disabled(engine.state == .stopped)

                    Button { app.playPause() } label: {
                        Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 42, height: 42)
                            .background(Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Play / Pause  (Space)")

                    TransportButton(system: "forward.fill", hint: "S") { app.skipSong() }
                        .disabled(engine.state == .stopped)

                    TransportButton(system: "forward.end.fill", hint: "N") { app.playNextGroup() }
                }

                Divider().frame(height: 32).overlay(Theme.hairline)

                Button { app.fadeToTalk() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "mic.fill").font(.system(size: 12))
                        Text(ducking ? "Music Up" : "Fade to Talk")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(ducking ? Theme.background : Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(ducking ? Theme.accent : Theme.surfaceHi, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(engine.state != .playing)
                .help("Duck the music under your voice, hold it there, then press again to bring it back  (F)")

                Spacer()

                HStack(spacing: 16) {
                    matchToggle
                    SettingSlider(label: "Crossfade",
                                  value: $app.show.crossfadeDuration, range: 0...12,
                                  display: app.show.crossfadeDuration == 0 ? "off" : "\(Int(app.show.crossfadeDuration))s") {
                        app.saveShow()
                    }
                    SettingSlider(label: "Duck time",
                                  value: $app.show.duckTime, range: 2...30,
                                  display: "\(Int(app.show.duckTime))s") {
                        app.saveShow()
                    }
                    SettingSlider(label: "Bed level",
                                  value: bedLevelBinding, range: 10...90,
                                  display: "\(Int(app.show.duckLevel * 100))%") {
                        app.saveShow()
                    }
                    SettingSlider(label: "Output",
                                  value: masterBinding, range: 50...200,
                                  display: "\(Int(app.show.masterGain * 100))%") {
                        app.saveShow()
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(Theme.surface)
    }

    private var bedLevelBinding: Binding<Double> {
        Binding(get: { app.show.duckLevel * 100 },
                set: { app.show.duckLevel = $0 / 100 })
    }

    // Master output level — updates the live feed as you drag.
    private var masterBinding: Binding<Double> {
        Binding(get: { app.show.masterGain * 100 },
                set: { app.setMasterGain($0 / 100) })
    }

    private var matchToggle: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel("Match")
            Toggle("", isOn: Binding(
                get: { app.show.normalizeLoudness },
                set: { app.show.normalizeLoudness = $0; app.saveShow() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
                .help("Match song levels across the show (applies from the next song)")
        }
    }

    private func banner(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft)
    }
}

private struct TransportButton: View {
    let system: String
    let hint: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: system)
                    .font(.system(size: 15, weight: .medium))
                Text(hint)
                    .font(Theme.mono(8))
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 40, height: 40)
            .background(hovering ? Theme.surfaceHi : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SettingSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel(label)
                Spacer()
                Text(display).font(Theme.mono(11)).foregroundStyle(Theme.accent)
            }
            Slider(value: $value, in: range, step: 1) { editing in
                if !editing { onCommit() }
            }
            .controlSize(.small)
            .tint(Theme.accent)
        }
        .frame(width: 106)
    }
}
