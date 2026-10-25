import AVFoundation
import Foundation
import os

/// The welcome's soft lofi score, synthesized live: warm pad chords, a Rhodes-like keys line, round bass, dusty
/// drums, vinyl crackle and tape wobble, through a small room reverb. No audio files ship with the app.
/// The last stage is a soft limiter, so the output can never peak above −18 dBFS.
@MainActor
final class PremiereMusic {
    enum Cue: Sendable {
        /// The wordmark finished: a rolled chord blooms.
        case bloom
        /// An import row ticked: one note, climbing the chord.
        case tick(Int)
        case addBass
        case addShuffle
        /// 0…1: how open the tone is (the theme swatches nudge it).
        case warmth(Double)
        /// Welcome home: settle on the home chord and fade out.
        case resolve
    }

    private let synth = LofiSynth(sampleRate: 44_100)
    private var engine: AVAudioEngine?

    init(muted: Bool) { synth.setMuted(muted, ramp: 0) }

    func start() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let synth = synth
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, buffers -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard list.count >= 2, let left = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            synth.render(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }   // no output device: stay silent, never block the welcome
        self.engine = engine
        synth.fadeIn(seconds: 2)
    }

    func cue(_ cue: Cue) { synth.enqueue(cue) }
    func setMuted(_ muted: Bool) { synth.setMuted(muted, ramp: 0.15) }
    func setPaused(_ paused: Bool) { if paused { engine?.pause() } else { try? engine?.start() } }

    func stop(fade: TimeInterval) {
        guard let engine else { return }
        if fade <= 0 { engine.stop(); self.engine = nil; return }
        synth.fadeOut(seconds: fade)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(fade + 0.2))
            engine.stop()
            if self?.engine === engine { self?.engine = nil }
        }
    }

    /// Renders the score without an audio device (smoke checks and `--render-premiere-music`), following the
    /// welcome's cues on a timeline. Returns the level in dBFS.
    static func renderOffline(seconds: Double, to file: URL? = nil) throws -> (peakDBFS: Double, rmsDBFS: Double) {
        let rate = 44_100.0
        let synth = LofiSynth(sampleRate: rate)
        synth.fadeIn(seconds: 2)
        let timeline: [(Double, Cue)] = [(2.6, .bloom), (6, .addBass), (6.4, .tick(0)), (6.7, .tick(1)), (7.0, .tick(2)),
                                         (7.3, .tick(3)), (7.6, .tick(4)), (12, .warmth(0.6)), (16, .addShuffle), (28, .resolve)]
        let total = Int(seconds * rate), block = 512
        var left = [Float](repeating: 0, count: block), right = [Float](repeating: 0, count: block)
        var peak: Float = 0, sumSquares: Double = 0
        let audioFile = try file.map { try AVAudioFile(forWriting: $0, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                                                   AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                                                                                   AVLinearPCMIsFloatKey: true]) }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        var done = 0, nextCue = 0
        while done < total {
            while nextCue < timeline.count, Double(done) / rate >= timeline[nextCue].0 { synth.enqueue(timeline[nextCue].1); nextCue += 1 }
            let frames = min(block, total - done)
            left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
                synth.render(left: l.baseAddress!, right: r.baseAddress!, frames: frames)
            } }
            for i in 0..<frames {
                peak = max(peak, abs(left[i]), abs(right[i]))
                sumSquares += Double(left[i] * left[i] + right[i] * right[i]) / 2
            }
            if let audioFile, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) {
                buffer.frameLength = AVAudioFrameCount(frames)
                for i in 0..<frames { buffer.floatChannelData![0][i] = left[i]; buffer.floatChannelData![1][i] = right[i] }
                try audioFile.write(from: buffer)
            }
            done += frames
        }
        let rms = sqrt(sumSquares / Double(max(total, 1)))
        return (20 * log10(Double(max(peak, 1e-9))), 20 * log10(max(rms, 1e-9)))
    }
}

/// The synthesizer. Rendering happens on the audio thread; cues arrive from the main thread through a small
/// lock that the audio thread only ever tries (it never waits).
final class LofiSynth: @unchecked Sendable {
    private struct Voice {
        enum Kind { case pad, keys, bass, kick, snare, hat }
        var kind: Kind
        var frequency: Double
        var velocity: Double
        var pan: Double
        var age = 0.0                // seconds
        var releaseAge: Double?      // seconds since release began
        var phase = 0.0, phase2 = 0.0, modPhase = 0.0
        var filter = 0.0, filter2 = 0.0
    }

    private let rate: Double
    private var voices: [Voice] = []
    private var time = 0.0
    private var nextEighth = 0.0     // seconds
    private var eighth = 0           // count since start
    private var bassOn = false, drumsOn = false, resolving = false, resolveStarted = false
    private var warmth = 0.3
    private var master = 0.0, masterTarget = 0.0, masterStep = 0.0
    private var mute = 1.0, muteTarget = 1.0, muteStep = 1.0
    private var noiseState: UInt32 = 0x9E3779B9
    private var crackle = 0.0, hiss = 0.0
    private var lowpass = (0.0, 0.0, 0.0, 0.0)
    private var reverb = Reverb()
    /// Everything the main thread asks for, applied by the audio thread at the start of its next block.
    private enum Control: Sendable { case cue(PremiereMusic.Cue), fade(target: Double, seconds: Double), mute(Bool, ramp: Double) }
    private let lock = OSAllocatedUnfairLock<[Control]>(initialState: [])

    // 72 BPM, swung eighths. D♭maj9 → B♭m9 → G♭maj7(add9) → A♭7sus4, a bar each.
    private static let beat = 60.0 / 72.0
    private static let chords: [[Int]] = [[53, 56, 60, 63, 65], [53, 56, 60, 61, 65], [53, 56, 58, 61, 65], [54, 56, 58, 61, 63]]
    private static let roots: [Int] = [37, 34, 30, 32]
    private static let home = 0

    init(sampleRate: Double) {
        rate = sampleRate
        voices.reserveCapacity(64)
        nextEighth = 0.15
    }

    func enqueue(_ cue: PremiereMusic.Cue) { lock.withLock { $0.append(.cue(cue)) } }
    func fadeIn(seconds: Double) { lock.withLock { $0.append(.fade(target: 1, seconds: seconds)) } }
    func fadeOut(seconds: Double) { lock.withLock { $0.append(.fade(target: 0, seconds: seconds)) } }
    func setMuted(_ muted: Bool, ramp: Double) { lock.withLock { $0.append(.mute(muted, ramp: ramp)) } }

    private func apply(_ control: Control) {
        switch control {
        case .cue(let cue): apply(cue)
        case .fade(let target, let seconds):
            masterTarget = target
            masterStep = 1 / max(seconds * rate, 1)
        case .mute(let muted, let ramp):
            muteTarget = muted ? 0 : 1
            muteStep = ramp <= 0 ? 1 : 1 / (ramp * rate)
            if ramp <= 0 { mute = muteTarget }
        }
    }

    private static func hz(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    private func play(_ kind: Voice.Kind, _ midi: Int, velocity: Double, pan: Double = 0, delay: Double = 0) {
        guard voices.count < 60 else { return }
        var voice = Voice(kind: kind, frequency: Self.hz(midi), velocity: velocity, pan: pan)
        voice.age = -delay
        voices.append(voice)
    }

    private func drum(_ kind: Voice.Kind, velocity: Double) {
        guard voices.count < 60 else { return }
        voices.append(Voice(kind: kind, frequency: kind == .kick ? 110 : 190, velocity: velocity, pan: kind == .hat ? 0.25 : 0))
    }

    private func chord(at bar: Int) -> Int { resolving ? Self.home : bar % 4 }

    private func apply(_ cue: PremiereMusic.Cue) {
        let current = chord(at: eighth / 8)
        switch cue {
        case .bloom:
            for (i, note) in Self.chords[current].enumerated() { play(.keys, note + 12, velocity: 0.55, pan: Double(i - 2) * 0.15, delay: Double(i) * 0.045) }
        case .tick(let n):
            let tones = Self.chords[current]
            play(.keys, tones[n % tones.count] + 24 + 12 * (n / tones.count), velocity: 0.32, pan: 0.2)
        case .addBass: bassOn = true
        case .addShuffle: drumsOn = true
        case .warmth(let value): warmth = min(max(value, 0), 1)
        case .resolve:
            resolving = true
            for index in voices.indices where voices[index].releaseAge == nil && voices[index].kind == .pad { voices[index].releaseAge = 0 }
            for note in Self.chords[Self.home] { play(.pad, note, velocity: 0.5) }
            for (i, note) in Self.chords[Self.home].enumerated() { play(.keys, note + 12, velocity: 0.5, pan: Double(i - 2) * 0.15, delay: Double(i) * 0.06) }
            play(.bass, Self.roots[Self.home], velocity: 0.6)
        }
    }

    /// One swung eighth of the groove.
    private func step() {
        let position = eighth % 8, bar = eighth / 8, harmony = chord(at: bar)
        let tones = Self.chords[harmony]
        if !resolving {
            if position == 0 {
                for index in voices.indices where voices[index].kind == .pad && voices[index].releaseAge == nil { voices[index].releaseAge = 0 }
                for note in tones.prefix(4) { play(.pad, note, velocity: 0.42) }
                for (i, note) in tones.suffix(3).enumerated() { play(.keys, note, velocity: 0.34, pan: -0.15 + Double(i) * 0.15, delay: Double(i) * 0.018) }
                if bassOn { play(.bass, Self.roots[harmony], velocity: 0.6) }
            }
            if position == 3 { for note in tones.suffix(2) { play(.keys, note, velocity: 0.22, pan: 0.1) } }
            if position == 5, bassOn { play(.bass, Self.roots[harmony] + (bar % 2 == 0 ? 0 : 7), velocity: 0.45) }
            if position == 6 { play(.keys, tones.last! + 12, velocity: 0.18, pan: 0.25) }
            if position == 7, bar % 2 == 1 { play(.keys, tones[1] + 24, velocity: 0.14, pan: -0.25) }
            if drumsOn {
                if position == 0 || position == 4 { drum(.kick, velocity: 0.55) }
                if position == 2 || position == 6 { drum(.snare, velocity: 0.22) }
                drum(.hat, velocity: position % 2 == 0 ? 0.09 : 0.055)
            }
        }
        eighth += 1
        // Swing: the off-beat eighth lands at 60% of the beat.
        nextEighth += Self.beat * (position % 2 == 0 ? 0.6 : 0.4)
    }

    private func noise() -> Double {
        noiseState ^= noiseState << 13; noiseState ^= noiseState >> 17; noiseState ^= noiseState << 5
        return Double(noiseState) / Double(UInt32.max) * 2 - 1
    }

    /// PolyBLEP saw, so the pad stays smooth instead of buzzy.
    private static func saw(_ phase: Double, _ increment: Double) -> Double {
        var value = 2 * phase - 1
        if phase < increment { let t = phase / increment; value -= t + t - t * t - 1 }
        else if phase > 1 - increment { let t = (phase - 1) / increment; value -= t * t + t + t + 1 }
        return value
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        if let controls = lock.withLockIfAvailable({ state -> [Control] in let pending = state; state.removeAll(); return pending }) {
            for control in controls { apply(control) }
        }
        let dt = 1 / rate
        let tau = 2 * Double.pi
        for frame in 0..<frames {
            if !resolving || !resolveStarted { while time >= nextEighth { step(); if resolving { resolveStarted = true; break } } }
            let wobble = 1 + 0.0023 * sin(tau * 0.3 * time)
            var bodyL = 0.0, bodyR = 0.0, lowL = 0.0, lowR = 0.0
            var index = 0
            while index < voices.count {
                var voice = voices[index]
                voice.age += dt
                if voice.age < 0 { voices[index] = voice; index += 1; continue }
                if voice.releaseAge != nil { voice.releaseAge! += dt }
                var sample = 0.0, finished = false
                let frequency = voice.frequency * wobble
                switch voice.kind {
                case .pad:
                    let attack = min(voice.age / 1.3, 1)
                    let release = voice.releaseAge.map { exp(-$0 / 0.9) } ?? 1
                    let increment = frequency * dt, detuned = frequency * 1.004 * dt
                    voice.phase = (voice.phase + increment).truncatingRemainder(dividingBy: 1)
                    voice.phase2 = (voice.phase2 + detuned).truncatingRemainder(dividingBy: 1)
                    let raw = (Self.saw(voice.phase, increment) + Self.saw(voice.phase2, detuned)) * 0.5
                    // Two one-pole low-passes: soft and dark.
                    let cutoff = 1 - exp(-tau * (650 + 900 * warmth) * dt)
                    voice.filter += cutoff * (raw - voice.filter)
                    voice.filter2 += cutoff * (voice.filter - voice.filter2)
                    sample = voice.filter2 * attack * release * voice.velocity * 0.22
                    finished = release < 0.0005
                case .keys:
                    // Two-operator FM: a Rhodes-like bell that mellows as it rings.
                    let index = 0.15 + 1.25 * exp(-voice.age / 0.22)
                    voice.modPhase = (voice.modPhase + frequency * dt).truncatingRemainder(dividingBy: 1)
                    voice.phase = (voice.phase + frequency * dt).truncatingRemainder(dividingBy: 1)
                    let tine = 0.06 * exp(-voice.age / 0.025) * sin(tau * voice.phase * 7)
                    let envelope = min(voice.age / 0.004, 1) * exp(-voice.age / 1.5)
                    sample = (sin(tau * voice.phase + index * sin(tau * voice.modPhase)) + tine) * envelope * voice.velocity * 0.3
                    finished = envelope < 0.0005 && voice.age > 0.05
                case .bass:
                    voice.phase = (voice.phase + frequency * dt).truncatingRemainder(dividingBy: 1)
                    let envelope = min(voice.age / 0.01, 1) * exp(-voice.age / 0.9)
                    sample = (sin(tau * voice.phase) + 0.2 * sin(2 * tau * voice.phase)) * envelope * voice.velocity * 0.5
                    finished = envelope < 0.0005 && voice.age > 0.05
                case .kick:
                    let sweep = 48 + 62 * exp(-voice.age / 0.035)
                    voice.phase = (voice.phase + sweep * dt).truncatingRemainder(dividingBy: 1)
                    let envelope = exp(-voice.age / 0.22)
                    sample = sin(tau * voice.phase) * envelope * voice.velocity * 0.6
                    finished = envelope < 0.0005
                case .snare:
                    voice.phase = (voice.phase + 190 * dt).truncatingRemainder(dividingBy: 1)
                    let n = noise()
                    voice.filter += 0.35 * (n - voice.filter)            // keep the body, lose the fizz
                    let envelope = exp(-voice.age / 0.11)
                    sample = (voice.filter * 0.8 + sin(tau * voice.phase) * exp(-voice.age / 0.04) * 0.5) * envelope * voice.velocity
                    finished = envelope < 0.0005
                case .hat:
                    let n = noise()
                    voice.filter += 0.6 * (n - voice.filter)
                    let envelope = exp(-voice.age / 0.03)
                    sample = (n - voice.filter) * envelope * voice.velocity
                    finished = envelope < 0.0005
                }
                let leftGain = 0.5 - voice.pan * 0.5 + 0.5, rightGain = 0.5 + voice.pan * 0.5 + 0.5
                if voice.kind == .bass || voice.kind == .kick { lowL += sample; lowR += sample }
                else { bodyL += sample * leftGain * 0.5; bodyR += sample * rightGain * 0.5 }
                if finished { voices.swapAt(index, voices.count - 1); voices.removeLast() } else { voices[index] = voice; index += 1 }
            }
            // Keys breathe a little (tremolo) — applied to the body bus only.
            let tremolo = 1 - 0.08 * (0.5 + 0.5 * sin(tau * 4.6 * time))
            bodyL *= tremolo; bodyR *= tremolo
            // Warm, slightly dark tone on everything but the lows.
            let tone = 1 - exp(-tau * (2_400 + 3_000 * warmth) * dt)
            lowpass.0 += tone * (bodyL - lowpass.0); lowpass.1 += tone * (lowpass.0 - lowpass.1)
            lowpass.2 += tone * (bodyR - lowpass.2); lowpass.3 += tone * (lowpass.2 - lowpass.3)
            // Vinyl: sparse soft pops and a whisper of hiss.
            if noise() > 0.99965 { crackle = 0.04 + 0.05 * abs(noise()) }
            crackle *= 0.985
            hiss += 0.05 * (noise() * 0.006 - hiss)
            let dryL = lowpass.1 + lowL + crackle + hiss, dryR = lowpass.3 + lowR + crackle * 0.8 + hiss
            let (wetL, wetR) = reverb.process(dryL * 0.5 + dryR * 0.5)
            let mixL = dryL + wetL * 0.32, mixR = dryR + wetR * 0.32

            if master < masterTarget { master = min(masterTarget, master + masterStep) } else if master > masterTarget { master = max(masterTarget, master - masterStep) }
            if mute < muteTarget { mute = min(muteTarget, mute + muteStep) } else if mute > muteTarget { mute = max(muteTarget, mute - muteStep) }
            // The ceiling: tanh never exceeds 1, so the output never exceeds 0.125 (−18 dBFS).
            let gain = 0.125 * master * mute
            left[frame] = Float(gain * tanh(mixL * 1.8))
            right[frame] = Float(gain * tanh(mixR * 1.8))
            time += dt
        }
    }
}

/// A small Freeverb-style room: four damped combs into two all-passes per side.
private struct Reverb {
    private struct Comb { var buffer: [Double]; var index = 0; var store = 0.0
        mutating func process(_ input: Double) -> Double {
            let output = buffer[index]
            store = output * 0.7 + store * 0.3
            buffer[index] = input + store * 0.8
            index = (index + 1) % buffer.count
            return output
        }
    }
    private struct AllPass { var buffer: [Double]; var index = 0
        mutating func process(_ input: Double) -> Double {
            let delayed = buffer[index]
            buffer[index] = input + delayed * 0.5
            index = (index + 1) % buffer.count
            return delayed - input
        }
    }
    private var combsL = [1116, 1188, 1277, 1356].map { Comb(buffer: Array(repeating: 0, count: $0)) }
    private var combsR = [1139, 1211, 1300, 1379].map { Comb(buffer: Array(repeating: 0, count: $0)) }
    private var passL = [556, 441].map { AllPass(buffer: Array(repeating: 0, count: $0)) }
    private var passR = [579, 464].map { AllPass(buffer: Array(repeating: 0, count: $0)) }

    mutating func process(_ input: Double) -> (Double, Double) {
        var left = 0.0, right = 0.0
        for i in 0..<4 { left += combsL[i].process(input * 0.25); right += combsR[i].process(input * 0.25) }
        for i in 0..<2 { left = passL[i].process(left); right = passR[i].process(right) }
        return (left, right)
    }
}
