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

                HStack(alignment: .top, spacing: 16) {
                    matchToggle
                    ConsoleFader(label: "Crossfade",
                                 display: app.show.crossfadeDuration == 0 ? "off" : "\(Int(app.show.crossfadeDuration))s",
                                 value: $app.show.crossfadeDuration, range: 0...12,
                                 help: "How long one song fades into the next inside a group. Applies from the next song.") {
                        app.saveShow()
                    }
                    ConsoleFader(label: "Duck time",
                                 display: "\(Int(app.show.duckTime))s",
                                 value: $app.show.duckTime, range: 2...30,
                                 help: "How long Fade to Talk takes to bring the music down to the bed level.") {
                        app.saveShow()
                    }
                    ConsoleFader(label: "Bed level",
                                 display: "\(Int(app.show.duckLevel * 100))%",
                                 value: bedLevelBinding, range: 10...90,
                                 help: "How loud the music sits underneath your voice once it has ducked.") {
                        app.saveShow()
                    }
                    ConsoleFader(label: "Output",
                                 display: "\(Int(min(1, app.show.masterGain) * 100))%",
                                 value: masterBinding, range: 10...100,
                                 help: "Output level, with the live signal metered in the track. The level rises until it meets the fader, so the control marks the ceiling — amber and red just short of it mean a hot song.",
                                 meter: MeterReading(level: engine.meterLevel, peak: engine.meterPeak)) {
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
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Levels")
            Button {
                app.show.normalizeLoudness.toggle()
                app.saveShow()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: app.show.normalizeLoudness ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                    Text(app.show.normalizeLoudness ? "Matched" : "Match off")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(app.show.normalizeLoudness ? Theme.background : Theme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(app.show.normalizeLoudness ? Theme.accent : Theme.surfaceHi, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Match levels: play every song at the same loudness — quiet songs boosted, loud songs eased down, never clipping. Applies from the next song. (Output level works either way.)")
        }
        .frame(width: 92)
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

/// A live meter reading for a fader that carries signal.
private struct MeterReading {
    let level: Float
    let peak: Float
}

/// The console's one fader. Every setting in the transport bar uses it, so the
/// bar reads as a single instrument rather than a row of system sliders: a dark
/// groove that runs from the left edge up to the cap, and the cap itself.
///
/// Output additionally lights that groove with the live signal — the fader
/// position *is* the meter's ceiling, so the level rises until it bumps against
/// the control. Pull the fader down and the meter shortens with it, which is
/// exactly what's happening to the signal.
private struct ConsoleFader: View {
    let label: String
    let display: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let help: String
    var meter: MeterReading? = nil
    let onCommit: () -> Void

    /// The value the cap was grabbed at. Outer nil = this gesture hasn't been
    /// classified yet; inner nil = it started off the cap, so ignore it.
    @State private var grabbedFrom: Double?? = nil

    private static let trackHeight: CGFloat = 13
    private static let capWidth: CGFloat = 5

    private static let zones = LinearGradient(
        stops: [.init(color: Theme.accent, location: 0),
                .init(color: Theme.accent, location: 0.80),
                .init(color: Theme.warning, location: 0.91),
                .init(color: Theme.alert, location: 1)],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel(label)
                Spacer()
                Text(display).font(Theme.mono(11)).foregroundStyle(Theme.accent)
            }
            fader
        }
        .frame(width: 106)
        .help(help)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(display)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: 1)
            case .decrement: adjust(by: -1)
            @unknown default: break
            }
        }
    }

    private func adjust(by step: Double) {
        value = min(range.upperBound, max(range.lowerBound, (value + step).rounded()))
        onCommit()
    }

    private var fader: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )

                // The groove runs from the left edge up to the cap.
                let capX = CGFloat(fraction) * (w - Self.capWidth) + Self.capWidth / 2
                groove(width: max(0, capX - 3))
                    .padding(.leading, 3)

                // Tick marks, on the faders that aren't carrying signal — the
                // Output groove stays clear so the meter reads cleanly.
                if meter == nil {
                    ticks(usable: w - Self.capWidth)
                }

                // Fader cap — rides over the groove, never hidden by it.
                Capsule()
                    .fill(Theme.textPrimary)
                    .frame(width: Self.capWidth, height: Self.trackHeight + 6)
                    .shadow(color: Theme.background.opacity(0.9), radius: 2)
                    .offset(x: CGFloat(fraction) * (w - Self.capWidth))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let usable = max(1, w - Self.capWidth)

                        // You have to grab the cap — a stray click on the track
                        // does nothing. Mid-show, a fader that jumped to wherever
                        // you happened to click would be a hazard.
                        if grabbedFrom == nil {
                            let capX = CGFloat(fraction) * usable + Self.capWidth / 2
                            guard abs(g.startLocation.x - capX) <= 14 else {
                                grabbedFrom = .some(nil)
                                return
                            }
                            grabbedFrom = .some(value)
                        }
                        guard let start = grabbedFrom ?? nil else { return }

                        // Move relative to where it was grabbed, so the cap never
                        // jumps out from under the pointer.
                        let span = range.upperBound - range.lowerBound
                        let delta = Double(g.translation.width / usable) * span
                        value = min(range.upperBound, max(range.lowerBound, (start + delta).rounded()))
                    }
                    .onEnded { _ in
                        if (grabbedFrom ?? nil) != nil { onCommit() }
                        grabbedFrom = nil
                    }
            )
        }
        .frame(height: Self.trackHeight)
    }

    /// Faint marks along the track, aligned to the positions the cap can take.
    /// Spaced by a whole number of steps that divides the range evenly and still
    /// leaves the marks legible — so Duck Time gets a mark every 2s rather than
    /// the 29 the system slider used to draw.
    private func ticks(usable: CGFloat) -> some View {
        let span = range.upperBound - range.lowerBound
        let maxIntervals = max(3, Int(usable / 7))
        var intervals = min(Int(span), maxIntervals)
        while intervals > 3 && Int(span) % intervals != 0 { intervals -= 1 }

        return ZStack(alignment: .leading) {
            ForEach(0...intervals, id: \.self) { i in
                Rectangle()
                    .fill(Theme.textTertiary.opacity(0.45))
                    .frame(width: 1, height: 5)
                    .offset(x: CGFloat(Double(i) / Double(intervals)) * usable
                             + Self.capWidth / 2 - 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func groove(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.surfaceHi)

            if let meter {
                // Full-width gradient masked to the level, so a given loudness
                // always lands on the same colour.
                Capsule()
                    .fill(Self.zones)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: CGFloat(max(0, min(1, meter.level))) * width)
                    }

                if meter.peak > 0.02 {
                    Capsule()
                        .fill(meter.peak > 0.86 ? Theme.alert : Theme.textPrimary.opacity(0.7))
                        .frame(width: 1.5)
                        .offset(x: min(width - 1.5, CGFloat(meter.peak) * width))
                }
            }
        }
        .frame(width: width, height: 6)
    }
}
