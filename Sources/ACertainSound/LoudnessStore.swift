import Foundation
import AVFoundation
import Combine

/// Per-file loudness (average RMS) and true peak, used to normalise every song
/// toward a common target level at playback — quiet songs boosted, loud songs
/// cut, and never past the point of clipping.
struct LoudnessInfo: Codable { var rms: Float; var peak: Float }

@MainActor
final class LoudnessStore: ObservableObject {
    static let shared = LoudnessStore()

    @Published private(set) var cache: [String: LoudnessInfo] = [:]
    private var inFlight: Set<String> = []
    private let fileURL: URL

    /// Target integrated level (dBFS RMS). Songs are matched toward this.
    static let targetDB: Double = -16
    static var targetLinear: Float { Float(pow(10.0, targetDB / 20.0)) }
    /// Never boost more than +12 dB (avoids amplifying near-silent material).
    static let maxBoost: Float = 4.0

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crocus", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("loudness.json")
        if let d = try? Data(contentsOf: fileURL),
           let m = try? JSONDecoder().decode([String: LoudnessInfo].self, from: d) {
            cache = m
        }
    }

    func info(for url: URL) -> LoudnessInfo? { cache[url.path] }

    /// Measure this file in the background if we haven't already.
    func ensure(_ url: URL) {
        let key = url.path
        guard cache[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            let result = LoudnessStore.analyze(url)
            await MainActor.run {
                if let result { LoudnessStore.shared.store(key: key, info: result) }
                LoudnessStore.shared.inFlight.remove(key)
            }
        }
    }

    /// Linear playback gain to bring this song to the target without clipping.
    /// Returns 1 (no change) when disabled or not yet measured.
    func gain(for url: URL, enabled: Bool) -> Float {
        guard enabled, let info = cache[url.path], info.rms > 0 else { return 1 }
        let desired = LoudnessStore.targetLinear / info.rms
        let peakCeiling = info.peak > 0 ? (0.97 / info.peak) : LoudnessStore.maxBoost
        return max(0.05, min(desired, peakCeiling, LoudnessStore.maxBoost))
    }

    private func store(key: String, info: LoudnessInfo) {
        cache[key] = info
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: fileURL, options: .atomic) }
    }

    /// Scan the whole file for average RMS and peak. Runs off the main thread.
    nonisolated static func analyze(_ url: URL) -> LoudnessInfo? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard file.length > 0, format.channelCount > 0 else { return nil }
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }

        var sumSquares = 0.0
        var count = 0.0
        var peak: Float = 0
        while true {
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let ch = buffer.floatChannelData else { break }
            let data = ch[0]
            var i = 0
            while i < n {
                let v = data[i]
                sumSquares += Double(v) * Double(v)
                let a = abs(v)
                if a > peak { peak = a }
                i += 1
            }
            count += Double(n)
        }
        guard count > 0 else { return nil }
        let rms = Float((sumSquares / count).squareRoot())
        return LoudnessInfo(rms: rms, peak: peak)
    }
}
