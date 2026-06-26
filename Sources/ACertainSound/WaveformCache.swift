import Foundation
import AVFoundation
import Combine

/// Computes and caches downsampled waveform peaks per audio file, off the main
/// thread, so the UI can draw a song's shape (and its quiet parts) at a glance.
@MainActor
final class WaveformCache: ObservableObject {
    /// url.path -> normalized peaks (0...1), one per horizontal bucket.
    @Published private(set) var cache: [String: [Float]] = [:]
    private var inFlight: Set<String> = []

    nonisolated static let buckets = 1000

    func peaks(for url: URL) -> [Float]? { cache[url.path] }

    /// Ensure peaks exist for this file; computes asynchronously if needed.
    func ensure(_ url: URL) {
        let key = url.path
        guard cache[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            let result = WaveformCache.analyze(url)
            await MainActor.run {
                if let result { WaveformCache.shared.store(key: key, peaks: result) }
                WaveformCache.shared.inFlight.remove(key)
            }
        }
    }

    static let shared = WaveformCache()

    private func store(key: String, peaks: [Float]) { cache[key] = peaks }

    /// Read the file in chunks and reduce to `buckets` peak values.
    nonisolated static func analyze(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let total = file.length
        guard total > 0, format.channelCount > 0 else { return nil }

        let bucketCount = buckets
        let framesPerBucket = max(1, Int(total) / bucketCount)
        var peaks = [Float](repeating: 0, count: bucketCount)

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }

        var globalFrame = 0
        while true {
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: chunk) }
            catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let ch = buffer.floatChannelData else { break }
            let data = ch[0]   // first channel is representative enough for display
            var i = 0
            while i < n {
                let bucket = min(bucketCount - 1, (globalFrame + i) / framesPerBucket)
                let v = abs(data[i])
                if v > peaks[bucket] { peaks[bucket] = v }
                i += 1
            }
            globalFrame += n
            if globalFrame >= Int(total) { break }
        }

        // Normalize to a pleasant range.
        let maxPeak = peaks.max() ?? 1
        if maxPeak > 0 {
            for j in 0..<peaks.count { peaks[j] = min(1, peaks[j] / maxPeak) }
        }
        return peaks
    }
}
