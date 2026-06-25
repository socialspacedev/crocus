import SwiftUI

/// The imported song pool. Pick songs here and add them to groups in the rundown.
struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""

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
        }
        .background(Theme.background)
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
            Spacer(minLength: 4)
            Text(TimeFmt.clock(track.duration))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textTertiary)

            if hovering {
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
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(app.show.groups) { g in
                Button("Add to \(g.name)") { app.addToGroup(track, groupID: g.id) }
            }
            Divider()
            Button("New Group with this Song") {
                app.newGroup()
                app.addToCurrentGroup(track)
            }
            Divider()
            Button("Remove from Library", role: .destructive) {
                app.removeFromLibrary(track)
            }
        }
    }
}
