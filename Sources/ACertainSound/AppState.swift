import Foundation
import AVFoundation
import SwiftUI
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

    let engine = AudioEngine()

    private let supportDir: URL
    private let showURL: URL
    private let libraryURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("A Certain Sound", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        supportDir = base
        showURL = base.appendingPathComponent("show.json")
        libraryURL = base.appendingPathComponent("library.json")
        load()
    }

    // MARK: - Derived

    var selectedGroup: SongGroup? {
        guard let id = selectedGroupID else { return nil }
        return show.groups.first { $0.id == id }
    }

    // MARK: - Transport (wired to hotkeys/commands)

    func playPause() {
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
                         fadeToTalk: show.fadeToTalkDuration)
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
    }

    func removeFromLibrary(_ track: Track) {
        library.removeAll { $0.id == track.id }
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

    /// Asynchronously read embedded title/artist tags and update the library.
    private func enrichMetadata(for tracks: [Track]) {
        for track in tracks {
            let url = track.url
            let id = track.id
            Task.detached {
                let asset = AVURLAsset(url: url)
                var title: String?
                var artist: String?
                if let items = try? await asset.load(.commonMetadata) {
                    for item in items {
                        guard let key = item.commonKey else { continue }
                        let value = try? await item.load(.stringValue)
                        if key == .commonKeyTitle, let v = value, !v.isEmpty { title = v }
                        if key == .commonKeyArtist, let v = value, !v.isEmpty { artist = v }
                    }
                }
                let finalTitle = title
                let finalArtist = artist
                await MainActor.run {
                    AppState.shared.applyMetadata(id: id, title: finalTitle, artist: finalArtist)
                }
            }
        }
    }

    private func applyMetadata(id: Track.ID, title: String?, artist: String?) {
        var changed = false
        if let i = library.firstIndex(where: { $0.id == id }) {
            if let t = title { library[i].title = t; changed = true }
            if let a = artist { library[i].artist = a; changed = true }
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
