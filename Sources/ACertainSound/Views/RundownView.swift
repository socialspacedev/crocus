import SwiftUI

/// The show's running order: numbered groups, each a short run of songs that
/// crossfade then stop. Drag to reorder or to add songs from the library.
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
                ScrollViewReader { proxy in
                    ScrollView {
                        // Cards are separated by drop-gaps that accept a dragged group
                        // and insert it at that slot. The gaps are the reorder drop
                        // targets (kept separate from the draggable cards, which can't
                        // reliably also be drop targets of the same type).
                        VStack(spacing: 0) {
                            ForEach(Array(app.show.groups.enumerated()), id: \.element.id) { idx, group in
                                GroupDropGap(insertIndex: idx)
                                GroupCard(group: group, number: idx + 1)
                                    .id(group.id)
                            }
                            GroupDropGap(insertIndex: app.show.groups.count)
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 16)
                    }
                    // Follow playback: keep the current/next group in view as the
                    // show advances (and when you select a group by hand).
                    .onChange(of: app.selectedGroupID) { _, newID in
                        guard let id = newID else { return }
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
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

/// A thin slot between group cards that accepts a dragged group and inserts it
/// here. Provides the visual spacing between cards, and shows an accent line
/// when a group is hovering over it.
private struct GroupDropGap: View {
    @EnvironmentObject var app: AppState
    let insertIndex: Int
    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(targeted ? Theme.accent : Color.clear)
            .frame(height: targeted ? 3 : 2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .dropDestination(for: GroupDragPayload.self) { items, _ in
                guard let p = items.first else { return false }
                app.moveGroup(p.groupID, toIndex: insertIndex)
                return true
            } isTargeted: { targeted = $0 }
            .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

private struct GroupCard: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: AudioEngine
    let group: SongGroup
    let number: Int

    @State private var dropTargeted = false
    @State private var pulse = false

    private var isSelected: Bool { app.selectedGroupID == group.id }
    private var isPlayingThis: Bool { engine.state != .stopped && isSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .help("Drag the card to reorder this group")

                Button { app.playGroup(group) } label: {
                    Image(systemName: isPlayingThis ? "waveform" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isPlayingThis ? Theme.accent : Theme.textPrimary)
                        .frame(width: 26, height: 26)
                        .background(isPlayingThis ? Theme.accentSoft : Theme.surfaceHi, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Play this group")

                Text("Group \(number)")
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

            if group.tracks.isEmpty {
                Text("Drag songs here")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 14)
            } else {
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
                .strokeBorder(highlighted ? Theme.accent
                              : (isSelected ? Theme.accent.opacity(0.5) : Color.clear),
                              lineWidth: highlighted ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { app.resignTextFocus(); app.selectedGroupID = group.id }
        // The card itself is the group's drag handle (the grip is the visual cue).
        // Draggable + tap on the same view is the pattern that works for song rows;
        // song rows stay draggable because the innermost draggable wins.
        .draggable(GroupDragPayload(groupID: group.id))
        // Songs dropped onto the card join the group. (Group-reorder drops are
        // handled one level up, in GroupRow.)
        .dropDestination(for: DragPayload.self) { items, _ in
            for p in items { app.handleDrop(p, intoGroup: group.id, at: nil) }
            return !items.isEmpty
        } isTargeted: { dropTargeted = $0 }
        // Brief accent pulse when this group gains a song (add confirmation).
        .onChange(of: group.tracks.count) { old, new in
            guard new > old else { return }
            withAnimation(.easeOut(duration: 0.2)) { pulse = true }
            Task {
                try? await Task.sleep(nanoseconds: 550_000_000)
                withAnimation(.easeOut(duration: 0.35)) { pulse = false }
            }
        }
    }

    private var highlighted: Bool { dropTargeted || pulse }
}

private struct TrackRow: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var artwork = ArtworkCache.shared
    let group: SongGroup
    let track: Track
    let position: Int
    let isCurrent: Bool
    @State private var showNote = false

    private var isFocused: Bool {
        app.focusedRef == TrackRef(groupID: group.id, trackID: track.id)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(Theme.mono(11))
                .foregroundStyle(isCurrent ? Theme.accent : Theme.textTertiary)
                .frame(width: 14, alignment: .trailing)

            artworkThumb

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
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

            Button { showNote.toggle() } label: {
                Image(systemName: track.note.isEmpty ? "text.bubble" : "text.bubble.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(track.note.isEmpty ? Theme.textTertiary : Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Note (shows on the website export)")
            .popover(isPresented: $showNote, arrowEdge: .trailing) {
                NoteEditor(group: group, track: track)
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
        .background(isCurrent ? Theme.accentSoft : (isFocused ? Theme.surfaceHi.opacity(0.6) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            app.resignTextFocus()
            app.selectedGroupID = group.id
            app.focus(TrackRef(groupID: group.id, trackID: track.id))
        }
        .draggable(DragPayload(trackID: track.id, fromGroupID: group.id))
        .dropDestination(for: DragPayload.self) { items, _ in
            for p in items { app.handleDrop(p, intoGroup: group.id, at: position - 1) }
            return !items.isEmpty
        }
    }

    @ViewBuilder private var artworkThumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.surfaceHi)
            if let img = artwork.image(for: track.url) {
                Image(nsImage: img).resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 26, height: 26)
        .onAppear { artwork.ensure(track.url) }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if let y = track.year { parts.append(String(y)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// Per-song note — feeds the website's `tracks[].note` and the exports.
private struct NoteEditor: View {
    @EnvironmentObject var app: AppState
    let group: SongGroup
    let track: Track
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Note · \(track.title)")
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(width: 280, height: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .cardSurface(Theme.surface)
                .onChange(of: text) { _, new in
                    app.updateNote(groupID: group.id, trackID: track.id, note: new)
                }
            Text("e.g. “Recorded in one take at Abbey Road, 1969.”")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(14)
        .onAppear { text = track.note }
    }
}
