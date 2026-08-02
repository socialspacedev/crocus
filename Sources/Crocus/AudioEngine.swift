import Foundation
import AVFoundation
import Accelerate
import Combine

/// Hands measured levels from the audio render thread to the UI clock.
///
/// Accumulates energy rather than a running maximum, so draining gives a true
/// time-weighted RMS over the window however many buffers landed in it. The tap
/// delivers on its own schedule — often slower than the UI clock — so a window
/// with no audio in it returns nil, meaning "nothing new", *not* "silence". A
/// reader that treated those as zero would drag the meter down between buffers.
private final class LevelTapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sumSquares: Double = 0
    private var frames: Double = 0

    func submit(meanSquare: Float, frames n: Int) {
        lock.lock()
        sumSquares += Double(meanSquare) * Double(n)
        frames += Double(n)
        lock.unlock()
    }

    /// RMS across everything submitted since the previous call, or nil if no
    /// audio arrived. Resets the accumulator.
    func drain() -> Float? {
        lock.lock()
        defer { sumSquares = 0; frames = 0; lock.unlock() }
        guard frames > 0 else { return nil }
        return Float((sumSquares / frames).squareRoot())
    }
}

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
    /// Real playback position within the file (trim-start + elapsed). Drives the
    /// waveform position line independently of any live trim edits.
    @Published private(set) var playheadAbsolute: TimeInterval = 0
    @Published private(set) var currentSegmentDuration: TimeInterval = 0
    @Published private(set) var groupRemaining: TimeInterval = 0
    @Published private(set) var isCrossfading = false
    /// Currently ramping the music down (or back up) for a voiceover.
    @Published private(set) var isFadingToTalk = false
    /// Holding at the bed level under a voiceover.
    @Published private(set) var isDucked = false
    /// Surfaced to the UI if a file fails to load mid-show, without crashing.
    @Published private(set) var lastError: String?

    /// Output meter, 0...1 on a -50…0 dB scale, already including the Output
    /// fader — what's actually leaving the app. A single mono reading, averaged
    /// the way a VU needle averages, plus a slow peak-hold marker.
    @Published private(set) var meterLevel: Float = 0
    @Published private(set) var meterPeak: Float = 0

    private let engine = AVAudioEngine()
    private let deckA = AVAudioPlayerNode()
    private let deckB = AVAudioPlayerNode()

    /// Per-track loudness-match gains (linear), parallel to `queue`. Applied by
    /// scaling the audio samples at load time (so quiet songs can be boosted).
    private var trackGains: [Float] = []

    /// Called when a group finishes playing naturally (not on manual stop).
    var onGroupFinished: (() -> Void)?
    private var cueNextOnEnd = true

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
    /// The trim start the active audio was actually scheduled from, and the full
    /// duration that was scheduled — used to honour live end-marker edits.
    private var activeSegmentStart: TimeInterval = 0
    private var activeSegmentScheduledDuration: TimeInterval = 0

    private let levelTap = LevelTapBox()
    /// The Output fader, mirrored so the meter can divide it back out — measured:
    /// a tap on the main mixer reads *after* `outputVolume` is applied.
    private var masterGain: Float = 1
    private var meterTarget: Float = 0
    private var peakHoldTicks = 0

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
        installMeterTap()
        engine.prepare()
    }

    /// Watch the post-mix signal so the meter shows both decks, the crossfade and
    /// any voiceover duck — everything except the Output fader, which is folded in
    /// on the UI side.
    ///
    /// Measures RMS across the channels rather than sample peak: peak jumps around
    /// on every snare hit, where RMS is the energy in the buffer — much closer to
    /// what the ear (and a VU needle) actually follows.
    private func installMeterTap() {
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [levelTap] buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frames = vDSP_Length(buffer.frameLength)
            guard frames > 0 else { return }
            let channelCount = max(1, Int(buffer.format.channelCount))
            var sumMeanSquare: Float = 0
            for c in 0..<channelCount {
                var meanSquare: Float = 0
                vDSP_measqv(channels[c], 1, &meanSquare, frames)
                sumMeanSquare += meanSquare
            }
            levelTap.submit(meanSquare: sumMeanSquare / Float(channelCount),
                            frames: Int(buffer.frameLength))
        }
    }

    /// Per-track loudness gain (linear) for a queue index.
    private func gainForIndex(_ i: Int) -> Float {
        (i >= 0 && i < trackGains.count) ? trackGains[i] : 1
    }

    /// Live master output level (0...1), applied on the main mixer.
    func setMasterGain(_ linear: Float) {
        masterGain = max(0.05, min(1, linear))
        engine.mainMixerNode.outputVolume = max(0, min(1, linear))
    }

    // MARK: - Public transport

    func playGroup(_ tracks: [Track], crossfade: TimeInterval,
                   fadeToTalk: TimeInterval, duckLevel: Float, cueNext: Bool = true,
                   gains: [Float] = [], master: Float = 1) {
        guard prepareGroup(tracks, crossfade: crossfade, fadeToTalk: fadeToTalk,
                           duckLevel: duckLevel, cueNext: cueNext,
                           gains: gains, master: master) else { return }
        deckA.play()
        state = .playing
        startTimer()
    }

    /// Load a group's first track but stay paused/cued — ready to play with Space.
    func cueGroup(_ tracks: [Track], crossfade: TimeInterval,
                  fadeToTalk: TimeInterval, duckLevel: Float,
                  gains: [Float] = [], master: Float = 1) {
        guard prepareGroup(tracks, crossfade: crossfade, fadeToTalk: fadeToTalk,
                           duckLevel: duckLevel, cueNext: true,
                           gains: gains, master: master) else { return }
        state = .paused
        startTimer()
    }

    /// Shared setup for play/cue: load the first track on deck A (not yet playing).
    private func prepareGroup(_ tracks: [Track], crossfade: TimeInterval,
                              fadeToTalk: TimeInterval, duckLevel: Float, cueNext: Bool,
                              gains: [Float], master: Float) -> Bool {
        stop()
        queue = tracks
        index = 0
        trackGains = gains
        setMasterGain(master)
        crossfadeDuration = max(0, crossfade)
        fadeToTalkDuration = max(1, fadeToTalk)
        self.duckLevel = min(0.95, max(0.05, duckLevel))
        cueNextOnEnd = cueNext
        guard !queue.isEmpty else { return false }

        ensureRunning()
        activeIsA = true
        deckA.volume = 1
        deckB.volume = 1

        guard let dur = loadSegment(queue[0], on: deckA, gain: gainForIndex(0)) else {
            stop()
            return false
        }
        setActiveSegment(dur: dur, start: queue[0].trimStart)
        currentSegmentDuration = dur
        currentTrack = queue[0]
        upNextTrack = queue.count > 1 ? queue[1] : nil
        groupRemaining = computeGroupRemaining(currentElapsed: 0)
        return true
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
        guard let dur = loadSegment(queue[i], on: activeDeck, gain: gainForIndex(i)) else { stop(); return }
        setActiveSegment(dur: dur, start: queue[i].trimStart)
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
        playheadAbsolute = 0
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
        resetMeters()
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
    private func loadSegment(_ track: Track, on deck: AVAudioPlayerNode, gain: Float = 1) -> TimeInterval? {
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
            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: count)
            else { return nil }

            // Read the trimmed segment into memory so we can scale its samples
            // for loudness matching (a boost > 1 isn't possible via node volume).
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: count)
            if abs(gain - 1) > 0.001, let channels = buffer.floatChannelData {
                let frames = Int(buffer.frameLength)
                for c in 0..<Int(fmt.channelCount) {
                    let p = channels[c]
                    var i = 0
                    while i < frames { p[i] *= gain; i += 1 }
                }
            }

            // Direct deck → mixer (the mixer resamples any file format safely).
            // Only ever reconnects a stopped deck.
            engine.connect(deck, to: engine.mainMixerNode, format: fmt)
            deck.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            return Double(buffer.frameLength) / sr
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
        updateMeters()
        guard state == .playing else { return }
        let e = elapsed(activeDeck)
        currentElapsed = e
        playheadAbsolute = activeSegmentStart + e
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
            if hasNext { hardAdvance() } else { endOfGroup() }
        }
    }

    // MARK: - Output meter

    /// Ease onto the reading and fall away slowly — a needle that swings, not a
    /// bar that strobes. Rise is quicker than fall so the meter still answers a
    /// song coming in, but neither is instant.
    private func updateMeters() {
        // The tap reads post-fader, but the fader is already drawn as the meter's
        // ceiling — so divide it back out and meter the programme itself, or the
        // fader would shorten the bar twice over.
        //
        // No new audio just means the tap hasn't delivered yet (it hands over ~100ms
        // at a time, slower than this clock) — hold the last reading and keep easing
        // toward it, rather than reading the gap as silence.
        if let rms = levelTap.drain() { meterTarget = meterScale(rms / masterGain) }
        if state != .playing { meterTarget = 0 }

        let coefficient: Float = meterTarget > meterLevel ? 0.18 : 0.07
        meterLevel += (meterTarget - meterLevel) * coefficient
        if meterLevel < 0.002 { meterLevel = 0 }

        // Peak marker: re-arm on a new high, sit still for ~1.5s, then slide down.
        if meterLevel >= meterPeak {
            meterPeak = meterLevel
            peakHoldTicks = 50
        } else if peakHoldTicks > 0 {
            peakHoldTicks -= 1
        } else {
            meterPeak = max(meterLevel, meterPeak - 0.008)
        }
    }

    /// RMS amplitude → bar position, on a scale chosen to suit the programme
    /// rather than the theoretical range of the format. The floor is well below
    /// anything you'd broadcast, and the top sits a little above the loudest
    /// material, so a song matched to `LoudnessStore.targetDB` sits about
    /// three-quarters of the way to the fader cap — room to see it move both ways.
    private static let meterFloorDB: Float = -42
    private static let meterTopDB: Float = -12

    private func meterScale(_ amplitude: Float) -> Float {
        guard amplitude > 0.003 else { return 0 }
        let db = 20 * log10(min(1, amplitude))
        let span = Self.meterTopDB - Self.meterFloorDB
        return max(0, min(1, (db - Self.meterFloorDB) / span))
    }

    private func resetMeters() {
        meterLevel = 0
        meterPeak = 0
        meterTarget = 0
        peakHoldTicks = 0
        _ = levelTap.drain()
    }

    /// The group finished playing on its own — go silent, then let AppState cue
    /// the next group (paused). Manual stop does not trigger this.
    private func endOfGroup() {
        let shouldCue = cueNextOnEnd
        stop()
        if shouldCue { onGroupFinished?() }
    }

    private func setActiveSegment(dur: TimeInterval, start: TimeInterval) {
        activeSegmentDuration = dur
        activeSegmentScheduledDuration = dur
        activeSegmentStart = start
        playheadAbsolute = start
    }

    /// Honour an end-marker edit on the currently-playing song without a restart.
    /// Only shortening takes effect live (we can't play past what was scheduled);
    /// a later end / a new start applies the next time the group plays.
    func applyLiveTrim(trackID: UUID, trimStart: TimeInterval, trimEnd: TimeInterval?) {
        guard state != .stopped, var cur = currentTrack, cur.id == trackID else { return }
        let end = trimEnd ?? cur.duration
        let desired = max(0.2, end - activeSegmentStart)
        activeSegmentDuration = min(activeSegmentScheduledDuration, desired)
        cur.trimStart = max(0, trimStart)
        cur.trimEnd = trimEnd
        currentTrack = cur
    }

    /// Reschedule the currently-playing/cued song to honour a new start (and end)
    /// — i.e. jump the audio to the new start marker. Keeps playing if it was
    /// playing, stays cued if it was paused.
    func rescheduleCurrentFromStart(trackID: UUID, trimStart: TimeInterval, trimEnd: TimeInterval?) {
        guard state != .stopped, let cur = currentTrack, cur.id == trackID, index < queue.count
        else { return }
        let wasPlaying = (state == .playing)
        clearDuck()
        idleDeck.stop(); idleDeck.volume = 1
        activeDeck.stop(); activeDeck.volume = 1
        var t = cur
        t.trimStart = max(0, trimStart)
        t.trimEnd = trimEnd
        queue[index] = t
        guard let dur = loadSegment(t, on: activeDeck, gain: gainForIndex(index)) else { stop(); return }
        setActiveSegment(dur: dur, start: t.trimStart)
        currentSegmentDuration = dur
        currentElapsed = 0
        currentTrack = t
        isCrossfading = false
        crossfadeStartElapsed = nil
        if wasPlaying { activeDeck.play() }
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
        guard let dur = loadSegment(next, on: idleDeck, gain: gainForIndex(index + 1)) else { return }
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
        setActiveSegment(dur: idleSegmentDuration, start: queue[index].trimStart)
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
        guard let dur = loadSegment(queue[nextIndex], on: activeDeck, gain: gainForIndex(nextIndex)) else { stop(); return }
        setActiveSegment(dur: dur, start: queue[nextIndex].trimStart)
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
