import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var app: AppState
    @State private var keyMonitor = KeyboardMonitor()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                ShowHeaderView()
                Divider().overlay(Theme.hairline)

                VStack(spacing: 14) {
                    NowPlayingView()
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
                        .onSubmit { app.saveShow() }

                    HStack(spacing: 2) {
                        Text("#").foregroundStyle(Theme.textTertiary)
                        TextField("1", value: $app.show.number, format: .number)
                            .textFieldStyle(.plain)
                            .frame(width: 46)
                            .foregroundStyle(Theme.accent)
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
                            .onSubmit { app.saveShow() }
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
                BatteryView()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
