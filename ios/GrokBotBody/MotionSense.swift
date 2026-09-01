import Combine
import CoreGraphics
import CoreMotion
import Foundation

/// Phone tilt and shake. The phone sits on the dock, so the same gyro
/// also sees stand rotation. Rest pose is the quiet dock angle; only
/// clear moves change the face. Gaze is read by the face view; only
/// shake/dizzy notify SwiftUI.
final class MotionSense: ObservableObject {
    var gaze = CGPoint.zero
    var turn: CGFloat = 0
    var jiggle: CGFloat = 0
    @Published var shaking = false
    @Published var dizzy: CGFloat = 0

    private let motion = CMMotionManager()
    private var shakeUntil: Date?
    private var dizzyUntil: Date?
    private var restX: Double?
    private var restY: Double?
    private var filteredX: Double = 0
    private var filteredY: Double = 0
    private var energy: Double = 0
    private var peaks = 0
    private var lastPeak: Date?
    private var stillFrames = 0

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] sample, _ in
            self?.ingest(sample)
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    private func ingest(_ sample: CMDeviceMotion?) {
        guard let sample else { return }
        let g = sample.gravity
        let acc = sample.userAcceleration
        let rate = sample.rotationRate
        let bump = sqrt(acc.x * acc.x + acc.y * acc.y + acc.z * acc.z)
        let spinning = abs(rate.x) + abs(rate.y) + abs(rate.z)

        if bump < 0.05, spinning < 0.18 {
            stillFrames += 1
            if stillFrames > 10 {
                if let restX, let restY {
                    self.restX = restX * 0.992 + g.x * 0.008
                    self.restY = restY * 0.992 + g.y * 0.008
                } else {
                    restX = g.x
                    restY = g.y
                }
            }
        } else {
            stillFrames = 0
        }

        let originX = restX ?? g.x
        let originY = restY ?? g.y
        var dx = g.x - originX
        var dy = g.y - originY
        if abs(dx) < 0.12 { dx = 0 }
        if abs(dy) < 0.12 { dy = 0 }

        filteredX = filteredX * 0.9 + dx * 0.1
        filteredY = filteredY * 0.9 + dy * 0.1
        if abs(filteredX) < 0.03 { filteredX = 0 }
        if abs(filteredY) < 0.03 { filteredY = 0 }

        let nextGaze = CGPoint(
            x: CGFloat(max(-1, min(1, filteredX * 2.2))),
            y: CGFloat(max(-1, min(1, -filteredY * 1.8)))
        )
        let nextTurn: CGFloat = abs(rate.y) < 0.4
            ? 0
            : CGFloat(max(-0.32, min(0.32, rate.y * 0.08)))
        let nextJiggle: CGFloat = bump > 0.55
            ? CGFloat(max(-5, min(5, acc.x * 5)))
            : 0

        energy = energy * 0.82 + bump
        let now = Date()
        let alreadyDizzy = dizzyUntil.map { $0 > now } ?? false
        if bump > 1.45 {
            if let lastPeak, now.timeIntervalSince(lastPeak) > 0.9 {
                peaks = 0
            }
            peaks += 1
            lastPeak = now
            shakeUntil = now.addingTimeInterval(bump > 2.1 ? 0.4 : 0.2)
        }
        if !alreadyDizzy, energy > 5.8, peaks >= 4 {
            dizzyUntil = now.addingTimeInterval(1.8)
            peaks = 0
            energy = 0
        }
        let nowShaking = (shakeUntil ?? .distantPast) > now
        var nextDizzy: CGFloat = 0
        if let until = dizzyUntil {
            if until > now {
                let left = until.timeIntervalSince(now)
                nextDizzy = CGFloat(min(1, max(0, left / 1.1)))
            } else {
                dizzyUntil = nil
                peaks = 0
                energy = 0
            }
        }

        gaze = nextGaze
        turn = nextTurn
        jiggle = nextJiggle
        if nowShaking != shaking { shaking = nowShaking }
        if nextDizzy == 0 {
            if dizzy != 0 { dizzy = 0 }
        } else if abs(nextDizzy - dizzy) > 0.02 {
            dizzy = nextDizzy
        }
    }
}
