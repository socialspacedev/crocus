import AppKit

/// Single-key show controls. A local event monitor catches plain keystrokes
/// (no modifier needed) but stays out of the way while you're editing a text
/// field, so typing a show name still works.
@MainActor
final class KeyboardMonitor {
    private var monitor: Any?
    private weak var app: AppState?

    func start(app: AppState) {
        self.app = app
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let app else { return event }

        // Don't steal keys while editing text (the field editor is an NSTextView).
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView { return event }

        // Ignore if a command/option/control chord — those are menu territory.
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty else { return event }

        let key = event.charactersIgnoringModifiers?.lowercased()
        switch event.keyCode {
        case 49: app.playPause(); return nil            // space
        case 124: app.skipSong(); return nil            // →
        case 36: app.playNextGroup(); return nil        // return
        case 53: app.stop(); return nil                 // esc
        default: break
        }
        switch key {
        case "s": app.skipSong(); return nil
        case "n": app.playNextGroup(); return nil
        case "f": app.fadeToTalk(); return nil
        case ".": app.stop(); return nil
        default: return event
        }
    }
}

/// The canonical list, shown in the Help → Keyboard Shortcuts sheet.
struct Shortcut: Identifiable {
    let id = UUID()
    let keys: String
    let action: String
}

let crocusShortcuts: [Shortcut] = [
    .init(keys: "Space", action: "Play / Pause"),
    .init(keys: "S  ·  →", action: "Skip to next song"),
    .init(keys: "N  ·  ⏎", action: "Play next group"),
    .init(keys: "F", action: "Fade to Talk"),
    .init(keys: ".  ·  Esc", action: "Stop"),
    .init(keys: "⌘N", action: "New show"),
    .init(keys: "⌘O", action: "Import music"),
]
