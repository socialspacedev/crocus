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

        // While editing a text field, let keys type normally — but Escape exits
        // the field so the single-key controls work again.
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
            if event.keyCode == 53 {                 // esc
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            }
            return event
        }

        // Ignore modifier chords — those belong to the menus.
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty else { return event }

        switch event.keyCode {
        case 49:  app.playPause();     return nil      // space
        case 124: app.skipSong();      return nil      // →
        case 123: app.previousSong();  return nil      // ←
        case 36:  app.playNextGroup(); return nil      // return
        case 53:  app.stop();          return nil      // esc
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s": app.skipSong();      return nil
        case "p": app.previousSong();  return nil
        case "n": app.playNextGroup(); return nil
        case "f": app.fadeToTalk();    return nil
        case ".": app.stop();          return nil
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
    .init(keys: "P  ·  ←", action: "Previous song (or restart)"),
    .init(keys: "N  ·  ⏎", action: "Play next group"),
    .init(keys: "F", action: "Fade to Talk"),
    .init(keys: ".", action: "Stop"),
    .init(keys: "Esc", action: "Leave a text field / Stop"),
    .init(keys: "⌘N", action: "New show"),
    .init(keys: "⌘O", action: "Import music"),
]
