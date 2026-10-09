import Foundation
import AVFoundation
import SwiftUI
import AppKit
import Combine
import CryptoKit
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
    /// The library track currently open in the metadata editor sheet (nil = closed).
    @Published var editingLibraryTrackID: Track.ID? = nil
    /// Which track the waveform panel edits when nothing is playing.
    @Published var focusedRef: TrackRef? = nil
    /// Second-screen web viewer state.
    @Published var viewerRunning = false
    @Published var viewerURL: String? = nil
    @Published var showViewerSheet = false

    let engine = AudioEngine()
    let power = PowerManager()
    let viewer = WebServer()
    let settings = AppSettings.shared

    private let supportDir: URL
    private let showURL: URL
    private let libraryURL: URL
    private let showsDir: URL
    private let mediaDir: URL
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
        // Crocus-managed audio lives in ~/Music/Crocus/Media so imports never break.
        mediaDir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crocus/Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        Self.migrateLegacyData(into: base)
        load()

        // Hold the display awake for the whole session, not just while audio is
        // playing. Crocus stops the music at the end of every group by design, so
        // playback-tied wakefulness would release the hold precisely when the host
        // is back-announcing — talking, touching nothing, for a minute or two.
        power.setKeepAwake(true)

        // When a group finishes on its own, cue the next group paused.
        engine.onGroupFinished = { [weak self] in self?.cueNextGroupPaused() }

        // Measure loudness for the existing library in the background so
        // level-matching is ready by the time a song plays.
        for t in library { LoudnessStore.shared.ensure(t.url) }
        for t in show.backups.tracks { LoudnessStore.shared.ensure(t.url) }

        // Feed the second-screen viewer (when it's running) as playback changes.
        engine.objectWillChange
            .throttle(for: .milliseconds(300), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.pushViewerStatus() }
            .store(in: &cancellables)
        $show
            .throttle(for: .milliseconds(300), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.pushViewerStatus() }
            .store(in: &cancellables)
    }

    // MARK: - Second-screen viewer

    func setViewer(_ on: Bool) {
        if on {
            viewer.start { [weak self] port in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let port, let ip = WebServer.localIPAddress() {
                        self.viewerURL = "http://\(ip):\(port)"
                        self.viewerRunning = true
                        self.pushViewerStatus()
                    } else {
                        self.viewerRunning = false
                        self.viewerURL = nil
                    }
                }
            }
        } else {
            viewer.stop()
            viewerRunning = false
            viewerURL = nil
        }
    }

    private func pushViewerStatus() {
        guard viewerRunning else { return }
        let st = engine.state == .playing ? "playing" : (engine.state == .paused ? "paused" : "stopped")
        let status = ViewerStatus(
            show: show.displayTitle, theme: show.theme, state: st,
            ducked: engine.isDucked || engine.isFadingToTalk,
            title: engine.currentTrack?.title, artist: engine.currentTrack?.artist,
            next: engine.upNextTrack?.displayArtistTitle,
            remaining: engine.groupRemaining, elapsed: engine.currentElapsed,
            segDur: engine.currentSegmentDuration)
        if let d = try? JSONEncoder().encode(status) { viewer.setStatus(d) }
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
                         duckLevel: Float(show.duckLevel),
                         fadeOut: show.fadeOutDuration,
                         gains: normGains(for: g.tracks),
                         master: Float(show.masterGain))
    }

    /// Loudness-match gains (linear) for a set of tracks, honouring the toggle.
    private func normGains(for tracks: [Track]) -> [Float] {
        tracks.map { LoudnessStore.shared.gain(for: $0.url, enabled: show.normalizeLoudness) }
    }

    /// Live master output level (drives the desk feed). Applies immediately.
    func setMasterGain(_ v: Double) {
        show.masterGain = v
        engine.setMasterGain(Float(v))
    }

    /// Live Fade Out length. Applies to the next press of Fade Out, so it can be
    /// dialled in during the very song you're about to take out.
    func setFadeOutDuration(_ v: Double) {
        show.fadeOutDuration = v
        engine.setFadeOutDuration(v)
    }

    func playGroup(_ group: SongGroup) {
        resignTextFocus()
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

    /// After a group ends, load the next one paused/cued on its first track.
    func cueNextGroupPaused() {
        guard let current = selectedGroupID,
              let i = show.groups.firstIndex(where: { $0.id == current }) else { return }
        let next = i + 1
        guard next < show.groups.count else { return }   // last group: stay off air
        let g = show.groups[next]
        selectedGroupID = g.id
        focusedRef = nil
        guard !g.tracks.isEmpty else { return }
        engine.cueGroup(g.tracks, crossfade: show.crossfadeDuration,
                        fadeToTalk: show.duckTime, duckLevel: Float(show.duckLevel),
                        fadeOut: show.fadeOutDuration,
                        gains: normGains(for: g.tracks), master: Float(show.masterGain))
    }

    /// Resolve a dragged payload to its Track, from whichever source it came.
    func resolveDraggedTrack(_ p: DragPayload) -> Track? {
        if p.fromBackups { return show.backups.tracks.first { $0.id == p.trackID } }
        if let from = p.fromGroupID {
            return show.groups.first { $0.id == from }?.tracks.first { $0.id == p.trackID }
        }
        return library.first { $0.id == p.trackID }
    }

    /// Play a single dragged song immediately (one-off — doesn't auto-cue next).
    func playSingle(_ payload: DragPayload) {
        guard let track = resolveDraggedTrack(payload) else { return }
        engine.playGroup([track], crossfade: 0,
                         fadeToTalk: show.duckTime, duckLevel: Float(show.duckLevel),
                         fadeOut: show.fadeOutDuration, cueNext: false,
                         gains: normGains(for: [track]), master: Float(show.masterGain))
    }

    // MARK: - Backups (spare songs for filling time, kept out of the rundown)

    /// Add a dragged song to the Backups shelf (duplicates allowed).
    func addToBackups(_ payload: DragPayload) {
        guard payload.fromBackups == false, var track = resolveDraggedTrack(payload) else { return }
        track.id = UUID()
        show.backups.tracks.append(track)
        LoudnessStore.shared.ensure(track.url)
        saveShow()
    }

    /// Import audio files dropped from Finder straight onto the Backups shelf:
    /// bring them into the managed library (reusing an existing copy if present),
    /// then add each to Backups.
    func importToBackups(_ urls: [URL]) {
        let audio = urls.filter { isAudio($0) }
        guard !audio.isEmpty else { return }
        Task {
            for src in audio {
                _ = src.startAccessingSecurityScopedResource()
                guard let libTrack = await resolveOrImport(src) else { continue }
                var backup = libTrack
                backup.id = UUID()
                show.backups.tracks.append(backup)
                LoudnessStore.shared.ensure(backup.url)
            }
            saveShow()
        }
    }

    /// Find the library track matching a source file (same artist+title, or the
    /// same managed file), importing it if it's new. Returns nil on failure.
    private func resolveOrImport(_ src: URL) async -> Track? {
        let tags = await MetadataIO.readFileTags(src)
        let title = (tags.title?.isEmpty == false) ? tags.title! : src.deletingPathExtension().lastPathComponent
        let artist = tags.artist ?? ""
        let taKey = artistTitleKey(artist: artist, title: title)
        if let match = library.first(where: { artistTitleKey(artist: $0.artist, title: $0.title) == taKey }) {
            return match
        }
        let dest = copyIntoMedia(src)
        if let existing = library.first(where: { $0.url.standardizedFileURL == dest.standardizedFileURL }) {
            return existing
        }
        var track = makeTrack(from: dest)
        track.title = title
        track.artist = artist
        if let al = tags.album, !al.isEmpty { track.album = al }
        track.year = tags.year
        library.append(track)
        saveLibrary()
        ArtworkCache.shared.ensure(track.url)
        LoudnessStore.shared.ensure(track.url)
        return track
    }

    func removeBackup(_ track: Track) {
        show.backups.tracks.removeAll { $0.id == track.id }
        saveShow()
    }

    /// Fire a backup song immediately as a one-off (doesn't disturb the rundown).
    func playBackup(_ track: Track) {
        resignTextFocus()
        engine.playGroup([track], crossfade: 0,
                         fadeToTalk: show.duckTime, duckLevel: Float(show.duckLevel),
                         fadeOut: show.fadeOutDuration, cueNext: false,
                         gains: normGains(for: [track]), master: Float(show.masterGain))
    }

    /// Jump the currently-playing song's audio to its (edited) start marker.
    func reseekCurrentToTrim(_ ref: TrackRef) {
        guard let t = track(for: ref) else { return }
        engine.rescheduleCurrentFromStart(trackID: t.id, trimStart: t.trimStart, trimEnd: t.trimEnd)
    }

    /// Clear a song's trim back to full length.
    func resetTrim(_ ref: TrackRef) {
        updateTrim(groupID: ref.groupID, trackID: ref.trackID, start: 0, end: nil)
        if engine.state != .stopped, engine.currentTrack?.id == ref.trackID {
            engine.rescheduleCurrentFromStart(trackID: ref.trackID, trimStart: 0, trimEnd: nil)
        }
    }

    func stop() { resignTextFocus(); engine.stop() }
    func skipSong() { resignTextFocus(); engine.skipSong() }
    func previousSong() { resignTextFocus(); engine.previousSong() }
    func fadeToTalk() { resignTextFocus(); engine.startFadeToTalk() }
    func fadeOutSong() { resignTextFocus(); engine.fadeOutCurrent() }
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
        guard !collected.isEmpty else { return }
        Task { await ingest(collected) }
    }

    /// Read each source's tags, skip exact-match duplicates (identical file
    /// content, OR same artist + title already in the library), then copy the
    /// keepers into the managed Media folder and add them — pre-filled with their
    /// tags so there's no filename flash.
    private func ingest(_ sources: [URL]) async {
        var titleArtistKeys = Set(library.map { artistTitleKey(artist: $0.artist, title: $0.title) })
        var sizeIndex: [Int: [URL]] = [:]
        for t in library {
            let s = fileSize(t.url)
            if s >= 0 { sizeIndex[s, default: []].append(t.url) }
        }
        var hashCache: [String: String] = [:]
        func hashFor(_ url: URL) -> String? {
            let p = url.standardizedFileURL.path
            if let h = hashCache[p] { return h }
            guard let h = contentHash(url) else { return nil }
            hashCache[p] = h
            return h
        }

        var newTracks: [Track] = []
        var skipped = 0

        for src in sources {
            // Duplicate by identical file content (size first, then hash).
            let size = fileSize(src)
            var isDupe = false
            if size >= 0, let candidates = sizeIndex[size], let srcHash = hashFor(src) {
                isDupe = candidates.contains { hashFor($0) == srcHash }
            }

            let tags = await MetadataIO.readFileTags(src)
            let title = (tags.title?.isEmpty == false) ? tags.title! : src.deletingPathExtension().lastPathComponent
            let artist = tags.artist ?? ""
            let taKey = artistTitleKey(artist: artist, title: title)

            // Duplicate by artist + title.
            if !isDupe, titleArtistKeys.contains(taKey) { isDupe = true }
            if isDupe { skipped += 1; continue }

            let dest = copyIntoMedia(src)
            let key = dest.standardizedFileURL
            if library.contains(where: { $0.url.standardizedFileURL == key })
                || newTracks.contains(where: { $0.url.standardizedFileURL == key }) {
                skipped += 1
                continue
            }

            var track = makeTrack(from: dest)
            track.title = title
            track.artist = artist
            if let al = tags.album, !al.isEmpty { track.album = al }
            track.year = tags.year
            newTracks.append(track)

            // Register so later files in this same batch dedupe against it too.
            titleArtistKeys.insert(taKey)
            let ds = fileSize(dest)
            if ds >= 0 { sizeIndex[ds, default: []].append(dest) }
            if let h = hashFor(src) { hashCache[dest.standardizedFileURL.path] = h }
        }

        if !newTracks.isEmpty {
            library.append(contentsOf: newTracks)
            saveLibrary()
            for t in newTracks {
                ArtworkCache.shared.ensure(t.url)
                LoudnessStore.shared.ensure(t.url)
            }
        }
        if skipped > 0 {
            infoAlert("Skipped duplicates",
                      "\(skipped) \(skipped == 1 ? "file was" : "files were") already in the library (identical file, or same artist & title).")
        }
    }

    /// A case-insensitive key for artist+title duplicate detection.
    private func artistTitleKey(artist: String, title: String) -> String {
        let a = artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let t = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(a)\u{1}\(t)"
    }

    /// SHA-256 of a file's bytes (memory-mapped), for exact-content dedupe.
    private func contentHash(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Copy a source file into the managed Media folder with a tidy name.
    /// Reuses an existing identical copy; returns the original on failure.
    private func copyIntoMedia(_ src: URL) -> URL {
        let fm = FileManager.default
        let cleaned = sanitizedFileName(src.lastPathComponent)
        var dest = mediaDir.appendingPathComponent(cleaned)
        if fm.fileExists(atPath: dest.path) {
            let s = fileSize(src), d = fileSize(dest)
            if s >= 0, s == d { return dest }          // identical file already managed
            dest = freeName(base: cleaned)             // name clash, different file
        }
        do { try fm.copyItem(at: src, to: dest); return dest }
        catch { return src }
    }

    private func fileSize(_ url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? Int else { return -1 }
        return n
    }

    private func sanitizedFileName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        base = base.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
                   .joined(separator: "-")
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.contains("  ") { base = base.replacingOccurrences(of: "  ", with: " ") }
        if base.isEmpty { base = "track" }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Managed-media files not referenced by the library, current show, or any
    /// archived show — safe to reclaim.
    private func unusedMediaFiles() -> [URL] {
        let fm = FileManager.default
        var referenced = Set<String>()
        for t in library { referenced.insert(t.url.standardizedFileURL.path) }
        for g in show.groups { for t in g.tracks { referenced.insert(t.url.standardizedFileURL.path) } }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let showFiles = (try? fm.contentsOfDirectory(at: showsDir, includingPropertiesForKeys: nil)) ?? []
        for f in showFiles where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let s = try? dec.decode(Show.self, from: d) {
                for g in s.groups { for t in g.tracks { referenced.insert(t.url.standardizedFileURL.path) } }
            }
        }
        let media = (try? fm.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil)) ?? []
        return media.filter { f in
            !f.lastPathComponent.hasPrefix(".") &&
            !referenced.contains(f.standardizedFileURL.path)
        }
    }

    /// Move unreferenced managed files to the Trash, with a confirmation.
    func cleanUnusedMedia() {
        let candidates = unusedMediaFiles()
        guard !candidates.isEmpty else {
            infoAlert("Nothing to clean", "Every file in your Media folder is still used by the library or a show.")
            return
        }
        let totalBytes = candidates.reduce(0) { $0 + max(0, fileSize($1)) }
        let alert = NSAlert()
        alert.messageText = "Clean Unused Media?"
        alert.informativeText = "\(candidates.count) file(s) (\(formatBytes(totalBytes))) in your Media folder aren't used by the library or any show. Move them to the Trash?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var trashed = 0
        for f in candidates where (try? FileManager.default.trashItem(at: f, resultingItemURL: nil)) != nil {
            trashed += 1
        }
        infoAlert("Cleaned up", "Moved \(trashed) file(s) to the Trash.")
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func infoAlert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private func freeName(base: String) -> URL {
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        var n = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let url = mediaDir.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    func removeFromLibrary(_ track: Track) {
        library.removeAll { $0.id == track.id }
        saveLibrary()
    }

    /// Empty the whole library (with confirmation). Leaves the audio files in the
    /// Media folder — reclaim disk later with "Clean Unused Media…". Songs already
    /// in the current or saved shows are unaffected.
    func clearLibrary() {
        guard !library.isEmpty else {
            infoAlert("Library is empty", "There are no songs to clear.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Clear the Library?"
        alert.informativeText = "Remove all \(library.count) song(s) from the library. The audio files stay in your Media folder (reclaim disk later with “Clean Unused Media…”). Songs already in this show or a saved show are unaffected."
        alert.addButton(withTitle: "Clear Library")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.removeAll()
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

    /// Build a Track (duration from the audio file; title from filename). The
    /// caller fills in real title/artist/album/year from the tags read during
    /// import (see `ingest`).
    private func makeTrack(from url: URL) -> Track {
        var duration: TimeInterval = 0
        if let file = try? AVAudioFile(forReading: url) {
            let fmt = file.processingFormat
            if fmt.sampleRate > 0 { duration = Double(file.length) / fmt.sampleRate }
        }
        let name = url.deletingPathExtension().lastPathComponent
        return Track(url: url, title: name, artist: "", duration: duration)
    }

    // MARK: - Metadata editing

    /// The library track backing the metadata editor sheet.
    var editingTrack: Track? {
        guard let id = editingLibraryTrackID else { return nil }
        return library.first { $0.id == id }
    }

    /// Apply edited title/artist/album/year to the library entry AND to every
    /// copy of the song already sitting in the current show's groups. Group
    /// copies are matched by file URL, because a track dragged into a group is
    /// given a fresh id (see `handleDrop`) — the URL is the stable join key.
    /// `note` is intentionally left alone (it's per-group, edited in the rundown).
    func updateTrackMetadata(id: Track.ID, title: String, artist: String,
                             album: String, year: Int?) {
        guard let li = library.firstIndex(where: { $0.id == id }) else { return }
        let key = library[li].url.standardizedFileURL

        library[li].title = title
        library[li].artist = artist
        library[li].album = album
        library[li].year = year
        saveLibrary()

        var touchedShow = false
        for gi in show.groups.indices {
            for ti in show.groups[gi].tracks.indices
            where show.groups[gi].tracks[ti].url.standardizedFileURL == key {
                show.groups[gi].tracks[ti].title = title
                show.groups[gi].tracks[ti].artist = artist
                show.groups[gi].tracks[ti].album = album
                show.groups[gi].tracks[ti].year = year
                touchedShow = true
            }
        }
        if touchedShow { saveShow() }
    }

    /// Write the given tags into the underlying audio file, then mirror them into
    /// Crocus (library + groups) and refresh artwork. Throws on failure, leaving
    /// the original file untouched (see `MetadataIO.writeFileTags`).
    func writeTagsToFile(id: Track.ID, title: String, artist: String,
                         album: String, year: Int?) async throws {
        guard let track = library.first(where: { $0.id == id }) else { return }
        let tags = FileTags(title: title.isEmpty ? nil : title,
                            artist: artist.isEmpty ? nil : artist,
                            album: album.isEmpty ? nil : album,
                            year: year)
        try await MetadataIO.writeFileTagsAsync(track.url, tags)
        updateTrackMetadata(id: id, title: title, artist: artist, album: album, year: year)
        ArtworkCache.shared.invalidate(track.url)
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

    /// Move a group to a gap position in the rundown. `target` is an insertion
    /// slot in the original ordering (0 = before the first group, count = after
    /// the last), as produced by the drop-gaps between cards.
    func moveGroup(_ id: SongGroup.ID, toIndex target: Int) {
        guard let from = show.groups.firstIndex(where: { $0.id == id }) else { return }
        let moved = show.groups.remove(at: from)
        var insertAt = target
        if from < target { insertAt -= 1 }          // account for the removal above
        insertAt = max(0, min(insertAt, show.groups.count))
        show.groups.insert(moved, at: insertAt)
        saveShow()
    }

    /// Is this song's file already placed somewhere in the current show? Used to
    /// keep a song to a single appearance per show.
    func isInShow(_ url: URL) -> Bool {
        let key = url.standardizedFileURL
        return show.groups.contains { $0.tracks.contains { $0.url.standardizedFileURL == key } }
    }

    /// Add a library song to a group, unless that song is already in the show.
    @discardableResult
    func addToGroup(_ track: Track, groupID: SongGroup.ID) -> Bool {
        guard let i = show.groups.firstIndex(where: { $0.id == groupID }) else { return false }
        guard !isInShow(track.url) else { return false }
        show.groups[i].tracks.append(track)
        saveShow()
        return true
    }

    /// Add to the selected group, creating one if needed.
    @discardableResult
    func addToCurrentGroup(_ track: Track) -> Bool {
        guard !isInShow(track.url) else { return false }
        if selectedGroupID == nil { newGroup() }
        if let id = selectedGroupID { return addToGroup(track, groupID: id) }
        return false
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

    /// Update trim in memory without writing to disk (used live during a drag).
    func setTrim(groupID: SongGroup.ID, trackID: Track.ID,
                 start: TimeInterval, end: TimeInterval?) {
        guard let gi = show.groups.firstIndex(where: { $0.id == groupID }),
              let ti = show.groups[gi].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        show.groups[gi].tracks[ti].trimStart = max(0, start)
        show.groups[gi].tracks[ti].trimEnd = end
        // If this song is playing right now, honour an end-marker shorten live.
        engine.applyLiveTrim(trackID: trackID, trimStart: max(0, start), trimEnd: end)
    }

    func updateTrim(groupID: SongGroup.ID, trackID: Track.ID,
                    start: TimeInterval, end: TimeInterval?) {
        setTrim(groupID: groupID, trackID: trackID, start: start, end: end)
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
            let ref = TrackRef(groupID: gid, trackID: cur.id)
            // Prefer the editable stored track so trim edits show; fall back to
            // the engine's snapshot if it isn't in the group for some reason.
            return (ref, track(for: ref) ?? cur)
        }
        if let ref = focusedRef, let t = track(for: ref) { return (ref, t) }
        return nil
    }

    // MARK: - Drag & drop

    /// Move/insert a dragged track into a group at a position. A track dragged
    /// from the library is added once; a song already placed in the show can't be
    /// added again (drag it between groups to move it instead).
    func handleDrop(_ payload: DragPayload, intoGroup groupID: SongGroup.ID, at index: Int?) {
        var dragged: Track
        if let from = payload.fromGroupID {
            guard let si = show.groups.firstIndex(where: { $0.id == from }),
                  let ti = show.groups[si].tracks.firstIndex(where: { $0.id == payload.trackID })
            else { return }
            dragged = show.groups[si].tracks.remove(at: ti)
        } else {
            // From the library or the Backups shelf → copy in (once per show).
            guard let src = resolveDraggedTrack(payload) else { return }
            guard !isInShow(src.url) else { return }
            dragged = src
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

    /// The station's running order — one numbered column of "Artist - Title".
    func copyRunningOrder() {
        copyToClipboard(Exporter.runningOrder(show))
    }

    /// The full episode, grouped, with years and notes — the raw material for
    /// writing up longer show notes.
    func copyDetailedNotes() {
        copyToClipboard(Exporter.detailedNotes(show))
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func exportMarkdown() {
        save(text: Exporter.markdown(show, settings.exportIdentity),
             suggested: Exporter.slug(show) + ".md", type: "md")
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
        // Named from settings rather than carried forward, so correcting the show
        // name in Settings takes effect on the next episode without an edit here.
        show = Show(name: settings.showName, number: nextNumber, date: Date())
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
        } else {
            // Fresh install: brand the very first show from settings rather than
            // leaving the placeholder name sitting in the header.
            show.name = AppSettings.shared.showName
        }
    }
}
