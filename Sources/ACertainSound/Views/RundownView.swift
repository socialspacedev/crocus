import SwiftUI

/// The show's running order: a list of groups, each a short run of songs that
/// crossfade then stop. This is where the host builds and triggers the show.
struct RundownView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Rundown")
                Spacer()
                Text(TimeFmt.clock(app.show.groups.reduce(0) { $0 + $1.totalDuration }))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textTertiary)
                Button { app.newGroup() } label: {
                    Label("Group", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if app.show.groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(app.show.groups) { group in
                            GroupCard(group: group)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(Theme.background)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Theme.textTertiary)
            Text("Build your first group")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("A group is 2–3 songs that play, crossfade, then stop\nso you can back-announce.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textTertiary)
            Button("New Group") { app.newGroup() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GroupCard: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: AudioEngine
    let group: SongGroup

    private var isSelected: Bool { app.selectedGroupID == group.id }
    private var isPlayingThis: Bool {
        engine.state != .stopped && isSelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Button {
                    app.playGroup(group)
                } label: {
                    Image(systemName: isPlayingThis ? "waveform" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isPlayingThis ? Theme.accent : Theme.textPrimary)
                        .frame(width: 26, height: 26)
                        .background(isPlayingThis ? Theme.accentSoft : Theme.surfaceHi,
                                    in: Circle())
                }
                .buttonStyle(.plain)
                .help("Play this group")

                TextField("Group name", text: bindingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Text("\(group.tracks.count) songs · \(TimeFmt.clock(group.totalDuration))")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textTertiary)

                Menu {
                    Button("Delete Group", role: .destructive) { app.deleteGroup(group) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
            }
            .padding(12)

            if !group.tracks.isEmpty {
                Divider().overlay(Theme.hairline)
                VStack(spacing: 0) {
                    ForEach(Array(group.tracks.enumerated()), id: \.element.id) { idx, track in
                        TrackRow(group: group, track: track, position: idx + 1,
                                 isCurrent: isPlayingThis && engine.currentTrack?.id == track.id)
                        if idx < group.tracks.count - 1 {
                            Divider().overlay(Theme.hairline).padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .cardSurface(isSelected ? Theme.surfaceHi : Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { app.selectedGroupID = group.id }
    }

    private var bindingName: Binding<String> {
        Binding(
            get: { group.name },
            set: { newValue in
                if let i = app.show.groups.firstIndex(where: { $0.id == group.id }) {
                    app.show.groups[i].name = newValue
                    app.saveShow()
                }
            }
        )
    }
}

private struct TrackRow: View {
    @EnvironmentObject var app: AppState
    let group: SongGroup
    let track: Track
    let position: Int
    let isCurrent: Bool
    @State private var showTrim = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(Theme.mono(11))
                .foregroundStyle(isCurrent ? Theme.accent : Theme.textTertiary)
                .frame(width: 16, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
                Text(track.artist.isEmpty ? "—" : track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if track.trimStart > 0 || track.trimEnd != nil {
                Image(systemName: "scissors")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent.opacity(0.8))
                    .help("Trimmed")
            }

            Text(TimeFmt.clock(track.effectiveDuration))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textTertiary)

            Button { showTrim.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Trim start / end")
            .popover(isPresented: $showTrim, arrowEdge: .trailing) {
                TrimEditor(group: group, track: track)
            }

            Button {
                if let i = group.tracks.firstIndex(where: { $0.id == track.id }) {
                    app.removeTrack(at: IndexSet(integer: i), fromGroup: group.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove from group")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isCurrent ? Theme.accentSoft : Color.clear)
    }
}

/// Set per-song start / end points to skip long intros or outros.
private struct TrimEditor: View {
    @EnvironmentObject var app: AppState
    let group: SongGroup
    let track: Track

    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var trimEndOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Trim · \(track.title)")

            HStack {
                Text("Start").font(.system(size: 12)).frame(width: 40, alignment: .leading)
                Stepper(value: $start, in: 0...max(0, track.duration - 1), step: 1) {
                    Text(TimeFmt.clock(start)).font(Theme.mono(13))
                }
                .onChange(of: start) { _, _ in commit() }
            }

            Toggle(isOn: $trimEndOn) {
                Text("Custom end").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .onChange(of: trimEndOn) { _, on in
                if on, end <= start { end = track.duration }
                commit()
            }

            if trimEndOn {
                HStack {
                    Text("End").font(.system(size: 12)).frame(width: 40, alignment: .leading)
                    Stepper(value: $end, in: (start + 1)...max(start + 1, track.duration), step: 1) {
                        Text(TimeFmt.clock(end)).font(Theme.mono(13))
                    }
                    .onChange(of: end) { _, _ in commit() }
                }
            }

            Text("Plays \(TimeFmt.clock((trimEndOn ? end : track.duration) - start)) of \(TimeFmt.clock(track.duration))")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
        .frame(width: 260)
        .onAppear {
            start = track.trimStart
            if let e = track.trimEnd { end = e; trimEndOn = true } else { end = track.duration }
        }
    }

    private func commit() {
        app.updateTrim(groupID: group.id, trackID: track.id,
                       start: start, end: trimEndOn ? end : nil)
    }
}
