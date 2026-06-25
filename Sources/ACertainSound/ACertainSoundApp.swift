import SwiftUI

@main
struct ACertainSoundApp: App {
    @StateObject private var app = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.engine)
                .frame(minWidth: 920, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            // Replace the default "New" with "New Show".
            CommandGroup(replacing: .newItem) {
                Button("New Show") { app.newShow() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Import Music…") { app.requestImport() }
                    .keyboardShortcut("o", modifiers: .command)
            }

            // Playback menu — these double as the show hotkeys.
            CommandMenu("Playback") {
                Button(app.engine.state == .playing ? "Pause" : "Play") { app.playPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Skip Song") { app.skipSong() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Play Next Group") { app.playNextGroup() }
                    .keyboardShortcut(.return, modifiers: .command)
                Divider()
                Button("Fade to Talk") { app.fadeToTalk() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Stop") { app.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}
