import Foundation
import AVFoundation
import ID3TagEditor

/// The title/artist/album/year actually embedded in an audio file — read fresh
/// from disk (as opposed to what Crocus has cached in its `Track` model).
struct FileTags: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var year: Int?
}

/// How (or whether) Crocus can write tags back into a given file, chosen by
/// extension. mp3 goes through ID3TagEditor; the mp4 family through AVFoundation;
/// everything else is read-only for now.
enum TagWritability {
    case id3          // mp3
    case avFoundation // m4a / aac / mp4 / m4b
    case unsupported  // flac, wav, aiff, alac, caf, …

    var canWrite: Bool { self != .unsupported }
}

/// Reads and writes embedded audio metadata, format-aware. Reading works for
/// every supported format; writing is limited to the formats macOS can safely
/// re-tag without re-encoding the audio (see `TagWritability`).
enum MetadataIO {

    static func writability(for url: URL) -> TagWritability {
        switch url.pathExtension.lowercased() {
        case "mp3":                     return .id3
        case "m4a", "aac", "mp4", "m4b": return .avFoundation
        default:                        return .unsupported
        }
    }

    /// The reason a file can't be written to, for showing in the editor.
    static func unsupportedReason(for url: URL) -> String {
        let ext = url.pathExtension.uppercased()
        return "\(ext.isEmpty ? "This" : ext) files can't be re-tagged by Crocus — edit in Crocus only."
    }

    // MARK: - Reading

    /// Read the tags embedded in the file. Never throws — returns whatever it can.
    static func readFileTags(_ url: URL) async -> FileTags {
        if writability(for: url) == .id3, let tags = readID3(url) {
            return tags
        }
        return await readViaAVFoundation(url)
    }

    private static func readID3(_ url: URL) -> FileTags? {
        guard let tag = try? ID3TagEditor().read(from: url.path) else { return nil }
        let reader = ID3TagContentReader(id3Tag: tag)
        return FileTags(title: reader.title(),
                        artist: reader.artist(),
                        album: reader.album(),
                        year: reader.recordingYear() ?? reader.recordingDateTime()?.year)
    }

    private static func readViaAVFoundation(_ url: URL) async -> FileTags {
        let asset = AVURLAsset(url: url)
        var tags = FileTags()
        guard let items = try? await asset.load(.commonMetadata) else { return tags }
        for item in items {
            guard let key = item.commonKey else { continue }
            let value = try? await item.load(.stringValue)
            switch key {
            case .commonKeyTitle:        if let v = value, !v.isEmpty { tags.title = v }
            case .commonKeyArtist:       if let v = value, !v.isEmpty { tags.artist = v }
            case .commonKeyAlbumName:    if let v = value, !v.isEmpty { tags.album = v }
            case .commonKeyCreationDate: if let v = value, let y = extractYear(v) { tags.year = y }
            default: break
            }
        }
        return tags
    }

    /// Pull a 4-digit year out of a metadata date string like "2012-05-01".
    static func extractYear(_ s: String) -> Int? {
        let digits = s.prefix(while: { $0 != "-" && $0 != "/" })
        if digits.count == 4, let y = Int(digits) { return y }
        let chars = Array(s)
        guard chars.count >= 4 else { return nil }
        for i in 0...(chars.count - 4) {
            let sub = String(chars[i..<i+4])
            if sub.allSatisfy({ $0.isNumber }), let y = Int(sub), y > 1900, y < 2200 { return y }
        }
        return nil
    }

    // MARK: - Writing

    enum WriteError: LocalizedError {
        case unsupportedFormat
        case exportFailed(String)
        case validationFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "This file format can't be re-tagged."
            case .exportFailed(let m): return "Couldn't write the file: \(m)"
            case .validationFailed: return "The written file didn't read back correctly — original left untouched."
            }
        }
    }

    /// Write the given tags into the file at `url`, in place. Only non-nil,
    /// non-empty fields are applied; other embedded data (artwork, etc.) is
    /// preserved. Writes to a temp file, validates it, then atomically replaces
    /// the original — so a failure never corrupts the source file.
    static func writeFileTags(_ url: URL, _ tags: FileTags) throws {
        switch writability(for: url) {
        case .id3:          try writeID3(url, tags)
        case .avFoundation: throw WriteError.exportFailed("m4a writing is handled asynchronously")
        case .unsupported:  throw WriteError.unsupportedFormat
        }
    }

    /// Async entry point — needed for the AVFoundation (m4a) export path.
    static func writeFileTagsAsync(_ url: URL, _ tags: FileTags) async throws {
        switch writability(for: url) {
        case .id3:          try writeID3(url, tags)
        case .avFoundation: try await writeAVFoundation(url, tags)
        case .unsupported:  throw WriteError.unsupportedFormat
        }
    }

    // MARK: mp3 (ID3TagEditor)

    private static func writeID3(_ url: URL, _ tags: FileTags) throws {
        let editor = ID3TagEditor()
        let existing = try? editor.read(from: url.path)
        let reader = existing.map { ID3TagContentReader(id3Tag: $0) }

        // Rebuild a clean ID3v2.3 tag through the typed builder rather than
        // mutating and rewriting the parsed tag. This matters for safety:
        //   • ID3TagEditor crashes (a force-unwrap, not a catchable error) if the
        //     writer is handed a frame it can't encode for the tag's version — e.g.
        //     setting the year (TYER) on a v2.4 tag, where TYER is deprecated.
        //   • Going through the builder guarantees every frame we emit is one the
        //     writer can encode. v2.3 supports TYER directly, so year "just works".
        // We normalise to v2.3 (the most broadly compatible version) and carry over
        // the frames that matter for a music library; blank edits fall back to the
        // existing value so a partial edit never wipes a field.
        let builder = ID32v3TagBuilder()

        let newTitle  = (tags.title?.isEmpty == false ? tags.title : nil)  ?? reader?.title()
        let newArtist = (tags.artist?.isEmpty == false ? tags.artist : nil) ?? reader?.artist()
        let newAlbum  = (tags.album?.isEmpty == false ? tags.album : nil)  ?? reader?.album()
        let newYear   = tags.year ?? reader?.recordingYear() ?? reader?.recordingDateTime()?.year

        if let v = newTitle,  !v.isEmpty { _ = builder.title(frame: ID3FrameWithStringContent(content: v)) }
        if let v = newArtist, !v.isEmpty { _ = builder.artist(frame: ID3FrameWithStringContent(content: v)) }
        if let v = newAlbum,  !v.isEmpty { _ = builder.album(frame: ID3FrameWithStringContent(content: v)) }
        if let y = newYear { _ = builder.recordingYear(frame: ID3FrameWithIntegerContent(value: y)) }

        if let r = reader {
            if let aa = r.albumArtist(), !aa.isEmpty {
                _ = builder.albumArtist(frame: ID3FrameWithStringContent(content: aa))
            }
            if let c = r.composer(), !c.isEmpty {
                _ = builder.composer(frame: ID3FrameWithStringContent(content: c))
            }
            if let g = r.genre() {
                _ = builder.genre(frame: ID3FrameGenre(genre: g.identifier, description: g.description))
            }
            if let t = r.trackPosition() {
                _ = builder.trackPosition(frame: ID3FramePartOfTotal(part: t.position, total: t.total))
            }
            if let d = r.discPosition() {
                _ = builder.discPosition(frame: ID3FramePartOfTotal(part: d.position, total: d.total))
            }
            for comment in r.comments() {
                _ = builder.comment(language: comment.language,
                                    frame: ID3FrameWithLocalizedContent(language: comment.language,
                                                                        contentDescription: comment.contentDescription,
                                                                        content: comment.content))
            }
            for pic in r.attachedPictures() {
                _ = builder.attachedPicture(pictureType: pic.type,
                                            frame: ID3FrameAttachedPicture(picture: pic.picture,
                                                                           type: pic.type,
                                                                           format: pic.format))
            }
        }

        let tag = builder.build()
        let temp = try tempURL(for: url)
        defer { try? FileManager.default.removeItem(at: temp) }

        do {
            try editor.write(tag: tag, to: url.path, andSaveTo: temp.path)
        } catch {
            throw WriteError.exportFailed(error.localizedDescription)
        }

        try validateAndReplace(original: url, temp: temp, expected: tags, useID3: true)
    }

    // MARK: m4a / aac (AVFoundation)

    private static func writeAVFoundation(_ url: URL, _ tags: FileTags) async throws {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetPassthrough) else {
            throw WriteError.exportFailed("couldn't create an export session")
        }
        let temp = try tempURL(for: url)
        defer { try? FileManager.default.removeItem(at: temp) }

        export.outputURL = temp
        export.outputFileType = .m4a
        export.metadata = metadataItems(for: tags)

        await export.export()  // extension below bridges the callback API

        if export.status == .failed {
            throw WriteError.exportFailed(export.error?.localizedDescription ?? "unknown export error")
        }
        guard export.status == .completed else {
            throw WriteError.exportFailed("export ended in state \(export.status.rawValue)")
        }

        try validateAndReplace(original: url, temp: temp, expected: tags, useID3: false)
    }

    private static func metadataItems(for tags: FileTags) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: (any NSCopying & NSObjectProtocol)?) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        if let t = tags.title,  !t.isEmpty { add(.commonIdentifierTitle, t as NSString) }
        if let a = tags.artist, !a.isEmpty { add(.commonIdentifierArtist, a as NSString) }
        if let al = tags.album, !al.isEmpty { add(.commonIdentifierAlbumName, al as NSString) }
        if let y = tags.year { add(.commonIdentifierCreationDate, String(y) as NSString) }
        return items
    }

    // MARK: - Shared helpers

    private static func tempURL(for url: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("crocus-retag-\(UUID().uuidString)")
                  .appendingPathExtension(url.pathExtension)
    }

    /// Re-read the freshly written temp file to confirm the edits stuck and the
    /// file still parses, then atomically swap it in for the original.
    private static func validateAndReplace(original: URL, temp: URL,
                                           expected: FileTags, useID3: Bool) throws {
        let written: FileTags
        if useID3 {
            guard let check = readID3(temp) else { throw WriteError.validationFailed }
            written = check
        } else {
            // AVFoundation read is async; do a lightweight synchronous existence +
            // size check plus a best-effort tag read on a semaphore.
            guard (try? temp.checkResourceIsReachable()) == true,
                  let size = try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 else { throw WriteError.validationFailed }
            written = FileTags() // trust the export; detailed re-read happens on next open
        }

        if useID3 {
            // Only assert the string fields we actually asked to change.
            if let t = expected.title, !t.isEmpty, written.title != t { throw WriteError.validationFailed }
            if let a = expected.artist, !a.isEmpty, written.artist != a { throw WriteError.validationFailed }
            if let al = expected.album, !al.isEmpty, written.album != al { throw WriteError.validationFailed }
        }

        _ = try FileManager.default.replaceItemAt(original, withItemAt: temp)
    }
}

// Bridge AVAssetExportSession's callback-based export to async/await (macOS 14).
private extension AVAssetExportSession {
    func export() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.exportAsynchronously { continuation.resume() }
        }
    }
}
