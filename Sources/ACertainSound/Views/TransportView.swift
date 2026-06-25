import SwiftUI

/// Bottom control bar: transport buttons, crossfade + fade-to-talk settings,
/// and quiet hotkey hints. Designed to be operated by keyboard during a show.
struct TransportView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: AudioEngine

    var body: some View {
        VStack(spacing: 0) {
            if let err = engine.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err).lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentSoft)
            }

            HStack(spacing: 18) {
                // Transport cluster
                HStack(spacing: 14) {
                    TransportButton(system: "stop.fill", hint: "⌘.") { app.stop() }
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

                    TransportButton(system: "forward.fill", hint: "⌘→") { app.skipSong() }
                        .disabled(engine.state == .stopped)

                    TransportButton(system: "forward.end.fill", hint: "⌘↩") { app.playNextGroup() }
                }

                Divider().frame(height: 32).overlay(Theme.hairline)

                // Fade to talk
                Button { app.fadeToTalk() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "mic.fill").font(.system(size: 12))
                        Text("Fade to Talk").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(engine.isFadingToTalk ? Theme.background : Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(engine.isFadingToTalk ? Theme.accent : Theme.surfaceHi,
                                in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(engine.state != .playing)
                .help("Slowly fade the current song out so you can talk over it  (⌘⇧F)")

                Spacer()

                // Settings
                HStack(spacing: 22) {
                    SettingSlider(label: "Crossfade",
                                  value: $app.show.crossfadeDuration,
                                  range: 0...12,
                                  display: app.show.crossfadeDuration == 0
                                      ? "off" : "\(Int(app.show.crossfadeDuration))s") {
                        app.saveShow()
                    }
                    SettingSlider(label: "Fade to talk",
                                  value: $app.show.fadeToTalkDuration,
                                  range: 5...90,
                                  display: "\(Int(app.show.fadeToTalkDuration))s") {
                        app.saveShow()
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(Theme.surface)
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
                Text(display)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.accent)
            }
            Slider(value: $value, in: range, step: 1) { editing in
                if !editing { onCommit() }
            }
            .controlSize(.small)
            .tint(Theme.accent)
        }
        .frame(width: 130)
    }
}
