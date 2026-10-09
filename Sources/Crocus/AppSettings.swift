import Foundation
import Combine

/// Settings that belong to the station and the show rather than to any one
/// episode. They outlive every rundown, and they're the first things somebody
/// else installing Crocus needs to change — which is exactly why they're here
/// and not baked into the source. A `Show` records what was broadcast; these
/// record who is doing the broadcasting.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Name given to new shows. Episodes already saved keep the name they were
    /// saved with — renaming here never rewrites history.
    @Published var showName: String = "My Radio Show"

    /// Station and frequency, as it should read in the website export's
    /// description line. Empty leaves the station out of the sentence entirely,
    /// so this costs nothing if you don't publish episode pages.
    @Published var station: String = ""

    /// Time zone the episode date is stamped in for the website export. Defaults
    /// to wherever this Mac thinks it is.
    @Published var timeZoneID: String = TimeZone.current.identifier

    /// The content schema the Markdown export targets, and the tag it adds.
    /// Only meaningful if you publish episodes to a static site that expects
    /// them; harmless otherwise.
    @Published var schemaKey: String = "radio_show"
    @Published var schemaTag: String = "radio-show"

    private let baseDir: URL
    private let fileURL: URL
    private var cancellables: Set<AnyCancellable> = []

    /// The Markdown export's shape, as a file you can rewrite. See `ExportTemplate`.
    var templateURL: URL { baseDir.appendingPathComponent("export-template.md") }

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crocus", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        baseDir = base
        fileURL = base.appendingPathComponent("settings.json")
        load()

        // `objectWillChange` fires *before* the new value lands, so let the run
        // loop turn once before writing — otherwise every save is one keystroke
        // behind. Same reason the second-screen viewer push is throttled.
        objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
            .store(in: &cancellables)
    }

    /// The export's view of these settings, as a plain value — so a Markdown
    /// export can be produced (and tested) without reaching for live state.
    var exportIdentity: ExportIdentity {
        ExportIdentity(station: station, timeZone: timeZone,
                       schemaKey: schemaKey, schemaTag: schemaTag)
    }

    /// Falls back to this Mac's zone if the stored identifier isn't one macOS
    /// recognises — a hand-edited settings file shouldn't break exporting.
    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneID) ?? .current
    }

    // MARK: - Export template

    /// The Markdown export template, writing the built-in default to disk the
    /// first time it's wanted — so there is always a real file to open and edit
    /// rather than an invisible default to discover.
    func exportTemplate() -> String {
        if let s = try? String(contentsOf: templateURL, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        resetExportTemplate()
        return ExportTemplate.standard
    }

    /// Put the shipped template back, discarding any edits.
    func resetExportTemplate() {
        try? ExportTemplate.standard.write(to: templateURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Persistence
    //
    // Stored separately from the published properties so the file format stays a
    // plain value type, decoded tolerantly: a settings file written by an older
    // (or newer) build loads with whatever it has and defaults the rest, rather
    // than failing and silently reverting everything.

    private struct Stored: Codable {
        var showName: String
        var station: String
        var timeZoneID: String
        var schemaKey: String
        var schemaTag: String

        @MainActor init(_ s: AppSettings) {
            showName = s.showName
            station = s.station
            timeZoneID = s.timeZoneID
            schemaKey = s.schemaKey
            schemaTag = s.schemaTag
        }

        enum CodingKeys: String, CodingKey {
            case showName, station, timeZoneID, schemaKey, schemaTag
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            showName = try c.decodeIfPresent(String.self, forKey: .showName) ?? "My Radio Show"
            station = try c.decodeIfPresent(String.self, forKey: .station) ?? ""
            timeZoneID = try c.decodeIfPresent(String.self, forKey: .timeZoneID) ?? TimeZone.current.identifier
            schemaKey = try c.decodeIfPresent(String.self, forKey: .schemaKey) ?? "radio_show"
            schemaTag = try c.decodeIfPresent(String.self, forKey: .schemaTag) ?? "radio-show"
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        showName = s.showName
        station = s.station
        timeZoneID = s.timeZoneID
        schemaKey = s.schemaKey
        schemaTag = s.schemaTag
    }

    /// Write to disk. Pretty-printed with sorted keys so the file stays readable
    /// and diffable for anyone who'd rather edit it by hand than open the window.
    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(Stored(self)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
