//
//  AlarmSound.swift
//  cyclingskibidi
//
//  Synthesised alarm tones for the HELP alarm: .playback audio ignores the
//  silent switch, and the audio background mode keeps it ringing when locked.
//

import AVFoundation

@MainActor
final class AlarmSound {
    enum Style {
        case rising, help
    }

    static let shared = AlarmSound()

    private let engine = AVAudioEngine()
    private var playing = false
    private var source: AVAudioSourceNode?
    private var style: Style?
    var isPlaying: Bool { playing }

    private init() {
        // A route change (earbuds in or out) or an interruption (a call) stops the engine;
        // a tone that should still be ringing starts again.
        let center = NotificationCenter.default
        for name in [Notification.Name.AVAudioEngineConfigurationChange, AVAudioSession.interruptionNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AlarmSound.shared.restartIfRinging() }
            }
        }
    }

    private func restartIfRinging() {
        guard let style, !engine.isRunning else { return }
        start(style)
    }

    /// Starting while a tone plays switches to the new one (Are you OK? → HELP).
    func start(_ style: Style) {
        stop()
        self.style = style
        let session = AVAudioSession.sharedInstance()
        do {
            // Mixable (.duckOthers), so it can start while locked with music playing: music
            // ducks, the tone rings. HELP goes to the loudspeaker even with earbuds in, so
            // bystanders hear it. Nothing ever reads the microphone.
            if style == .help {
                try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .duckOthers])
                try session.setActive(true)
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.setCategory(.playback, options: [.duckOthers])
                try session.setActive(true)
            }
        } catch {
            print("AlarmSound: audio session failed: \(error)")
        }

        let format = engine.outputNode.inputFormat(forBus: 0)
        let source = Self.makeSource(style, format: format)
        engine.attach(source)
        self.source = source
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        do {
            try engine.start()
            playing = true
        } catch {
            print("AlarmSound: engine failed: \(error)")
            stop()
            self.style = style   // try again on the next route change or interruption end
        }
    }

    func stop() {
        style = nil
        guard let source else { return }
        engine.stop()
        engine.detach(source)   // one source node at a time, never stacked
        self.source = nil
        playing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The tone's pitch at `t` seconds: what the engine plays and what the check tests.
    nonisolated static func frequency(_ style: Style, at t: Double) -> Double {
        switch style {
        case .rising: 600 + 300 * t.truncatingRemainder(dividingBy: 2)
        case .help: t.truncatingRemainder(dividingBy: 0.5) < 0.25 ? 960 : 1280
        }
    }

    /// Built off the main actor: the render block runs on the audio thread.
    nonisolated private static func makeSource(_ style: Style, format: AVAudioFormat) -> AVAudioSourceNode {
        let channels = format.isInterleaved ? Int(format.channelCount) : 1
        let rate = format.sampleRate
        var phase = 0.0
        var elapsed = 0.0
        return AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                // Accumulate phase: sin(2πft) with a changing f would jump at every change.
                phase += 2 * Double.pi * frequency(style, at: elapsed) / rate
                if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
                elapsed += 1 / rate
                let value = Float(sin(phase) * 0.9)
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let p = data.assumingMemoryBound(to: Float.self)
                    if format.isInterleaved {
                        for channel in 0..<channels { p[frame * channels + channel] = value }
                    } else {
                        p[frame] = value
                    }
                }
            }
            return noErr
        }
    }

    /// Closed form of the waveform, for the pure selfCheck (the engine integrates phase).
    nonisolated static func samples(_ style: Style, at t: Double) -> Float {
        switch style {
        case .help:
            let frequency = t.truncatingRemainder(dividingBy: 0.5) < 0.25 ? 960.0 : 1280.0
            return Float(sin(2 * Double.pi * frequency * t) * 0.9)
        case .rising:
            let u = t.truncatingRemainder(dividingBy: 2)
            return Float(sin(2 * Double.pi * (600 * u + 150 * u * u)) * 0.9)
        }
    }
}

extension AlarmSound {
    /// Pure waveform checks only; the engine is never started here.
    nonisolated static func selfCheck() {
        let rate = 44100.0
        let step = 1.0 / rate

        for i in 0..<Int(rate) {
            let v = samples(.help, at: Double(i) * step)
            assert(v >= -1 && v <= 1, "AlarmSound .help sample outside -1...1 at \(i): \(v)")
        }

        func crossings(_ style: Style, _ start: Double, _ duration: Double) -> Int {
            let steps = Int((duration * rate).rounded())
            var previous = samples(style, at: start)
            var count = 0
            for i in 1..<steps {
                let current = samples(style, at: start + Double(i) * step)
                if (previous < 0) != (current < 0) { count += 1 }
                previous = current
            }
            return count
        }

        let helpLow = crossings(.help, 0, 0.25)
        let helpHigh = crossings(.help, 0.25, 0.25)
        assert(helpLow > 0, "AlarmSound .help must produce a tone before 0.25 s")
        let ratio = Double(helpHigh) / Double(helpLow)
        assert(abs(ratio - 1280.0 / 960.0) < 0.06,
               "AlarmSound .help must change frequency at 0.25 s (ratio \(ratio))")
        // The pitch the engine actually plays.
        assert(frequency(.help, at: 0.1) == 960 && frequency(.help, at: 0.3) == 1280 && frequency(.help, at: 0.6) == 960,
               "HELP alternates 960/1280 Hz every 0.25 s")
        assert(frequency(.rising, at: 0) == 600 && frequency(.rising, at: 1.9) > 1150 && frequency(.rising, at: 2.1) < 650,
               "the rising tone sweeps up over 2 s and repeats")
        assert(crossings(.rising, 1.9, 0.02) > crossings(.rising, 0, 0.02),
               "AlarmSound .rising must sweep upward from 0 to 1.9 s")
    }
}
