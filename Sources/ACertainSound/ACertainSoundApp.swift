import SwiftUI

@main
struct ACertainSoundApp: App {
    @StateObject private var app = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.engine)
                .environmentObject(app.power)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Show") { app.newShow() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Import Music…") { app.requestImport() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Previous Shows…") { app.showArchive = true }
                Menu("Export") {
                    Button("Copy as Spreadsheet Rows") { app.copySpreadsheet() }
                    Button("Export Markdown…") { app.exportMarkdown() }
                    Button("Export CSV…") { app.exportCSV() }
                }
                Divider()
                Button("Clear Library…") { app.clearLibrary() }
                Button("Clean Unused Media…") { app.cleanUnusedMedia() }
            }

            // Playback menu — clickable mirrors of the single-key controls. No key
            // equivalents here; the keyboard monitor owns the keys so they don't
            // fire while you're typing in a text field.
            CommandMenu("Playback") {
                Button(app.engine.state == .playing ? "Pause" : "Play") { app.playPause() }
                Button("Previous Song") { app.previousSong() }
                Button("Skip Song") { app.skipSong() }
                Button("Play Next Group") { app.playNextGroup() }
                Divider()
                Button("Fade to Talk / Music Up") { app.fadeToTalk() }
                Button("Stop") { app.stop() }
            }

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { app.showShortcuts = true }
            }
        }
    }
}
