import SwiftUI
import UniformTypeIdentifiers

/// The imported song pool. Pick songs here and add them to groups in the rundown.
struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var dropTargeted = false

    private var filtered: [Track] {
        guard !search.isEmpty else { return app.library }
        let q = search.lowercased()
        return app.library.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Library")
                Spacer()
                Text("\(app.library.count)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textTertiary)
                Button { app.requestImport() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)

                Menu {
                    Button("Import Music…") { app.requestImport() }
                    Divider()
                    Button("Clear Library…", role: .destructive) { app.clearLibrary() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Filter", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .cardSurface(Theme.surface)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if app.library.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { track in
                            LibraryRow(track: track)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }

            BackupsShelf()
        }
        .background(Theme.background)
        .overlay(
            Rectangle()
                .strokeBorder(Theme.accent, lineWidth: dropTargeted ? 2 : 0)
                .allowsHitTesting(false)
        )
        // Drag files / folders from Finder, Desktop, etc. straight in.
        .dropDestination(for: URL.self) { urls, _ in
            app.importItems(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Theme.textTertiary)
            Text("No songs yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Button("Import Music…") { app.requestImport() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LibraryRow: View {
    @EnvironmentObject var app: AppState
    let track: Track
    @State private var hovering = false

    /// A song already placed in the current show — kept to one appearance.
    private var inShow: Bool { app.isInShow(track.url) }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(track.artist.isEmpty ? "—" : track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .opacity(inShow ? 0.5 : 1)

            Spacer(minLength: 4)

            Text(TimeFmt.clock(track.duration))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textTertiary)
                .opacity(inShow ? 0.5 : 1)

            if hovering {
                Button {
                    app.editingLibraryTrackID = track.id
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Edit info")
            }

            if inShow {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                    .help("Already in this show")
                    .transition(.scale.combined(with: .opacity))
            } else if hovering {
                Button {
                    app.addToCurrentGroup(track)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Add to current group")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? Theme.surface : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: inShow)
        .onHover { hovering = $0 }
        .draggable(DragPayload(trackID: track.id, fromGroupID: nil))
        .dropDestination(for: DragPayload.self) { items, _ in
            var handled = false
            for p in items where p.fromGroupID == nil && !p.fromBackups {
                app.reorderLibrary(p, before: track.id); handled = true
            }
            return handled
        }
        .contextMenu {
            Button("Edit Info…") { app.editingLibraryTrackID = track.id }
            Divider()
            if inShow {
                Text("Already in this show")
            } else {
                ForEach(app.show.groups) { g in
                    Button("Add to \(g.name)") { app.addToGroup(track, groupID: g.id) }
                }
                Button("New Group with this Song") {
                    app.newGroup()
                    app.addToCurrentGroup(track)
                }
            }
            Button("Add to Backups") { app.addToBackups(DragPayload(trackID: track.id)) }
            Divider()
            Button("Remove from Library", role: .destructive) {
                app.removeFromLibrary(track)
            }
        }
    }
}

/// Spare songs for filling time, kept in the library area (not the rundown, and
/// excluded from the show total). Drag songs in; drag a backup out to the player
/// or a group; or tap to fire it as a one-off.
private struct BackupsShelf: View {
    @EnvironmentObject var app: AppState
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                SectionLabel("Backups")
                Spacer()
                Text("\(app.show.backups.tracks.count)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if app.show.backups.tracks.isEmpty {
                Text("Drag spare songs here for quick filler")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(app.show.backups.tracks) { BackupRow(track: $0) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 132)
            }
        }
        .background(targeted ? Theme.accentSoft : Theme.surface)
        .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: targeted ? 2 : 0)
            .allowsHitTesting(false))
        // One handler for BOTH internal song drags (crocusTrack) and files from
        // Finder (fileURL) — SwiftUI won't honour two typed drop targets on one
        // view, and the library-wide file importer would otherwise swallow files.
        .onDrop(of: [UTType.crocusTrack, UTType.fileURL], isTargeted: $targeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.crocusTrack.identifier) {
                handled = true
                p.loadDataRepresentation(forTypeIdentifier: UTType.crocusTrack.identifier) { data, _ in
                    guard let data,
                          let payload = try? JSONDecoder().decode(DragPayload.self, from: data) else { return }
                    Task { @MainActor in app.addToBackups(payload) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in app.importToBackups([url]) }
                }
            }
        }
        return handled
    }
}

private struct BackupRow: View {
    @EnvironmentObject var app: AppState
    let track: Track
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button { app.playBackup(track) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 18, height: 18)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Play now (one-off)")

            Text(track.title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if hovering {
                Button { app.removeBackup(track) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Remove from Backups")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Theme.surfaceHi : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Drag a backup into a group or onto the now-playing area.
        .draggable(DragPayload(trackID: track.id, fromBackups: true))
    }
}
