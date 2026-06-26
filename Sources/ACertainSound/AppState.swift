import Foundation
import AVFoundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// Top-level app model: the imported library, the current show rundown, and the
/// bridge to the audio engine. A single shared instance keeps menu commands and
/// views in sync.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var library: [Track] = []
    @Published var show = Show()
    @Published var selectedGroupID: SongGroup.ID?
    /// Toggled by the "Import Music…" menu command; the view presents the picker.
    @Published var showImporter = false
    /// Sheets.
    @Published var showArchive = false
    @Published var showShortcuts = false
    /// Which track the waveform panel edits when nothing is playing.
    @Published var focusedRef: TrackRef? = nil

    let engine = AudioEngine()
    let power = PowerManager()

    private let supportDir: URL
    private let showURL: URL
    private let libraryURL: URL
    private let showsDir: URL
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crocus", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        supportDir = base
        showURL = base.appendingPathComponent("show.json")
        libraryURL = base.appendingPathComponent("library.json")
        showsDir = base.appendingPathComponent("Shows", isDirectory: true)
        try? FileManager.default.createDirectory(at: showsDir, withIntermediateDirectories: true)
        Self.migrateLegacyData(into: base)
        load()

        // Hold the display awake whenever a show is playing.
        engine.$state
            .sink { [weak self] st in self?.power.setKeepAwake(st == .playing) }
            .store(in: &cancellables)
    }

    // MARK: - Derived

    var selectedGroup: SongGroup? {
        guard let id = selectedGroupID else { return nil }
        return show.groups.first { $0.id == id }
    }

    // MARK: - Transport (wired to hotkeys/commands)

    func playPause() {
        resignTextFocus()   // so subsequent single-key shortcuts work
        if engine.state == .stopped {
            playSelectedGroup()
        } else {
            engine.togglePlayPause()
        }
    }

    func playSelectedGroup() {
        guard let g = selectedGroup, !g.tracks.isEmpty else { return }
        engine.playGroup(g.tracks,
                         crossfade: show.crossfadeDuration,
                         fadeToTalk: show.duckTime,
                         duckLevel: Float(show.duckLevel))
    }

    func playGroup(_ group: SongGroup) {
        selectedGroupID = group.id
        playSelectedGroup()
    }

    func playNextGroup() {
        guard let current = selectedGroupID,
              let i = show.groups.firstIndex(where: { $0.id == current }) else {
            if let first = show.groups.first { playGroup(first) }
            return
        }
        let next = i + 1
        if next < show.groups.count { playGroup(show.groups[next]) }
    }

    func stop() { engine.stop() }
    func skipSong() { engine.skipSong() }
    func fadeToTalk() { engine.startFadeToTalk() }
    func requestImport() { showImporter = true }

    /// Release any focused text field so single-key shortcuts work again.
    func resignTextFocus() { NSApp.keyWindow?.makeFirstResponder(nil) }

    // MARK: - Library

    /// Import a mix of files and/or folders (folders are scanned recursively).
    func importItems(_ urls: [URL]) {
        var collected: [URL] = []
        for url in urls {
            _ = url.startAccessingSecurityScopedResource()
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                collected.append(contentsOf: audioFiles(in: url))
            } else if isAudio(url) {
                collected.append(url)
            }
        }
        let existing = Set(library.map { $0.url.standardizedFileURL })
        let newURLs = collected.filter { !existing.contains($0.standardizedFileURL) }
        let newTracks = newURLs.map { makeTrack(from: $0) }
        guard !newTracks.isEmpty else { return }
        library.append(contentsOf: newTracks)
        saveLibrary()
        enrichMetadata(for: newTracks)
        for t in newTracks { ArtworkCache.shared.ensure(t.url) }
    }

    func removeFromLibrary(_ track: Track) {
        library.removeAll { $0.id == track.id }
        saveLibrary()
    }

    /// Reorder the library by dropping one song before another.
    func reorderLibrary(_ payload: DragPayload, before targetID: Track.ID) {
        guard payload.fromGroupID == nil, payload.trackID != targetID,
              let from = library.firstIndex(where: { $0.id == payload.trackID }) else { return }
        let moved = library.remove(at: from)
        if let to = library.firstIndex(where: { $0.id == targetID }) {
            library.insert(moved, at: to)
        } else {
            library.append(moved)
        }
        saveLibrary()
    }

    private func audioFiles(in folder: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let f as URL in en where isAudio(f) { out.append(f) }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isAudio(_ url: URL) -> Bool {
        let exts: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "alac", "caf"]
        return exts.contains(url.pathExtension.lowercased())
    }

    /// Build a Track quickly (duration from the audio file; title from filename).
    /// Real metadata is filled in afterward by `enrichMetadata`.
    private func makeTrack(from url: URL) -> Track {
        var duration: TimeInterval = 0
        if let file = try? AVAudioFile(forReading: url) {
            let fmt = file.processingFormat
            if fmt.sampleRate > 0 { duration = Double(file.length) / fmt.sampleRate }
        }
        let name = url.deletingPathExtension().lastPathComponent
        return Track(url: url, title: name, artist: "", duration: duration)
    }

    /// Asynchronously read embedded title/artist/album/year tags into the library.
    private func enrichMetadata(for tracks: [Track]) {
        for track in tracks {
            let url = track.url
            let id = track.id
            Task.detached {
                let asset = AVURLAsset(url: url)
                var title: String?
                var artist: String?
                var album: String?
                var year: Int?
                if let items = try? await asset.load(.commonMetadata) {
                    for item in items {
                        guard let key = item.commonKey else { continue }
                        let value = try? await item.load(.stringValue)
                        switch key {
                        case .commonKeyTitle:     if let v = value, !v.isEmpty { title = v }
                        case .commonKeyArtist:    if let v = value, !v.isEmpty { artist = v }
                        case .commonKeyAlbumName: if let v = value, !v.isEmpty { album = v }
                        case .commonKeyCreationDate:
                            if let v = value, let y = Self.extractYear(v) { year = y }
                        default: break
                        }
                    }
                }
                let fTitle = title, fArtist = artist, fAlbum = album, fYear = year
                await MainActor.run {
                    AppState.shared.applyMetadata(id: id, title: fTitle, artist: fArtist,
                                                  album: fAlbum, year: fYear)
                }
            }
        }
    }

    /// Pull a 4-digit year out of a metadata date string like "2012-05-01".
    private nonisolated static func extractYear(_ s: String) -> Int? {
        let digits = s.prefix(while: { $0 != "-" && $0 != "/" })
        if digits.count == 4, let y = Int(digits) { return y }
        // Fallback: first run of 4 consecutive digits.
        let chars = Array(s)
        for i in 0...(max(0, chars.count - 4)) where i + 4 <= chars.count {
            let sub = String(chars[i..<i+4])
            if sub.allSatisfy({ $0.isNumber }), let y = Int(sub), y > 1900, y < 2200 { return y }
        }
        return nil
    }

    private func applyMetadata(id: Track.ID, title: String?, artist: String?,
                               album: String?, year: Int?) {
        var changed = false
        if let i = library.firstIndex(where: { $0.id == id }) {
            if let t = title { library[i].title = t; changed = true }
            if let a = artist { library[i].artist = a; changed = true }
            if let al = album { library[i].album = al; changed = true }
            if let y = year { library[i].year = y; changed = true }
        }
        if changed { saveLibrary() }
    }

    // MARK: - Rundown editing

    func newGroup() {
        let g = SongGroup(name: "Group \(show.groups.count + 1)")
        show.groups.append(g)
        selectedGroupID = g.id
        saveShow()
    }

    func deleteGroup(_ group: SongGroup) {
        show.groups.removeAll { $0.id == group.id }
        if selectedGroupID == group.id { selectedGroupID = show.groups.first?.id }
        saveShow()
    }

    func addToGroup(_ track: Track, groupID: SongGroup.ID) {
        guard let i = show.groups.firstIndex(where: { $0.id == groupID }) else { return }
        show.groups[i].tracks.append(track)
        saveShow()
    }

    /// Add to the selected group, creating one if needed.
    func addToCurrentGroup(_ track: Track) {
        if selectedGroupID == nil { newGroup() }
        if let id = selectedGroupID { addToGroup(track, groupID: id) }
    }

    func removeTrack(at offsets: IndexSet, fromGroup groupID: SongGroup.ID) {
        guard let i = show.groups.firstIndex(where: { $0.id == groupID }) else { return }
        show.groups[i].tracks.remove(atOffsets: offsets)
        saveShow()
    }

    func moveTrack(from offsets: IndexSet, to dest: Int, inGroup groupID: SongGroup.ID) {
        guard let i = show.groups.firstIndex(where: { $0.id == groupID }) else { return }
        show.groups[i].tracks.move(fromOffsets: offsets, toOffset: dest)
        saveShow()
    }

    func updateTrim(groupID: SongGroup.ID, trackID: Track.ID,
                    start: TimeInterval, end: TimeInterval?) {
        guard let gi = show.groups.firstIndex(where: { $0.id == groupID }),
              let ti = show.groups[gi].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        show.groups[gi].tracks[ti].trimStart = max(0, start)
        show.groups[gi].tracks[ti].trimEnd = end
        saveShow()
    }

    func updateNote(groupID: SongGroup.ID, trackID: Track.ID, note: String) {
        guard let gi = show.groups.firstIndex(where: { $0.id == groupID }),
              let ti = show.groups[gi].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        show.groups[gi].tracks[ti].note = note
        saveShow()
    }

    func track(for ref: TrackRef) -> Track? {
        show.groups.first { $0.id == ref.groupID }?.tracks.first { $0.id == ref.trackID }
    }

    func focus(_ ref: TrackRef) { focusedRef = ref }

    /// The track whose waveform the upper panel should show: the playing one if
    /// any, else the user's focused selection.
    var waveformContext: (ref: TrackRef, track: Track)? {
        if engine.state != .stopped, let cur = engine.currentTrack, let gid = selectedGroupID {
            return (TrackRef(groupID: gid, trackID: cur.id), cur)
        }
        if let ref = focusedRef, let t = track(for: ref) { return (ref, t) }
        return nil
    }

    // MARK: - Drag & drop

    /// Move/insert a dragged track into a group at a position. Library drags
    /// create an independent copy (so a song can appear more than once).
    func handleDrop(_ payload: DragPayload, intoGroup groupID: SongGroup.ID, at index: Int?) {
        var dragged: Track
        if let from = payload.fromGroupID {
            guard let si = show.groups.firstIndex(where: { $0.id == from }),
                  let ti = show.groups[si].tracks.firstIndex(where: { $0.id == payload.trackID })
            else { return }
            dragged = show.groups[si].tracks.remove(at: ti)
        } else {
            guard let lib = library.first(where: { $0.id == payload.trackID }) else { return }
            dragged = lib
            dragged.id = UUID()
        }
        guard let di = show.groups.firstIndex(where: { $0.id == groupID }) else { return }
        let count = show.groups[di].tracks.count
        let insertAt = min(max(0, index ?? count), count)
        show.groups[di].tracks.insert(dragged, at: insertAt)
        saveShow()
    }

    // MARK: - Archive of previous shows

    struct ShowSummary: Identifiable {
        let id: UUID
        let name: String
        let number: Int
        let date: Date
        let theme: String
        let trackCount: Int
        let url: URL
    }

    func listShows() -> [ShowSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: showsDir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var out: [ShowSummary] = []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let s = try? dec.decode(Show.self, from: d) else { continue }
            out.append(.init(id: s.id, name: s.name, number: s.number, date: s.date,
                             theme: s.theme,
                             trackCount: s.groups.reduce(0) { $0 + $1.tracks.count }, url: f))
        }
        return out.sorted { $0.date > $1.date }
    }

    func loadShow(_ summary: ShowSummary) {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: summary.url),
              let s = try? dec.decode(Show.self, from: d) else { return }
        engine.stop()
        show = s
        selectedGroupID = s.groups.first?.id
        focusedRef = nil
        saveShow()
    }

    // MARK: - Export

    func copySpreadsheet() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Exporter.tsv(show), forType: .string)
    }

    func exportMarkdown() {
        save(text: Exporter.markdown(show), suggested: Exporter.slug(show) + ".md", type: "md")
    }

    func exportCSV() {
        save(text: Exporter.csv(show), suggested: Exporter.slug(show) + ".csv", type: "csv")
    }

    private func save(text: String, suggested: String, type: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    // MARK: - Legacy migration (old "A Certain Sound" support folder → "Crocus")

    private static func migrateLegacyData(into base: URL) {
        let fm = FileManager.default
        let crocusShow = base.appendingPathComponent("show.json")
        guard !fm.fileExists(atPath: crocusShow.path) else { return }   // already have data
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("A Certain Sound", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }
        for name in ["show.json", "library.json"] {
            let src = legacy.appendingPathComponent(name)
            let dst = base.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }

    // MARK: - Show lifecycle

    func newShow() {
        let nextNumber = show.number + 1
        engine.stop()
        show = Show(name: show.name, number: nextNumber, date: Date())
        selectedGroupID = nil
        saveShow()
    }

    // MARK: - Persistence

    func saveShow() {
        write(show, to: showURL)
        // Keep an archived copy per show id so previous shows are browsable.
        write(show, to: showsDir.appendingPathComponent("\(show.id.uuidString).json"))
    }

    func saveLibrary() {
        write(library, to: libraryURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(value) { try? data.write(to: url, options: .atomic) }
    }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: libraryURL),
           let lib = try? dec.decode([Track].self, from: data) {
            library = lib.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
        if let data = try? Data(contentsOf: showURL),
           let s = try? dec.decode(Show.self, from: data) {
            show = s
            selectedGroupID = s.groups.first?.id
        }
    }
}
