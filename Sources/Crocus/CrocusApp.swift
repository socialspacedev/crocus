import SwiftUI

@main
struct CrocusApp: App {
    @StateObject private var app = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.engine)
                .environmentObject(app.power)
                // The transport bar is a fixed-width console — five faders, the
                // match toggle and the transport cluster all sit at their natural
                // size — so the window can't go narrower than that row needs
                // without clipping the Output fader off the right-hand edge.
                .frame(minWidth: 1240, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1320, height: 780)

        // Gives Crocus ▸ Settings… on ⌘, for free.
        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }

        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Show") { app.newShow() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Import Music…") { app.requestImport() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Previous Shows…") { app.showArchive = true }
                Menu("Export") {
                    Button("Copy Running Order") { app.copyRunningOrder() }
                    Button("Copy Detailed Notes") { app.copyDetailedNotes() }
                    Divider()
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
                Button("Fade Out Song") { app.fadeOutSong() }
                Button("Stop") { app.stop() }
            }

            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { app.showShortcuts = true }
            }
        }
    }
}
