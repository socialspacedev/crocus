import SwiftUI

/// Upper-panel waveform for the playing (or focused) song: shows the song's
/// shape and quiet parts, a live position line, and draggable start/end markers
/// for trimming — no number-typing required.
struct WaveformView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: AudioEngine
    @ObservedObject private var waveforms = WaveformCache.shared

    var body: some View {
        Group {
            if let ctx = app.waveformContext {
                content(ref: ctx.ref, track: ctx.track)
            } else {
                placeholder
            }
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .cardSurface(Theme.surface)
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(Theme.textTertiary)
            Text("Select a song to see its waveform and set trim points")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func content(ref: TrackRef, track: Track) -> some View {
        let dur = max(0.01, track.duration)
        let endVal = track.trimEnd ?? dur
        let isPlayingThis = engine.state != .stopped && engine.currentTrack?.id == track.id
        let posTime = track.trimStart + engine.currentElapsed

        return GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            let startX = CGFloat(track.trimStart / dur) * W
            let endX = CGFloat(endVal / dur) * W
            let posX = CGFloat(min(1, max(0, posTime / dur))) * W

            ZStack(alignment: .topLeading) {
                // Waveform bars
                Canvas { gc, size in
                    guard let peaks = waveforms.peaks(for: track.url), !peaks.isEmpty else { return }
                    let n = peaks.count
                    let bw = max(0.6, size.width / CGFloat(n))
                    let mid = size.height / 2
                    for i in 0..<n {
                        let x = CGFloat(i) / CGFloat(n) * size.width
                        let h = max(1, CGFloat(peaks[i]) * (size.height - 8))
                        let inTrim = x >= startX && x <= endX
                        let played = isPlayingThis && x <= posX
                        let color: Color = played ? Theme.accent
                            : (inTrim ? Theme.textSecondary : Theme.textTertiary.opacity(0.5))
                        let rect = CGRect(x: x, y: mid - h / 2, width: bw * 0.8, height: h)
                        gc.fill(Path(rect), with: .color(color))
                    }
                }

                // Dim the trimmed-off regions
                if startX > 0 {
                    Theme.background.opacity(0.55).frame(width: startX, height: H)
                }
                if endX < W {
                    Theme.background.opacity(0.55)
                        .frame(width: W - endX, height: H)
                        .offset(x: endX)
                }

                // Position line
                if isPlayingThis {
                    Rectangle().fill(Theme.accent).frame(width: 1.5, height: H).offset(x: posX)
                }

                // Start / end markers
                marker(x: startX, height: H, label: "▸")
                    .gesture(dragStart(ref: ref, track: track, width: W, dur: dur, endVal: endVal))
                marker(x: endX, height: H, label: "◂")
                    .gesture(dragEnd(ref: ref, track: track, width: W, dur: dur))

                // Time readouts
                VStack {
                    Spacer()
                    HStack {
                        Text(TimeFmt.clock(track.trimStart))
                        Spacer()
                        Text("plays \(TimeFmt.clock(track.effectiveDuration))")
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(TimeFmt.clock(endVal))
                    }
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
                }
            }
            .coordinateSpace(name: "wave")
            .onAppear { waveforms.ensure(track.url) }
            .onChange(of: track.url) { _, newURL in waveforms.ensure(newURL) }
        }
    }

    private func marker(x: CGFloat, height: CGFloat, label: String) -> some View {
        ZStack {
            Rectangle().fill(Theme.accent).frame(width: 2, height: height)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 14, height: 14)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3))
                .offset(y: -height / 2 + 9)
        }
        .frame(width: 16, height: height)
        .contentShape(Rectangle())
        .offset(x: x - 8)
    }

    private func dragStart(ref: TrackRef, track: Track, width: CGFloat,
                           dur: Double, endVal: Double) -> some Gesture {
        DragGesture(coordinateSpace: .named("wave")).onChanged { v in
            let t = min(max(0, Double(v.location.x / width) * dur), endVal - 1)
            app.updateTrim(groupID: ref.groupID, trackID: ref.trackID,
                           start: t, end: track.trimEnd)
        }
    }

    private func dragEnd(ref: TrackRef, track: Track, width: CGFloat, dur: Double) -> some Gesture {
        DragGesture(coordinateSpace: .named("wave")).onChanged { v in
            let t = min(max(track.trimStart + 1, Double(v.location.x / width) * dur), dur)
            app.updateTrim(groupID: ref.groupID, trackID: ref.trackID,
                           start: track.trimStart, end: t >= dur - 0.05 ? nil : t)
        }
    }
}
