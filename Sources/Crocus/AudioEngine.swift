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
    /// Taking the current song out early, by hand (see `fadeOutCurrent`).
    @Published private(set) var isFadingOut = false
    /// Reading a song in. Brief for a normal track, a couple of seconds for a
    /// long one — the app stays responsive throughout either way.
    @Published private(set) var isLoading = false
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

    /// How long the crossfade or early fade currently running takes: the show's
    /// crossfade for an automatic one, `manualFadeDuration` for an early fade.
    private var activeFadeDuration: TimeInterval = 3
    /// The volume the outgoing deck sat at when that fade began. Normally 1, but
    /// an early fade started under a voiceover ramps down from the bed level
    /// rather than jumping back up to full first.
    private var outgoingFromVolume: Float = 1
    private var fadeOutStartElapsed: TimeInterval = 0

    /// The next song, decoded ahead of time, plus the queue index it belongs to.
    private var preroll: DecodedSegment?
    private var prerollIndex: Int?
    private var prerollTask: Task<Void, Never>?
    /// Bumped whenever the queue is replaced, so a decode that finishes against
    /// the old queue can be recognised and thrown away.
    private var queueGeneration = 0
    /// Whether the segment currently being read should start playing when it
    /// arrives — Space pressed mid-load flips this rather than being ignored.
    private var pendingAutoPlay = false

    /// How long a manual Fade Out takes. Its own setting rather than the
    /// crossfade: quick automatic transitions and a long deliberate ride down
    /// are different jobs. Live-settable, so it can be dialled in mid-song —
    /// the decision to end a song early is often made in the moment.
    private var manualFadeDuration: TimeInterval = 10

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

    /// Live Fade Out length, in seconds. Takes effect on the next press of Fade
    /// Out — including one made later in the song that's playing right now.
    func setFadeOutDuration(_ seconds: TimeInterval) {
        manualFadeDuration = max(1, seconds)
    }

    /// Live master output level (0...1), applied on the main mixer.
    func setMasterGain(_ linear: Float) {
        masterGain = max(0.05, min(1, linear))
        engine.mainMixerNode.outputVolume = max(0, min(1, linear))
    }

    // MARK: - Public transport

    func playGroup(_ tracks: [Track], crossfade: TimeInterval,
                   fadeToTalk: TimeInterval, duckLevel: Float, fadeOut: TimeInterval,
                   cueNext: Bool = true, gains: [Float] = [], master: Float = 1) {
        beginGroup(tracks, crossfade: crossfade, fadeToTalk: fadeToTalk,
                   duckLevel: duckLevel, fadeOut: fadeOut, cueNext: cueNext,
                   gains: gains, master: master, startPlaying: true)
    }

    /// Load a group's first track but stay paused/cued — ready to play with Space.
    func cueGroup(_ tracks: [Track], crossfade: TimeInterval,
                  fadeToTalk: TimeInterval, duckLevel: Float, fadeOut: TimeInterval,
                  gains: [Float] = [], master: Float = 1) {
        beginGroup(tracks, crossfade: crossfade, fadeToTalk: fadeToTalk,
                   duckLevel: duckLevel, fadeOut: fadeOut, cueNext: true,
                   gains: gains, master: master, startPlaying: false)
    }

    /// Shared setup for play/cue. The first song is read in asynchronously, so
    /// this returns immediately and the music starts when the audio lands.
    private func beginGroup(_ tracks: [Track], crossfade: TimeInterval,
                            fadeToTalk: TimeInterval, duckLevel: Float,
                            fadeOut: TimeInterval, cueNext: Bool,
                            gains: [Float], master: Float, startPlaying: Bool) {
        stop()
        queue = tracks
        trackGains = gains
        setMasterGain(master)
        crossfadeDuration = max(0, crossfade)
        fadeToTalkDuration = max(1, fadeToTalk)
        manualFadeDuration = max(1, fadeOut)
        self.duckLevel = min(0.95, max(0.05, duckLevel))
        cueNextOnEnd = cueNext
        guard !queue.isEmpty else { return }

        ensureRunning()
        activeIsA = true
        deckA.volume = 1
        deckB.volume = 1
        loadActive(0, autoPlay: startPlaying)
    }

    /// Space-bar action. Resumes/pauses; starting a group is handled by AppState.
    func togglePlayPause() {
        // Mid-load there is no audio to start yet, so record the intent instead
        // of dropping the keypress: the segment goes straight on air (or stays
        // cued) the moment it arrives.
        if isLoading {
            pendingAutoPlay.toggle()
            state = pendingAutoPlay ? .playing : .paused
            return
        }
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
        loadActive(i, autoPlay: true)
    }

    /// Toggle "fade to talk": duck the music down to a bed level and hold it there
    /// so you can talk over the song; press again to bring it back up. The duck
    /// time is clamped so it never runs past the end of the current song.
    func startFadeToTalk() {
        // An early fade is already driving the active deck's volume — leave it
        // alone rather than have two ramps fight over the same fader.
        guard state == .playing, !isFadingOut else { return }

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

    /// Take the current song out early — for when it's running long and no end
    /// marker was set. With another song still in the group this is simply the
    /// normal crossfade brought forward, so the next song comes up underneath
    /// as usual. On the last song the music fades to silence and the group ends
    /// exactly as if it had run out, so the next group still cues up behind it.
    ///
    /// Ignored if a crossfade or an earlier fade is already running — the song
    /// is on its way out either way, and a second ramp would only fight the first.
    func fadeOutCurrent() {
        guard state == .playing, !isCrossfading, !isFadingOut else { return }
        let dur = manualFadeDuration
        let e = elapsed(activeDeck)
        let from = activeDeck.volume     // may be the bed level, if ducked
        clearVolumeOverlays()

        if index + 1 < queue.count {
            guard beginCrossfade(over: dur, from: from, at: e) else { return }
        } else {
            isFadingOut = true
            fadeOutStartElapsed = e
            activeFadeDuration = dur
            outgoingFromVolume = from
        }

        // Bring the segment's end forward to where the fade lands, so the big
        // countdown tells the truth from the moment you press it — and so the
        // last song's group ends on its own, through the usual path.
        activeSegmentDuration = min(activeSegmentDuration, e + dur)
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
        // Any decode still in flight belongs to a queue that no longer exists.
        queueGeneration &+= 1
        prerollTask?.cancel()
        prerollTask = nil
        preroll = nil
        prerollIndex = nil
        pendingAutoPlay = false
        isLoading = false
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
        isFadingOut = false
        crossfadeStartElapsed = nil
        fadeStart = nil
        fadeTarget = 1
        outgoingFromVolume = 1
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

    // MARK: - Decoding a segment
    //
    // Decoding is kept separate from scheduling. A trimmed segment is read whole
    // into memory so its samples can be scaled for loudness matching (a boost
    // above 1 isn't reachable through node volume) — and for a long track that
    // read is slow: ~3s for a 29-minute mp3, which is also ~600MB. Done on the
    // main actor it froze the entire app, so `decodeSegment` is nonisolated and
    // runs off it.

    /// A decoded, gain-scaled segment, ready to hand to a deck.
    private struct DecodedSegment: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let format: AVAudioFormat
        let duration: TimeInterval
        /// What this actually is, so a decode that lands after the queue has
        /// moved on can be spotted as stale and dropped.
        let trackID: UUID
        let trimStart: TimeInterval
        let trimEnd: TimeInterval?
    }

    private enum DecodeOutcome {
        case ok(DecodedSegment)
        case failed(String)
    }

    /// Read a track's trimmed segment into memory and scale it for loudness
    /// match. Pure file work, touching no engine state, so it is safe to run off
    /// the main actor — which is the entire point of it being nonisolated.
    private nonisolated static func decodeSegment(_ track: Track, gain: Float) -> DecodeOutcome {
        let name = track.url.lastPathComponent
        do {
            let file = try AVAudioFile(forReading: track.url)
            let fmt = file.processingFormat
            let sr = fmt.sampleRate
            guard sr > 0 else { return .failed("Couldn't read \(name): no sample rate") }
            let total = file.length
            let startFrame = AVAudioFramePosition((max(0, track.trimStart) * sr).rounded())
            let endSec = track.trimEnd ?? (Double(total) / sr)
            let endFrame = min(total, AVAudioFramePosition((endSec * sr).rounded()))
            let count = AVAudioFrameCount(max(0, endFrame - startFrame))
            guard count > 0 else { return .failed("Nothing left to play in \(name) after its trim") }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: count) else {
                // Long songs are big — half an hour of 44.1kHz stereo is ~600MB.
                // Say so; this used to fail silently and simply not play.
                return .failed("Not enough memory to load \(name)")
            }

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
            return .ok(DecodedSegment(buffer: buffer, format: fmt,
                                      duration: Double(buffer.frameLength) / sr,
                                      trackID: track.id,
                                      trimStart: track.trimStart, trimEnd: track.trimEnd))
        } catch {
            return .failed("Couldn't load \(name): \(error.localizedDescription)")
        }
    }

    /// Hand a decoded segment to a deck. Direct deck → mixer (the mixer resamples
    /// any file format safely); only ever reconnects a stopped deck.
    private func schedule(_ seg: DecodedSegment, on deck: AVAudioPlayerNode) {
        engine.connect(deck, to: engine.mainMixerNode, format: seg.format)
        deck.scheduleBuffer(seg.buffer, at: nil, options: [], completionHandler: nil)
    }

    /// Decode right now, on the main actor. The fallback for the rare moments
    /// audio is needed immediately and no pre-roll is ready — a skip or a manual
    /// Fade Out taken seconds after the song began. Blocks; see `decodeSegment`.
    private func decodeNow(_ i: Int) -> DecodedSegment? {
        guard i >= 0, i < queue.count else { return nil }
        switch AudioEngine.decodeSegment(queue[i], gain: gainForIndex(i)) {
        case .ok(let seg): return seg
        case .failed(let msg): lastError = msg; return nil
        }
    }

    // MARK: - Pre-roll
    //
    // The next song is decoded as soon as the current one starts, so its audio is
    // already in memory by the time the crossfade is due. Without this a long
    // track's read happened *inside* the crossfade window and overran it, so the
    // ramp was already complete when the app came back — a hard cut, not a fade.

    /// Begin decoding queue[i] in the background, discarding any earlier pre-roll.
    private func startPreroll(for i: Int) {
        prerollTask?.cancel()
        prerollTask = nil
        preroll = nil
        prerollIndex = nil
        guard i >= 0, i < queue.count else { return }
        let track = queue[i]
        let gain = gainForIndex(i)
        let generation = queueGeneration
        prerollIndex = i
        prerollTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = AudioEngine.decodeSegment(track, gain: gain)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.acceptPreroll(outcome, for: i, trackID: track.id, generation: generation)
            }
        }
    }

    private func acceptPreroll(_ outcome: DecodeOutcome, for i: Int,
                               trackID: UUID, generation: Int) {
        // Drop anything that finished after the queue moved on beneath it.
        guard generation == queueGeneration, prerollIndex == i,
              i < queue.count, queue[i].id == trackID else { return }
        switch outcome {
        case .ok(let seg): preroll = seg
        case .failed(let msg): preroll = nil; lastError = msg
        }
    }

    /// Claim the pre-rolled segment for `i`, if one is ready and still matches
    /// what the queue says should play there.
    private func takePreroll(for i: Int) -> DecodedSegment? {
        guard let seg = preroll, prerollIndex == i, i < queue.count,
              queue[i].id == seg.trackID,
              queue[i].trimStart == seg.trimStart,
              queue[i].trimEnd == seg.trimEnd else { return nil }
        preroll = nil
        prerollIndex = nil
        return seg
    }

    // MARK: - Putting a song on the active deck

    /// Load queue[i] onto the active deck without blocking: the app stays live
    /// while the file is read, and playback begins when it lands. `autoPlay` says
    /// whether it should go straight on air or sit cued.
    private func loadActive(_ i: Int, autoPlay: Bool) {
        guard i >= 0, i < queue.count else { stop(); return }
        clearVolumeOverlays()
        idleDeck.stop(); idleDeck.volume = 1
        activeDeck.stop(); activeDeck.volume = 1
        isCrossfading = false
        crossfadeStartElapsed = nil

        index = i
        currentTrack = queue[i]
        upNextTrack = i + 1 < queue.count ? queue[i + 1] : nil
        currentElapsed = 0
        pendingAutoPlay = autoPlay
        state = autoPlay ? .playing : .paused

        // Already decoded ahead of time? Then there is nothing to wait for.
        if let seg = takePreroll(for: i) {
            activate(seg, at: i)
            return
        }

        isLoading = true
        let track = queue[i]
        let gain = gainForIndex(i)
        let generation = queueGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = AudioEngine.decodeSegment(track, gain: gain)
            guard let self else { return }
            await MainActor.run {
                guard generation == self.queueGeneration, self.index == i,
                      i < self.queue.count, self.queue[i].id == track.id else { return }
                switch outcome {
                case .ok(let seg):
                    self.activate(seg, at: i)
                case .failed(let msg):
                    self.lastError = msg
                    self.stop()
                }
            }
        }
    }

    /// Put a decoded segment on air: schedule it, adopt its timings, start it if
    /// the transport is meant to be running, and pre-roll whatever follows.
    private func activate(_ seg: DecodedSegment, at i: Int) {
        isLoading = false
        schedule(seg, on: activeDeck)
        setActiveSegment(dur: seg.duration, start: seg.trimStart)
        currentSegmentDuration = seg.duration
        groupRemaining = computeGroupRemaining(currentElapsed: 0)
        if pendingAutoPlay {
            ensureRunning()
            activeDeck.play()
            state = .playing
        }
        if timer == nil { startTimer() }
        startPreroll(for: i + 1)
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
        // While a segment is still being read there are no timings to act on —
        // and a zero-length segment would otherwise read as "already finished".
        guard state == .playing, !isLoading else { return }
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
            let p = min(1, (e - cs) / activeFadeDuration)
            activeDeck.volume = outgoingFromVolume * Float(cos(p * .pi / 2))  // equal-power out
            idleDeck.volume = Float(sin(p * .pi / 2))                         // equal-power in
            if p >= 1 { completeCrossfade() }
        } else if isFadingOut {
            // Last song taken out by hand: the same equal-power curve, with
            // nothing coming up underneath. The segment end was pulled forward
            // to meet it, so `remaining` lands on zero at the same moment.
            let p = min(1, (e - fadeOutStartElapsed) / activeFadeDuration)
            activeDeck.volume = outgoingFromVolume * Float(cos(p * .pi / 2))
            if p >= 1 || remaining <= 0 { endOfGroup() }
        } else if remaining <= 0 {
            // Checked before the crossfade window, not after: if a crossfade
            // couldn't start (see `beginCrossfade`), the song must still end
            // rather than sit here retrying against a deck that has run dry.
            if hasNext { hardAdvance() } else { endOfGroup() }
        } else if hasNext, crossfadeDuration > 0, remaining <= crossfadeDuration, !suppressCrossfade {
            beginCrossfade()
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
        var t = cur
        t.trimStart = max(0, trimStart)
        t.trimEnd = trimEnd
        queue[index] = t
        loadActive(index, autoPlay: wasPlaying)
    }

    /// Drop every ramp that was riding on top of the active deck's volume —
    /// a voiceover duck, or an early fade-out. Called wherever we take the deck
    /// over ourselves (song change, reschedule, stop), so a stale ramp can't
    /// keep writing to a fader that now belongs to a different song.
    private func clearVolumeOverlays() {
        isFadingToTalk = false
        isDucked = false
        isFadingOut = false
        fadeStart = nil
        fadeTarget = 1
    }

    /// The automatic crossfade at the tail of a song: full volume, the show's
    /// crossfade length, starting now.
    ///
    /// Pre-roll only. If the next song somehow isn't decoded yet — a song shorter
    /// than its own read time — this does nothing and `tick` simply tries again
    /// next time round, so the crossfade starts late rather than the app hanging
    /// on a disk read mid-show. If it never becomes ready the end-of-song check
    /// picks it up and advances instead.
    private func beginCrossfade() {
        _ = beginCrossfade(over: crossfadeDuration, from: 1,
                           at: elapsed(activeDeck), prerollOnly: true)
    }

    /// Bring the next song up under the current one. `from` is the volume the
    /// outgoing deck starts at, so an early fade triggered under a voiceover
    /// ramps down from the bed level instead of jumping to full first.
    /// Returns false if the next song's audio wasn't available.
    @discardableResult
    private func beginCrossfade(over duration: TimeInterval, from: Float,
                                at startElapsed: TimeInterval,
                                prerollOnly: Bool = false) -> Bool {
        let nextIndex = index + 1
        guard nextIndex < queue.count else { return false }
        guard let seg = takePreroll(for: nextIndex) ?? (prerollOnly ? nil : decodeNow(nextIndex))
        else { return false }
        idleDeck.stop()
        idleDeck.volume = 0
        schedule(seg, on: idleDeck)
        idleSegmentDuration = seg.duration
        idleDeck.play()
        isCrossfading = true
        activeFadeDuration = max(0.05, duration)
        outgoingFromVolume = from
        crossfadeStartElapsed = startElapsed
        return true
    }

    private func completeCrossfade() {
        clearVolumeOverlays()
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
        startPreroll(for: index + 1)
    }

    private func hardAdvance() {
        let nextIndex = index + 1
        guard nextIndex < queue.count else { stop(); return }
        let wasPlaying = (state == .playing)
        clearVolumeOverlays()
        activeDeck.stop()
        activeDeck.volume = 1
        // Pre-rolled in all but the freak case; decode inline only if it isn't
        // ready, where a gap of silence would be the worse of the two.
        guard let seg = takePreroll(for: nextIndex) ?? decodeNow(nextIndex) else { stop(); return }
        index = nextIndex
        currentTrack = queue[index]
        upNextTrack = index + 1 < queue.count ? queue[index + 1] : nil
        pendingAutoPlay = wasPlaying
        activate(seg, at: index)
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
