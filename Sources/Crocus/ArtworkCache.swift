import Foundation
import AVFoundation
import AppKit
import Combine

/// Pulls embedded cover art out of audio files (lazily, off the main thread) and
/// caches the images. Album/year tags are read into the Track model elsewhere.
@MainActor
final class ArtworkCache: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var misses: Set<String> = []

    static let shared = ArtworkCache()

    func image(for url: URL) -> NSImage? { images[url.path] }

    /// Forget any cached art (or recorded miss) for a URL so the next `ensure`
    /// re-reads it — e.g. after the file's tags/artwork have been rewritten.
    func invalidate(_ url: URL) {
        let key = url.path
        images[key] = nil
        misses.remove(key)
    }

    func ensure(_ url: URL) {
        let key = url.path
        guard images[key] == nil, !inFlight.contains(key), !misses.contains(key) else { return }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            var found: NSImage?
            if let items = try? await asset.load(.commonMetadata) {
                for item in items where item.commonKey == .commonKeyArtwork {
                    if let data = try? await item.load(.dataValue), let img = NSImage(data: data) {
                        found = img
                        break
                    }
                }
            }
            let result = found
            await MainActor.run {
                ArtworkCache.shared.inFlight.remove(key)
                if let result { ArtworkCache.shared.images[key] = result }
                else { ArtworkCache.shared.misses.insert(key) }
            }
        }
    }
}
