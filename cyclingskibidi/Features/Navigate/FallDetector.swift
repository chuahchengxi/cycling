//
//  FallDetector.swift
//  cyclingskibidi
//
//  Pure fall detection from motion samples: impact + tumble + a long stillness.
//  No CoreMotion here — the caller feeds already-reduced magnitudes.
//

nonisolated enum FallSensitivity: String, Codable, CaseIterable {
    case off, low, normal, high

    // ponytail: calibration constants — impact/tumble thresholds to tune on real rides.
    var impactG: Double {
        switch self {
        case .off: return .infinity
        case .low: return 4.0
        case .normal: return 3.5
        case .high: return 3.0
        }
    }

    var tumbleRadPerSec: Double {
        switch self {
        case .off: return .infinity
        case .low: return 6
        case .normal: return 5
        case .high: return 4
        }
    }
}

nonisolated struct MotionSample {
    let t: Double
    let accelG: Double   // |userAcceleration| in g
    let rotation: Double // |rotationRate| in rad/s
}

nonisolated struct FallDetector {
    var sensitivity: FallSensitivity

    // ponytail: calibration constants — timing/stillness gates to tune on real rides.
    private static let tumbleWindow = 0.5    // s either side of the impact
    private static let stillStartWindow = 3.0 // s after impact to start lying still
    private static let stillFor = 10.0       // s of continuous stillness
    private static let stillAccelG = 0.15
    private static let stillRotation = 0.5

    private struct Candidate {
        let impactTime: Double
        var tumbleSeen: Bool
        var stillStart: Double?
    }

    private var candidate: Candidate?
    private var lastTumble: Double?
    private var confirmed = false

    /// One impact paired with one tumble, then ten quiet seconds, is a fall.
    /// Returns true on exactly the sample that completes the stillness.
    mutating func feed(_ s: MotionSample) -> Bool {
        guard sensitivity != .off, !confirmed else { return false }
        if s.rotation > sensitivity.tumbleRadPerSec { lastTumble = s.t }
        // Never lay still in time: the rider got up and rode on, so look for the next impact.
        if let c = candidate, c.stillStart == nil, s.t - c.impactTime > Self.stillStartWindow { candidate = nil }

        guard var c = candidate else {
            if s.accelG > sensitivity.impactG {
                let paired = s.rotation > sensitivity.tumbleRadPerSec
                    || lastTumble.map { abs(s.t - $0) <= Self.tumbleWindow } == true
                candidate = Candidate(impactTime: s.t, tumbleSeen: paired, stillStart: nil)
            }
            return false
        }

        if !c.tumbleSeen {
            if s.rotation > sensitivity.tumbleRadPerSec,
               abs(s.t - c.impactTime) <= Self.tumbleWindow {
                c.tumbleSeen = true
            } else if s.t - c.impactTime > Self.tumbleWindow {
                candidate = nil
                return false
            }
            guard c.tumbleSeen else { candidate = c; return false }
        }

        let still = s.accelG < Self.stillAccelG && s.rotation < Self.stillRotation
        if still {
            if c.stillStart == nil {
                guard s.t - c.impactTime <= Self.stillStartWindow + 1e-9 else {
                    candidate = nil
                    return false
                }
                c.stillStart = s.t
            } else if s.t - c.stillStart! >= Self.stillFor - 1e-3 {
                candidate = nil
                confirmed = true
                return true
            }
        } else if c.stillStart != nil {
            // Motion once stillness began: the phone was picked up.
            candidate = nil
            return false
        }

        candidate = c
        return false
    }

    mutating func reset() {
        candidate = nil
        lastTumble = nil
        confirmed = false
    }
}

extension FallDetector {
    static func selfCheck() {
        // 50 Hz synthetic streams: each part repeats (accelG, rotation) for a duration.
        let dt = 0.02
        func stream(_ parts: [(Double, Double, Double)]) -> [MotionSample] {
            var out: [MotionSample] = []
            var t = 0.0
            for part in parts {
                for _ in 0..<Int((part.0 / dt).rounded()) {
                    out.append(MotionSample(t: t, accelG: part.1, rotation: part.2))
                    t += dt
                }
            }
            return out
        }

        func fires(_ sensitivity: FallSensitivity, _ parts: [(Double, Double, Double)]) -> Int {
            var detector = FallDetector(sensitivity: sensitivity)
            var count = 0
            for sample in stream(parts) where detector.feed(sample) { count += 1 }
            return count
        }

        let noise = [(60.0, 0.3, 1.0)]                         // steady riding
        let fall = [(dt, 5.0, 7.0), (10.5, 0.05, 0.2)]          // impact + tumble + still
        let pickedUp = [(dt, 5.0, 7.0), (4.0, 0.05, 0.2), (6.0, 0.6, 1.0)]
        let kerb = [(dt, 3.5, 1.0), (10.5, 0.05, 0.2)]          // hard bump, no tumble
        let soft = [(dt, 3.2, 7.0), (10.5, 0.05, 0.2)]          // only High should catch this
        let lateStill = [(dt, 5.0, 7.0), (3.5, 0.3, 1.0), (10.5, 0.05, 0.2)]
        let rodeOn = [(dt, 5.0, 7.0), (20.0, 0.3, 1.0), (dt, 5.0, 7.0), (10.5, 0.05, 0.2)]
        let tumbleFirst = [(dt, 0.1, 7.0), (0.28, 0.1, 0.2), (dt, 5.0, 0.2), (10.5, 0.05, 0.2)]

        assert(fires(.normal, noise) == 0, "steady riding must never confirm a fall")
        assert(fires(.normal, fall) == 1, "impact + tumble + 10 s still confirms exactly once")
        assert(fires(.normal, pickedUp) == 0, "picked up mid-still is a dropped phone, not a fall")
        assert(fires(.normal, kerb) == 0, "3.5 g kerb spike without tumble is below Normal")
        assert(fires(.high, soft) == 1, "3.2 g + tumble confirms at High")
        assert(fires(.normal, soft) == 0, "3.2 g is below Normal's impact threshold")
        assert(fires(.low, soft) == 0, "3.2 g is below Low's impact threshold")
        assert(fires(.normal, lateStill) == 0, "stillness starting over 3 s after impact is too late")
        assert(fires(.normal, rodeOn) == 1, "a bump the rider rode on from must not blind the detector to a later fall")
        assert(fires(.normal, tumbleFirst) == 1, "a tumble 0.28 s before impact still pairs")
        for s in [noise, fall, pickedUp, kerb, soft, lateStill, tumbleFirst] {
            assert(fires(.off, s) == 0, "off must never detect")
        }

        var detector = FallDetector(sensitivity: .normal)
        let samples = stream(fall)
        let first = samples.filter { detector.feed($0) }.count
        assert(first == 1, "one confirmation per fall")
        assert(samples.allSatisfy { !detector.feed($0) }, "nothing more until reset")
        detector.reset()
        let second = stream(fall).filter { detector.feed($0) }.count
        assert(second == 1, "reset re-arms detection")
    }
}
