import SwiftUI

/// Upper-panel waveform for the playing (or focused) song: shows the song's
/// shape and quiet parts, a live position line, and draggable start/end markers
/// for trimming. A single drag gesture spans the whole strip and moves whichever
/// marker you grabbed nearest — so the small markers are never a hit-target.
struct WaveformView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: AudioEngine
    @ObservedObject private var waveforms = WaveformCache.shared

    // Live drag state (committed to the model only on release, to avoid
    // cancelling the gesture by mutating observed state mid-drag).
    @State private var activeMarker: Int? = nil      // 0 = start, 1 = end
    @State private var liveStart: Double? = nil
    @State private var liveEnd: Double? = nil

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
            Image(systemName: "waveform").foregroundStyle(Theme.textTertiary)
            Text("Select a song to see its waveform and drag the ▸ ◂ markers to trim")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func content(ref: TrackRef, track: Track) -> some View {
        let dur = max(0.01, track.duration)
        let curStart = liveStart ?? track.trimStart
        let curEnd = liveEnd ?? (track.trimEnd ?? dur)
        let isPlayingThis = engine.state != .stopped && engine.currentTrack?.id == track.id
        let posTime = track.trimStart + engine.currentElapsed

        return GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            let startX = CGFloat(curStart / dur) * W
            let endX = CGFloat(curEnd / dur) * W
            let posX = CGFloat(min(1, max(0, posTime / dur))) * W

            ZStack(alignment: .topLeading) {
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
                        gc.fill(Path(CGRect(x: x, y: mid - h / 2, width: bw * 0.8, height: h)),
                                with: .color(color))
                    }
                }

                if startX > 0 {
                    Theme.background.opacity(0.55).frame(width: startX, height: H)
                }
                if endX < W {
                    Theme.background.opacity(0.55).frame(width: W - endX, height: H).offset(x: endX)
                }
                if isPlayingThis {
                    Rectangle().fill(Theme.accent).frame(width: 1.5, height: H).offset(x: posX)
                }

                marker(x: startX, height: H, label: "▸", active: activeMarker == 0)
                marker(x: endX, height: H, label: "◂", active: activeMarker == 1)

                VStack {
                    Spacer()
                    HStack {
                        Text(TimeFmt.clock(curStart))
                        Spacer()
                        Text("plays \(TimeFmt.clock(max(0, curEnd - curStart)))")
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(TimeFmt.clock(curEnd))
                    }
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 6).padding(.bottom, 2)
                }
            }
            .coordinateSpace(name: "wave")
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
                    .onChanged { v in
                        if activeMarker == nil {
                            // Grab whichever marker the drag started nearest.
                            activeMarker = abs(v.startLocation.x - startX) <= abs(v.startLocation.x - endX) ? 0 : 1
                        }
                        let t = Double(v.location.x / max(1, W)) * dur
                        if activeMarker == 0 {
                            liveStart = min(max(0, t), (liveEnd ?? curEnd) - 1)
                        } else {
                            liveEnd = min(max((liveStart ?? curStart) + 1, t), dur)
                        }
                    }
                    .onEnded { _ in
                        let s = liveStart ?? track.trimStart
                        let e = liveEnd ?? (track.trimEnd ?? dur)
                        app.updateTrim(groupID: ref.groupID, trackID: ref.trackID,
                                       start: s, end: e >= dur - 0.05 ? nil : e)
                        activeMarker = nil; liveStart = nil; liveEnd = nil
                    }
            )
            .onAppear { waveforms.ensure(track.url) }
            .onChange(of: track.url) { _, newURL in
                waveforms.ensure(newURL)
                activeMarker = nil; liveStart = nil; liveEnd = nil
            }
        }
    }

    private func marker(x: CGFloat, height: CGFloat, label: String, active: Bool) -> some View {
        ZStack {
            Rectangle().fill(Theme.accent).frame(width: active ? 3 : 2, height: height)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.background)
                .frame(width: 16, height: 16)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3))
                .offset(y: -height / 2 + 10)
        }
        .frame(width: 16, height: height)
        .offset(x: x - 8)
        .allowsHitTesting(false)
    }
}
