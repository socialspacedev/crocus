import SwiftUI

/// The broadcast centerpiece: artwork, what's playing, what's next, and a large,
/// steady countdown to when the music stops — the host's cue to talk.
struct NowPlayingView: View {
    @EnvironmentObject var engine: AudioEngine
    @ObservedObject private var artwork = ArtworkCache.shared

    private var isLive: Bool { engine.state == .playing }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            artworkView

            // Now playing + up next
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isLive ? Theme.accent : Theme.textTertiary)
                        .frame(width: 7, height: 7)
                    SectionLabel(statusLabel)
                }

                if let t = engine.currentTrack {
                    Text(t.title)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle(t))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if !t.note.isEmpty {
                        Text(t.note)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                    }
                } else {
                    Text("Nothing playing")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text("Select a group and press Space")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }

                if let next = engine.upNextTrack {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                        Text("Up next: \(next.displayArtistTitle)")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                } else if engine.currentTrack != nil {
                    Text("Last in group — music stops after this")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent.opacity(0.9))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Countdown
            VStack(alignment: .trailing, spacing: 6) {
                SectionLabel(countdownLabel)
                Text(TimeFmt.clock(engine.groupRemaining))
                    .font(Theme.mono(60, .light))
                    .foregroundStyle(countdownColor)
                    .opacity(flashOpacity)
                    .contentTransition(.numericText())
                if engine.currentSegmentDuration > 0 {
                    Text("track \(TimeFmt.clock(engine.currentElapsed)) / \(TimeFmt.clock(engine.currentSegmentDuration))")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    @ViewBuilder private var artworkView: some View {
        let img = engine.currentTrack.flatMap { artwork.image(for: $0.url) }
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surfaceHi)
            if let img {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 88, height: 88)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .onAppear { if let t = engine.currentTrack { artwork.ensure(t.url) } }
        .onChange(of: engine.currentTrack?.url) { _, url in if let url { artwork.ensure(url) } }
    }

    private func subtitle(_ t: Track) -> String {
        var parts: [String] = []
        if !t.artist.isEmpty { parts.append(t.artist) }
        if !t.album.isEmpty { parts.append(t.album) }
        if let y = t.year { parts.append(String(y)) }
        return parts.isEmpty ? "—" : parts.joined(separator: "  ·  ")
    }

    private var statusLabel: String {
        if engine.isDucked || engine.isFadingToTalk { return "Talk · music ducked" }
        switch engine.state {
        case .playing: return engine.isCrossfading ? "Crossfading" : "On air"
        case .paused:  return "Paused"
        case .stopped: return "Off air"
        }
    }

    private var countdownLabel: String {
        (engine.isDucked || engine.isFadingToTalk) ? "Bed ends in" : "Music stops in"
    }

    /// The last ten seconds of music — get ready to talk.
    private var inFinalTen: Bool {
        isLive && !engine.isDucked && !engine.isFadingToTalk
            && engine.groupRemaining > 0 && engine.groupRemaining <= 10
    }

    private var countdownColor: Color {
        if engine.isDucked || engine.isFadingToTalk { return Theme.accent }
        if inFinalTen { return Theme.alert }
        return isLive ? Theme.textPrimary : Theme.textTertiary
    }

    /// A slow breathe rather than a blink: one cycle every 1.7s, easing between
    /// full and half brightness instead of snapping. Red already carries the
    /// message — the pulse is only there to catch your eye. Never blanks, so the
    /// number stays readable the whole way down.
    private var flashOpacity: Double {
        guard inFinalTen else { return 1 }
        let phase = engine.groupRemaining.truncatingRemainder(dividingBy: 1.7) / 1.7
        return 0.75 + 0.25 * cos(2 * .pi * phase)
    }
}
