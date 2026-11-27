//
//  FallMonitor.swift
//  cyclingskibidi
//
//  Core Motion wrapper: feeds reduced magnitudes to the pure FallDetector on
//  its own serial queue, and hops to the main actor when a fall is confirmed.
//

import Foundation
import CoreMotion

nonisolated final class FallMonitor {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    // Touched only on `queue`, inside the motion handler.
    private var detector = FallDetector(sensitivity: .normal)

    func start(sensitivity: FallSensitivity, onFall: @escaping @MainActor () -> Void) {
        stop()
        guard sensitivity != .off, manager.isDeviceMotionAvailable else { return }
        queue.maxConcurrentOperationCount = 1
        detector = FallDetector(sensitivity: sensitivity)
        manager.deviceMotionUpdateInterval = 0.02
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let a = motion.userAcceleration
            let r = motion.rotationRate
            let sample = MotionSample(t: motion.timestamp,
                                      accelG: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot(),
                                      rotation: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot())
            if self.detector.feed(sample) {
                // Re-arm at once: after "I'm OK" the ride goes on and a second fall must count.
                // (A fall while the prompt is up is ignored by fallDetected().)
                self.detector.reset()
                Task { @MainActor in onFall() }
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
