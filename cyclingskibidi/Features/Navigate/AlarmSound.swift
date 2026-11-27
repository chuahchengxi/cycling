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
    var isPlaying: Bool { playing }

    /// Starting while a tone plays switches to the new one (Are you OK? → HELP).
    func start(_ style: Style) {
        stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [])
        try? session.setActive(true)

        let format = engine.outputNode.inputFormat(forBus: 0)
        let channels = format.isInterleaved ? Int(format.channelCount) : 1
        var phase = 0.0
        var elapsed = 0.0
        let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let rate = format.sampleRate
            for frame in 0..<Int(frameCount) {
                let frequency: Double
                switch style {
                case .rising:
                    frequency = 600 + 300 * elapsed.truncatingRemainder(dividingBy: 2)
                case .help:
                    frequency = elapsed.truncatingRemainder(dividingBy: 0.5) < 0.25 ? 960 : 1280
                }
                // Accumulate phase: sin(2πft) with a changing f would jump at every change.
                phase += 2 * Double.pi * frequency / rate
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
        engine.attach(source)
        self.source = source
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        do {
            try engine.start()
            playing = true
        } catch {
            stop()
        }
    }

    func stop() {
        guard let source else { return }
        engine.stop()
        engine.detach(source)   // one source node at a time, never stacked
        self.source = nil
        playing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        assert(crossings(.rising, 1.9, 0.02) > crossings(.rising, 0, 0.02),
               "AlarmSound .rising must sweep upward from 0 to 1.9 s")
    }
}
