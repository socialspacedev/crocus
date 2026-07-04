import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var app: AppState
    @State private var keyMonitor = KeyboardMonitor()
    @State private var playDropTargeted = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                ShowHeaderView()
                Divider().overlay(Theme.hairline)

                VStack(spacing: 14) {
                    NowPlayingView()
                        .contentShape(Rectangle())
                        .onTapGesture { app.resignTextFocus() }
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Theme.accent, lineWidth: playDropTargeted ? 2 : 0)
                                .allowsHitTesting(false)
                        )
                        // Drop a song here to play it immediately (mix on the fly).
                        .dropDestination(for: DragPayload.self) { items, _ in
                            if let p = items.first { app.playSingle(p) }
                            return !items.isEmpty
                        } isTargeted: { playDropTargeted = $0 }
                    WaveformView()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)

                Divider().overlay(Theme.hairline)

                HStack(spacing: 0) {
                    LibraryView()
                        .frame(width: 320)
                    Divider().overlay(Theme.hairline)
                    RundownView()
                        .frame(maxWidth: .infinity)
                }

                Divider().overlay(Theme.hairline)
                TransportView()
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .onAppear { keyMonitor.start(app: app) }
        .fileImporter(
            isPresented: $app.showImporter,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { app.importItems(urls) }
        }
        .sheet(isPresented: $app.showArchive) { ShowsArchiveView() }
        .sheet(isPresented: $app.showShortcuts) { ShortcutsView() }
        .sheet(isPresented: Binding(
            get: { app.editingLibraryTrackID != nil },
            set: { if !$0 { app.editingLibraryTrackID = nil } }
        )) {
            if let track = app.editingTrack { MetadataEditorView(track: track) }
        }
    }
}

/// Editable show identity — large and legible: title, number, date, and theme.
struct ShowHeaderView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                // Title + number — large.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TextField("Show name", text: $app.show.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize()
                        .onSubmit { app.saveShow(); app.resignTextFocus() }

                    HStack(spacing: 2) {
                        Text("#").foregroundStyle(Theme.textTertiary)
                        TextField("1", value: $app.show.number, format: .number)
                            .textFieldStyle(.plain)
                            .frame(width: 46)
                            .foregroundStyle(Theme.accent)
                            .onSubmit { app.saveShow(); app.resignTextFocus() }
                    }
                    .font(.system(size: 30, weight: .semibold))
                }

                // Date + theme — medium.
                HStack(spacing: 12) {
                    DatePicker("", selection: $app.show.date, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .font(.system(size: 16))
                        .onChange(of: app.show.date) { _, _ in app.saveShow() }

                    Text("·").foregroundStyle(Theme.textTertiary)

                    HStack(spacing: 6) {
                        Image(systemName: "tag")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                        TextField("Theme (e.g. Instrumentals)", text: $app.show.theme)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: 240)
                            .onSubmit { app.saveShow(); app.resignTextFocus() }
                    }
                }
            }

            Spacer()

            // Action cluster
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 10) {
                    Button { app.showArchive = true } label: {
                        Label("Shows", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)

                    Menu {
                        Button("Copy as Spreadsheet Rows") { app.copySpreadsheet() }
                        Button("Export Markdown…") { app.exportMarkdown() }
                        Button("Export CSV…") { app.exportCSV() }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(Theme.textSecondary)

                    Button { app.newShow() } label: {
                        Label("New Show", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 14) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Text("\(TimeFmt.clock(app.show.totalPlaytime)) total")
                            .font(Theme.mono(12, .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .help("Total show playtime (sum of group playtimes, trimmed)")
                    }
                    BatteryView()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
