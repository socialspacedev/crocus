import Foundation
import AVFoundation
import Combine

/// The core playback engine. Two player nodes ("decks") feed the main mixer,
/// which lets us crossfade between consecutive songs and run a slow manual
/// fade-out, all with sample-accurate, network-free local playback.
@MainActor
final class AudioEngine: ObservableObject {

    enum PlaybackState: Equatable { case stopped, playing, paused }

    // Published state the UI observes.
    @Published private(set) var state: PlaybackState = .stopped
    @Published private(set) var currentTrack: Track?
    @Published private(set) var upNextTrack: Track?
    @Published private(set) var currentElapsed: TimeInterval = 0
    @Published private(set) var currentSegmentDuration: TimeInterval = 0
    @Published private(set) var groupRemaining: TimeInterval = 0
    @Published private(set) var isCrossfading = false
    /// Currently ramping the music down (or back up) for a voiceover.
    @Published private(set) var isFadingToTalk = false
    /// Holding at the bed level under a voiceover.
    @Published private(set) var isDucked = false
    /// Surfaced to the UI if a file fails to load mid-show, without crashing.
    @Published private(set) var lastError: String?

    private let engine = AVAudioEngine()
    private let deckA = AVAudioPlayerNode()
    private let deckB = AVAudioPlayerNode()

    private var queue: [Track] = []
    private var index = 0
    private var crossfadeDuration: TimeInterval = 3
    private var fadeToTalkDuration: TimeInterval = 10
    private var duckLevel: Float = 0.45

    private var activeIsA = true
    private var activeDeck: AVAudioPlayerNode { activeIsA ? deckA : deckB }
    private var idleDeck: AVAudioPlayerNode { activeIsA ? deckB : deckA }

    private var activeSegmentDuration: TimeInterval = 0
    private var idleSegmentDuration: TimeInterval = 0

    private var timer: Timer?
    private var crossfadeStartElapsed: TimeInterval?
    private var fadeStart: Date?
    private var fadeFromVolume: Float = 1
    private var fadeTarget: Float = 1
    private var fadeRampDuration: TimeInterval = 10

    init() {
        engine.attach(deckA)
        engine.attach(deckB)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        engine.connect(deckA, to: engine.mainMixerNode, format: fmt)
        engine.connect(deckB, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
    }

    // MARK: - Public transport

    func playGroup(_ tracks: [Track], crossfade: TimeInterval,
                   fadeToTalk: TimeInterval, duckLevel: Float) {
        stop()
        queue = tracks
        index = 0
        crossfadeDuration = max(0, crossfade)
        fadeToTalkDuration = max(1, fadeToTalk)
        self.duckLevel = min(0.95, max(0.05, duckLevel))
        guard !queue.isEmpty else { return }

        ensureRunning()
        activeIsA = true
        deckA.volume = 1
        deckB.volume = 1

        guard let dur = loadSegment(queue[0], on: deckA) else {
            stop()
            return
        }
        activeSegmentDuration = dur
        deckA.play()
        state = .playing
        currentTrack = queue[0]
        upNextTrack = queue.count > 1 ? queue[1] : nil
        startTimer()
    }

    /// Space-bar action. Resumes/pauses; starting a group is handled by AppState.
    func togglePlayPause() {
        switch state {
        case .playing:
            activeDeck.pause()
            if isCrossfading { idleDeck.pause() }
            state = .paused
        case .paused:
            ensureRunning()
            activeDeck.play()
            if isCrossfading { idleDeck.play() }
            state = .playing
        case .stopped:
            break
        }
    }

    /// Immediately move to the next song in the group (snappy host control).
    func skipSong() {
        guard state != .stopped else { return }
        if index + 1 < queue.count {
            hardAdvance()
        } else {
            stop()
        }
    }

    /// Restart the current song, or (if near its start) jump to the previous one.
    func previousSong() {
        guard state != .stopped else { return }
        if currentElapsed > 2 || index == 0 {
            playIndex(index)
        } else {
            playIndex(index - 1)
        }
    }

    /// Load and play a specific index in the current group on the active deck.
    private func playIndex(_ i: Int) {
        guard i >= 0, i < queue.count else { return }
        clearDuck()
        idleDeck.stop()
        idleDeck.volume = 1
        activeDeck.stop()
        activeDeck.volume = 1
        guard let dur = loadSegment(queue[i], on: activeDeck) else { stop(); return }
        activeSegmentDuration = dur
        activeDeck.play()
        index = i
        state = .playing
        currentTrack = queue[i]
        upNextTrack = i + 1 < queue.count ? queue[i + 1] : nil
        isCrossfading = false
        crossfadeStartElapsed = nil
        if timer == nil { startTimer() }
    }

    /// Toggle "fade to talk": duck the music down to a bed level and hold it there
    /// so you can talk over the song; press again to bring it back up. The duck
    /// time is clamped so it never runs past the end of the current song.
    func startFadeToTalk() {
        guard state == .playing else { return }

        if isDucked || isFadingToTalk {
            // Bring the music back up.
            beginVolumeRamp(to: 1.0, over: 2)
            return
        }

        // Duck down — but never slower than the song has left to play.
        let remaining = max(0, activeSegmentDuration - currentElapsed)
        let dur = min(fadeToTalkDuration, max(1, remaining - 0.3))
        if isCrossfading {
            idleDeck.stop()
            idleDeck.volume = 0
            isCrossfading = false
            crossfadeStartElapsed = nil
        }
        beginVolumeRamp(to: duckLevel, over: dur)
    }

    private func beginVolumeRamp(to target: Float, over duration: TimeInterval) {
        fadeFromVolume = activeDeck.volume
        fadeTarget = target
        fadeRampDuration = max(0.2, duration)
        fadeStart = Date()
        isFadingToTalk = true
        isDucked = false
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        deckA.stop()
        deckB.stop()
        deckA.volume = 1
        deckB.volume = 1
        state = .stopped
        currentTrack = nil
        upNextTrack = nil
        currentElapsed = 0
        currentSegmentDuration = 0
        groupRemaining = 0
        isCrossfading = false
        isFadingToTalk = false
        isDucked = false
        crossfadeStartElapsed = nil
        fadeStart = nil
        fadeTarget = 1
        queue = []
        index = 0
    }

    // MARK: - Engine helpers

    private func ensureRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            lastError = "Audio engine failed to start: \(error.localizedDescription)"
        }
    }

    /// Reconnect the deck to match the file's format, then schedule its trimmed
    /// segment. Returns the segment's play duration, or nil on failure.
    @discardableResult
    private func loadSegment(_ track: Track, on deck: AVAudioPlayerNode) -> TimeInterval? {
        do {
            let file = try AVAudioFile(forReading: track.url)
            let fmt = file.processingFormat
            let sr = fmt.sampleRate
            guard sr > 0 else { return nil }
            let total = file.length
            let startFrame = AVAudioFramePosition((max(0, track.trimStart) * sr).rounded())
            let endSec = track.trimEnd ?? (Double(total) / sr)
            let endFrame = min(total, AVAudioFramePosition((endSec * sr).rounded()))
            let count = AVAudioFrameCount(max(0, endFrame - startFrame))
            guard count > 0 else { return nil }
            // Safe to reconnect at runtime; we only ever reconnect a stopped deck.
            engine.connect(deck, to: engine.mainMixerNode, format: fmt)
            deck.scheduleSegment(file, startingFrame: startFrame,
                                 frameCount: count, at: nil, completionHandler: nil)
            return Double(count) / sr
        } catch {
            lastError = "Couldn't load \(track.url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    private func elapsed(_ deck: AVAudioPlayerNode) -> TimeInterval {
        guard let nodeTime = deck.lastRenderTime,
              let pt = deck.playerTime(forNodeTime: nodeTime),
              pt.sampleRate > 0 else { return currentElapsed }
        return max(0, Double(pt.sampleTime) / pt.sampleRate)
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - The clock (drives crossfade, fade-to-talk, countdown, auto-stop)

    private func tick() {
        guard state == .playing else { return }
        let e = elapsed(activeDeck)
        currentElapsed = e
        currentSegmentDuration = activeSegmentDuration
        groupRemaining = computeGroupRemaining(currentElapsed: e)

        // Fade-to-talk volume ramp (duck down or restore) runs as an overlay,
        // so the song keeps playing and the countdown keeps ticking.
        if isFadingToTalk, let fs = fadeStart {
            let p = min(1, Date().timeIntervalSince(fs) / fadeRampDuration)
            activeDeck.volume = fadeFromVolume + (fadeTarget - fadeFromVolume) * Float(p)
            if p >= 1 {
                isFadingToTalk = false
                isDucked = fadeTarget < 0.99
                fadeStart = nil
            }
        }

        let remaining = activeSegmentDuration - e
        let hasNext = index + 1 < queue.count
        // While ducked/voiceover, don't auto-crossfade into the next song.
        let suppressCrossfade = isFadingToTalk || isDucked

        if isCrossfading {
            guard let cs = crossfadeStartElapsed else { return }
            let p = min(1, (e - cs) / crossfadeDuration)
            activeDeck.volume = Float(cos(p * .pi / 2))   // equal-power out
            idleDeck.volume = Float(sin(p * .pi / 2))     // equal-power in
            if p >= 1 { completeCrossfade() }
        } else if hasNext, crossfadeDuration > 0, remaining <= crossfadeDuration, !suppressCrossfade {
            beginCrossfade()
        } else if remaining <= 0 {
            if hasNext { hardAdvance() } else { stop() }
        }
    }

    /// Reset any voiceover ducking back to full volume (on song change/stop).
    private func clearDuck() {
        isFadingToTalk = false
        isDucked = false
        fadeStart = nil
        fadeTarget = 1
    }

    private func beginCrossfade() {
        let next = queue[index + 1]
        idleDeck.stop()
        idleDeck.volume = 0
        guard let dur = loadSegment(next, on: idleDeck) else { return }
        idleSegmentDuration = dur
        idleDeck.play()
        isCrossfading = true
        crossfadeStartElapsed = elapsed(activeDeck)
    }

    private func completeCrossfade() {
        clearDuck()
        activeDeck.stop()
        activeDeck.volume = 1
        idleDeck.volume = 1
        activeIsA.toggle()
        index += 1
        activeSegmentDuration = idleSegmentDuration
        isCrossfading = false
        crossfadeStartElapsed = nil
        currentTrack = queue[index]
        upNextTrack = index + 1 < queue.count ? queue[index + 1] : nil
    }

    private func hardAdvance() {
        let nextIndex = index + 1
        guard nextIndex < queue.count else { stop(); return }
        clearDuck()
        activeDeck.stop()
        activeDeck.volume = 1
        guard let dur = loadSegment(queue[nextIndex], on: activeDeck) else { stop(); return }
        activeSegmentDuration = dur
        activeDeck.play()
        index = nextIndex
        currentTrack = queue[index]
        upNextTrack = index + 1 < queue.count ? queue[index + 1] : nil
    }

    /// Time until the music stops, accounting for crossfade overlap.
    private func computeGroupRemaining(currentElapsed e: TimeInterval) -> TimeInterval {
        guard !queue.isEmpty, index < queue.count else { return 0 }
        var remaining = max(0, activeSegmentDuration - e)
        var i = index + 1
        while i < queue.count {
            remaining += max(0, queue[i].effectiveDuration - crossfadeDuration)
            i += 1
        }
        return remaining
    }
}
