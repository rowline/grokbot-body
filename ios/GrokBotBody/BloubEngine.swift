import CoreGraphics
import Foundation

final class BloubEngine {
    private var current = "idle"
    private var previous: String?
    private var frozen: Bloub.Pose?
    private var tCur: CGFloat = 0
    private var tPrev: CGFloat = 0
    private var look = Bloub.Look.none
    private var lookPrev = Bloub.Look.none
    private var lookAt: CGFloat = -10
    private var rub = Bloub.Rub.none
    private var rubPrev = Bloub.Rub.none
    private var rubAt: CGFloat = -10
    private var rest = "idle"
    private var shape = "cercle"

    var state: String { current }

    func setSkin(rest: String, shape: String, now: CGFloat) {
        if rest == self.rest, shape == self.shape { return }
        frozen = composed(now)
        previous = current
        tPrev = tCur
        self.rest = rest
        self.shape = shape
        tCur = now
    }

    func setState(_ name: String, now: CGFloat) {
        if name == current { return }
        let morph = Bloub.morphDuration(for: current)
        let midFade = previous != nil && now - tCur < morph
        frozen = midFade ? composed(now) : nil
        previous = current
        tPrev = tCur
        current = name
        tCur = now
    }

    func setLook(_ look: Bloub.Look, now: CGFloat) {
        lookPrev = lookAtTime(now)
        self.look = look
        lookAt = now
    }

    func setRub(_ rub: Bloub.Rub, now: CGFloat) {
        rubPrev = rubAtTime(now)
        self.rub = rub
        rubAt = now
    }

    func sample(_ now: CGFloat) -> Bloub.Pose {
        var pose = composed(now)
        let look = lookAtTime(now)
        let life = Bloub.liveliness(now, wander: pose.eyeAlpha > 0.01 ? look.wander : 0, blink: pose.eyeAlpha > 0.01)
        pose.gaze = Bloub.Gaze(
            yaw: Bloub.lerp(pose.gaze.yaw, look.yaw, look.mix) + life.dYaw,
            pitch: Bloub.lerp(pose.gaze.pitch, look.pitch, look.mix) + life.dPitch,
            roll: pose.gaze.roll + life.dRoll
        )
        pose.offX += life.driftX
        pose.offY += life.driftY
        pose.sil.sy *= life.breath
        var left = pose.eyes.0
        var right = pose.eyes.1
        left.open *= life.lid
        right.open *= life.lid
        pose.eyes = (left, right)
        return Bloub.applyRub(pose, rubAtTime(now))
    }

    private func composed(_ now: CGFloat) -> Bloub.Pose {
        let pose = Bloub.pose(for: current, t: max(0, now - tCur), rest: rest, shape: shape)
        let morph = Bloub.morphDuration(for: current)
        let since = now - tCur
        guard since < morph else { return pose }
        let origin = frozen ?? previous.map { Bloub.pose(for: $0, t: max(0, now - tPrev), rest: rest, shape: shape) }
        guard let origin else { return pose }
        return Bloub.blendPose(origin, pose, Bloub.easeOutQuint(Bloub.clamp(since / morph)))
    }

    private func lookAtTime(_ now: CGFloat) -> Bloub.Look {
        let k = (now - lookAt) / Bloub.lookMorph
        if k >= 1 { return look }
        let t = Bloub.easeOutQuint(Bloub.clamp(k))
        return Bloub.Look(
            yaw: Bloub.lerp(lookPrev.yaw, look.yaw, t),
            pitch: Bloub.lerp(lookPrev.pitch, look.pitch, t),
            mix: Bloub.lerp(lookPrev.mix, look.mix, t),
            wander: Bloub.lerp(lookPrev.wander, look.wander, t)
        )
    }

    private func rubAtTime(_ now: CGFloat) -> Bloub.Rub {
        let k = (now - rubAt) / Bloub.rubMorph
        if k >= 1 { return rub }
        let t = Bloub.easeOutQuint(Bloub.clamp(k))
        return Bloub.Rub(
            nx: Bloub.lerp(rubPrev.nx, rub.nx, t),
            ny: Bloub.lerp(rubPrev.ny, rub.ny, t),
            press: Bloub.lerp(rubPrev.press, rub.press, t)
        )
    }
}
