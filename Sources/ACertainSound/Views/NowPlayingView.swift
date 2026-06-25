import SwiftUI

/// The broadcast centerpiece: what's playing, what's next, and a large, steady
/// countdown to the moment the music stops — the host's cue to talk.
struct NowPlayingView: View {
    @EnvironmentObject var engine: AudioEngine

    private var isLive: Bool { engine.state == .playing }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            // Left: now playing + up next
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isLive ? Theme.accent : Theme.textTertiary)
                        .frame(width: 7, height: 7)
                        .opacity(isLive ? 1 : 0.5)
                    SectionLabel(statusLabel)
                }

                if let t = engine.currentTrack {
                    Text(t.title)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(t.artist.isEmpty ? "—" : t.artist)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("Nothing playing")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text("Select a group and press Space")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer().frame(height: 4)

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

            // Right: the big countdown
            VStack(alignment: .trailing, spacing: 6) {
                SectionLabel(engine.isFadingToTalk ? "Fading out" : "Music stops in")
                Text(TimeFmt.clock(engine.groupRemaining))
                    .font(Theme.mono(64, .light))
                    .foregroundStyle(countdownColor)
                    .contentTransition(.numericText())

                if engine.currentSegmentDuration > 0 {
                    Text("track \(TimeFmt.clock(engine.currentElapsed)) / \(TimeFmt.clock(engine.currentSegmentDuration))")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var statusLabel: String {
        switch engine.state {
        case .playing: return engine.isCrossfading ? "Crossfading" : "On air"
        case .paused:  return "Paused"
        case .stopped: return "Off air"
        }
    }

    private var countdownColor: Color {
        if engine.isFadingToTalk { return Theme.accent }
        if isLive && engine.groupRemaining <= 10 { return Theme.accent }
        return isLive ? Theme.textPrimary : Theme.textTertiary
    }
}
