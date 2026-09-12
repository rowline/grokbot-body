// Geometry and easing ported from jeremy-prt/bloub (MIT).
// Transitions are exponential ease-outs. The body never overshoots.

import CoreGraphics
import Foundation
import UIKit

enum Bloub {
    static let tau = CGFloat.pi * 2
    static let samples = 64
    static let restYaw: CGFloat = 28.49
    static let restPitch: CGFloat = 28.62
    static let restRoll: CGFloat = -13
    static let eyeSplit: CGFloat = 15.46
    static let eyeW: CGFloat = 0.186
    static let eyeH: CGFloat = 0.412
    static let shapeMorph: CGFloat = 0.45
    static let lookMorph: CGFloat = 0.24
    static let rubMorph: CGFloat = 0.36

    static func clamp(_ v: CGFloat, _ lo: CGFloat = 0, _ hi: CGFloat = 1) -> CGFloat {
        Swift.max(lo, Swift.min(hi, v))
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    static func easeOutQuint(_ t: CGFloat) -> CGFloat {
        let u = 1 - clamp(t)
        return 1 - u * u * u * u * u
    }

    static func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let u = 1 - clamp(t)
        return 1 - u * u * u
    }

    static func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        let x = clamp(t)
        if x < 0.5 { return 4 * x * x * x }
        let u = -2 * x + 2
        return 1 - u * u * u / 2
    }

    static func loopNoise(_ t: CGFloat, period: CGFloat, seed: CGFloat) -> CGFloat {
        let p = (t / period) * tau
        return 0.55 * sin(p + seed)
            + 0.3 * sin(2 * p + seed * 1.7 + 1.1)
            + 0.15 * sin(3 * p + seed * 2.3 + 2.4)
    }

    static let hexagon: [CGFloat] = [
        0.9210, 0.9282, 0.9441, 0.9706, 0.9984, 1.0059, 0.9896, 0.9562,
        0.9290, 0.9124, 0.9047, 0.9058, 0.9157, 0.9349, 0.9642, 0.9873,
        0.9882, 0.9665, 0.9336, 0.9105, 0.8968, 0.8918, 0.8955, 0.9080,
        0.9293, 0.9611, 0.9820, 0.9812, 0.9590, 0.9282, 0.9089, 0.8978,
        0.8964, 0.9026, 0.9189, 0.9439, 0.9778, 0.9990, 0.9964, 0.9713,
        0.9439, 0.9274, 0.9196, 0.9206, 0.9308, 0.9502, 0.9799, 1.0121,
        1.0226, 1.0071, 0.9752, 0.9510, 0.9366, 0.9316, 0.9351, 0.9485,
        0.9711, 1.0026, 1.0213, 1.0155, 0.9863, 0.9547, 0.9347, 0.9232,
    ]

    struct Gaze {
        var yaw: CGFloat
        var pitch: CGFloat
        var roll: CGFloat
        static let rest = Gaze(yaw: restYaw, pitch: restPitch, roll: restRoll)
    }

    struct Eye {
        var w: CGFloat
        var h: CGFloat
        var open: CGFloat
        var tilt: CGFloat
        static func pair(_ w: CGFloat, _ h: CGFloat, tilt: CGFloat = 0, open: CGFloat = 1) -> (Eye, Eye) {
            (Eye(w: w, h: h, open: open, tilt: tilt), Eye(w: w, h: h, open: open, tilt: -tilt))
        }
    }

    struct Silhouette {
        var radii: [CGFloat]
        var rot: CGFloat
        var cx: CGFloat
        var cy: CGFloat
        var sx: CGFloat
        var sy: CGFloat

        static func circle(_ radius: CGFloat = 1, rot: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0) -> Silhouette {
            Silhouette(radii: Array(repeating: radius, count: samples), rot: rot, cx: cx, cy: cy, sx: 1, sy: 1)
        }

        static func hex() -> Silhouette {
            Silhouette(radii: hexagon, rot: 0, cx: 0, cy: 0, sx: 1, sy: 1)
        }
    }

    struct Look {
        var yaw: CGFloat
        var pitch: CGFloat
        var mix: CGFloat
        var wander: CGFloat
        static let none = Look(yaw: 0, pitch: 0, mix: 0, wander: 1)
    }

    struct Rub {
        var nx: CGFloat
        var ny: CGFloat
        var press: CGFloat
        static let none = Rub(nx: 0, ny: 0, press: 0)
    }

    struct Pose {
        var sil: Silhouette
        var offX: CGFloat
        var offY: CGFloat
        var gaze: Gaze
        var split: CGFloat
        var eyes: (Eye, Eye)
        var eyeAlpha: CGFloat
        var bodyAlpha: CGFloat
        var showBang: Bool
        var orbit: CGFloat

        static func rest() -> Pose {
            let eyes = Eye.pair(eyeW, eyeH)
            return Pose(
                sil: .circle(),
                offX: 0,
                offY: 0,
                gaze: .rest,
                split: eyeSplit,
                eyes: eyes,
                eyeAlpha: 1,
                bodyAlpha: 1,
                showBang: false,
                orbit: 0
            )
        }
    }

    static func blendSil(_ a: Silhouette, _ b: Silhouette, _ t: CGFloat) -> Silhouette {
        var rot = b.rot - a.rot
        while rot > .pi { rot -= tau }
        while rot < -.pi { rot += tau }
        return Silhouette(
            radii: zip(a.radii, b.radii).map { lerp($0, $1, t) },
            rot: a.rot + rot * t,
            cx: lerp(a.cx, b.cx, t),
            cy: lerp(a.cy, b.cy, t),
            sx: lerp(a.sx, b.sx, t),
            sy: lerp(a.sy, b.sy, t)
        )
    }

    static func blendPose(_ a: Pose, _ b: Pose, _ t: CGFloat) -> Pose {
        Pose(
            sil: blendSil(a.sil, b.sil, t),
            offX: lerp(a.offX, b.offX, t),
            offY: lerp(a.offY, b.offY, t),
            gaze: Gaze(
                yaw: lerp(a.gaze.yaw, b.gaze.yaw, t),
                pitch: lerp(a.gaze.pitch, b.gaze.pitch, t),
                roll: lerp(a.gaze.roll, b.gaze.roll, t)
            ),
            split: lerp(a.split, b.split, t),
            eyes: (
                Eye(
                    w: lerp(a.eyes.0.w, b.eyes.0.w, t),
                    h: lerp(a.eyes.0.h, b.eyes.0.h, t),
                    open: lerp(a.eyes.0.open, b.eyes.0.open, t),
                    tilt: lerp(a.eyes.0.tilt, b.eyes.0.tilt, t)
                ),
                Eye(
                    w: lerp(a.eyes.1.w, b.eyes.1.w, t),
                    h: lerp(a.eyes.1.h, b.eyes.1.h, t),
                    open: lerp(a.eyes.1.open, b.eyes.1.open, t),
                    tilt: lerp(a.eyes.1.tilt, b.eyes.1.tilt, t)
                )
            ),
            eyeAlpha: lerp(a.eyeAlpha, b.eyeAlpha, t),
            bodyAlpha: lerp(a.bodyAlpha, b.bodyAlpha, t),
            showBang: t < 0.5 ? a.showBang : b.showBang,
            orbit: lerp(a.orbit, b.orbit, t)
        )
    }

    static func points(_ s: Silhouette, scale: CGFloat) -> [CGPoint] {
        let cr = cos(s.rot)
        let sr = sin(s.rot)
        let radii = s.radii
        guard radii.count == samples else {
            return (0..<samples).map { i in
                let ang = CGFloat(i) / CGFloat(samples) * tau
                let r = i < radii.count ? radii[i] : 1
                return CGPoint(x: r * cos(ang) * scale, y: r * sin(ang) * scale)
            }
        }
        return (0..<samples).map { i in
            let ang = CGFloat(i) / CGFloat(samples) * tau
            let r = radii[i]
            let x = r * cos(ang)
            let y = r * sin(ang)
            let rx = x * cr - y * sr
            let ry = x * sr + y * cr
            return CGPoint(
                x: (rx * s.sx + s.cx) * scale,
                y: (ry * s.sy + s.cy) * scale
            )
        }
    }

    static func closedPath(_ pts: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        let n = pts.count
        guard n >= 3 else { return path }
        path.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n]
            let p1 = pts[i]
            let p2 = pts[(i + 1) % n]
            let p3 = pts[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        path.close()
        return path
    }

    static func capsule(w: CGFloat, h: CGFloat) -> UIBezierPath {
        let hw = max(w, 0.01) / 2
        let hh = max(h, 0.01) / 2
        let r = min(hw, hh)
        return UIBezierPath(roundedRect: CGRect(x: -hw, y: -hh, width: hw * 2, height: hh * 2), cornerRadius: r)
    }

    static func radiusAtAngle(_ radii: [CGFloat], _ angle: CGFloat) -> CGFloat {
        guard !radii.isEmpty else { return 1 }
        let n = CGFloat(radii.count)
        var t = (angle / tau).truncatingRemainder(dividingBy: 1)
        if t < 0 { t += 1 }
        t *= n
        let i = Int(floor(t))
        return lerp(radii[i % radii.count], radii[(i + 1) % radii.count], t - CGFloat(i))
    }

    struct EyePose {
        var x: CGFloat
        var y: CGFloat
        var a: CGFloat
        var b: CGFloat
        var c: CGFloat
        var d: CGFloat
        var depth: CGFloat
    }

    static func eyePoses(_ gaze: Gaze, scale: CGFloat, split: CGFloat) -> (EyePose, EyePose) {
        var f: (CGFloat, CGFloat, CGFloat) = (0, 0, 1)
        var right: (CGFloat, CGFloat, CGFloat) = (1, 0, 0)
        var down: (CGFloat, CGFloat, CGFloat) = (0, 1, 0)
        func spin(
            _ u: (CGFloat, CGFloat, CGFloat),
            _ v: (CGFloat, CGFloat, CGFloat),
            _ angle: CGFloat
        ) -> ((CGFloat, CGFloat, CGFloat), (CGFloat, CGFloat, CGFloat)) {
            let c = cos(angle)
            let s = sin(angle)
            return (
                (u.0 * c + v.0 * s, u.1 * c + v.1 * s, u.2 * c + v.2 * s),
                (v.0 * c - u.0 * s, v.1 * c - u.1 * s, v.2 * c - u.2 * s)
            )
        }
        (f, right) = spin(f, right, gaze.yaw * .pi / 180)
        (down, f) = spin(down, f, gaze.pitch * .pi / 180)
        (right, down) = spin(right, down, gaze.roll * .pi / 180)
        func build(_ side: CGFloat) -> EyePose {
            let (ef, er) = spin(f, right, split * side * .pi / 180)
            return EyePose(x: ef.0 * scale, y: ef.1 * scale, a: er.0, b: er.1, c: down.0, d: down.1, depth: ef.2)
        }
        return (build(-1), build(1))
    }

    static func blinkScale(_ lid: CGFloat) -> CGFloat {
        0.06 + 0.94 * clamp(lid)
    }

    static func liveliness(_ t: CGFloat, wander: CGFloat, blink: Bool) -> (dYaw: CGFloat, dPitch: CGFloat, dRoll: CGFloat, lid: CGFloat, driftX: CGFloat, driftY: CGFloat, breath: CGFloat) {
        let lid: CGFloat = blink ? blinkLid(t) : 1
        return (
            (loopNoise(t, period: 11.3, seed: 0.4) * 5.5 + loopNoise(t, period: 3.7, seed: 2.1) * 1.6) * wander,
            (loopNoise(t, period: 9.1, seed: 1.3) * 4.2 + loopNoise(t, period: 4.3, seed: 0.7) * 1.3) * wander,
            loopNoise(t, period: 13.7, seed: 3.2) * 2.2 * wander,
            lid,
            loopNoise(t, period: 7.9, seed: 1.9) * 0.006,
            loopNoise(t, period: 5.3, seed: 0.3) * 0.007,
            1 + sin((t / 3.4) * tau) * 0.005
        )
    }

    private static let blinks: [CGFloat] = {
        var out: [CGFloat] = []
        var t: CGFloat = 1.4
        var seed: UInt32 = 0x5eed
        func rng() -> CGFloat {
            seed = seed &+ 0x6d2b79f5
            var x = seed
            x ^= x >> 15
            x &*= 1 | seed
            return CGFloat(x % 10_000) / 10_000
        }
        while t < 900 {
            out.append(t)
            t += 1.9 + rng() * 2.7
            if rng() < 0.18 {
                out.append(t)
                t += 0.24
            }
        }
        return out
    }()

    private static func blinkLid(_ t: CGFloat) -> CGFloat {
        let dur: CGFloat = 0.18
        let cycle = t - floor(t / 900) * 900
        for start in blinks {
            if cycle < start { break }
            let k = (cycle - start) / dur
            if k >= 0, k <= 1 {
                return k < 0.45 ? 1 - k / 0.45 : (k - 0.45) / 0.55
            }
        }
        return 1
    }

    static func canonicalExpression(_ name: String) -> String {
        switch name {
        case "neutre", "": return "idle"
        case "attentif", "alert": return "listen"
        case "excite", "excited": return "excited"
        case "heureux": return "happy"
        case "hilare", "laughing": return "laugh"
        case "colere": return "angry"
        case "triste": return "sad"
        case "effraye": return "scared"
        case "mefiant": return "suspicious"
        case "confus": return "confused"
        case "curieux": return "curious"
        case "fier": return "proud"
        case "timide": return "shy"
        case "blase": return "bored"
        case "somnolent", "drowsy": return "sleepy"
        case "surpris": return "surprised"
        default: return name
        }
    }

    static func pose(for name: String, t: CGFloat, rest: String = "idle", shape: String = "cercle") -> Pose {
        let key = canonicalExpression(name == "idle" ? rest : name)
        var pose = Pose.rest()
        switch key {
        case "listen":
            pose.gaze = Gaze(yaw: 4, pitch: 5, roll: -4)
            pose.split = 16
            pose.eyes = Eye.pair(0.21, 0.44)
        case "speak", "excited":
            pose.gaze = Gaze(yaw: 6, pitch: -14, roll: 0)
            pose.split = 19.5
            pose.eyes = Eye.pair(0.4, 0.56, tilt: -10)
        case "think":
            pose.orbit = 1
            pose.gaze = Gaze(
                yaw: restYaw + sin(t * 6.5) * 28,
                pitch: 8,
                roll: restRoll
            )
            pose.eyes = Eye.pair(0.18, 0.38)
        case "happy":
            pose.gaze = Gaze(yaw: 5, pitch: 9, roll: 0)
            pose.split = 17
            pose.eyes = Eye.pair(0.27, 0.17, tilt: 14)
        case "laugh":
            pose.gaze = Gaze(yaw: 4, pitch: 14, roll: 0)
            pose.split = 18
            pose.eyes = Eye.pair(0.34, 0.13, tilt: 20)
        case "angry":
            pose.gaze = Gaze(yaw: 3, pitch: 7, roll: 0)
            pose.split = 17
            pose.eyes = Eye.pair(0.34, 0.15, tilt: 30)
        case "sad":
            pose.gaze = Gaze(yaw: 3, pitch: -13, roll: 0)
            pose.split = 16
            pose.eyes = Eye.pair(0.22, 0.4, tilt: -28)
        case "scared":
            pose.gaze = Gaze(yaw: 2, pitch: -20, roll: 0)
            pose.split = 20.5
            pose.eyes = Eye.pair(0.4, 0.6)
        case "suspicious":
            pose.gaze = Gaze(yaw: 12, pitch: 6, roll: -6)
            pose.split = 16
            pose.eyes = (Eye(w: 0.21, h: 0.4, open: 1, tilt: 0), Eye(w: 0.22, h: 0.15, open: 1, tilt: 0))
        case "confused":
            pose.gaze = Gaze(yaw: -14, pitch: 3, roll: 8)
            pose.split = 16.5
            pose.eyes = (Eye(w: 0.2, h: 0.44, open: 1, tilt: -18), Eye(w: 0.28, h: 0.17, open: 1, tilt: 14))
        case "curious":
            pose.gaze = Gaze(yaw: 16, pitch: -9, roll: -15)
            pose.split = 16.5
            pose.eyes = (Eye(w: 0.24, h: 0.46, open: 1, tilt: -8), Eye(w: 0.2, h: 0.38, open: 1, tilt: -8))
        case "proud":
            pose.gaze = Gaze(yaw: 5, pitch: 17, roll: 0)
            pose.split = 17
            pose.eyes = Eye.pair(0.3, 0.15, tilt: 18)
        case "shy":
            pose.gaze = Gaze(yaw: -19, pitch: -14, roll: -7)
            pose.split = 14
            pose.eyes = Eye.pair(0.17, 0.3)
        case "bored":
            pose.gaze = Gaze(yaw: -22, pitch: 2, roll: 0)
            pose.split = 16
            pose.eyes = Eye.pair(0.3, 0.12)
        case "surprised":
            pose.gaze = Gaze(yaw: 6.92, pitch: -21.96, roll: 11.6)
            pose.split = 18.43
            pose.eyes = Eye.pair(0.356, 0.875)
        case "sleepy":
            pose.gaze = Gaze(yaw: 6, pitch: -9, roll: -3)
            pose.split = 16
            pose.eyes = Eye.pair(0.2, 0.42, open: 0.42)
        case "look":
            pose.gaze = Gaze(yaw: 42, pitch: 6, roll: restRoll)
        case "nod":
            pose.gaze = Gaze(yaw: restYaw, pitch: -18, roll: restRoll)
            pose.eyes = Eye.pair(0.21, 0.36)
        case "shake":
            pose.gaze = Gaze(yaw: restYaw + sin(t * 8) * 22, pitch: restPitch, roll: restRoll)
        case "error":
            pose.showBang = true
            pose.eyeAlpha = 0
            pose.bodyAlpha = 1
        case "hex":
            pose.sil = .hex()
            pose.gaze = Gaze(yaw: 23.11, pitch: 24.42, roll: -13.3)
            pose.split = 13.37
            pose.eyes = Eye.pair(0.177, 0.411)
        default:
            break
        }
        if !pose.showBang, key != "hex" {
            pose.sil.radii = BloubSkin.radii(for: shape)
        }
        return pose
    }

    static func morphDuration(for name: String) -> CGFloat {
        switch name {
        case "think": return 0.6
        case "error": return 0.45
        case "hex": return 0.4
        case "surprised": return 0.55
        default: return 0.45
        }
    }

    static func applyRub(_ pose: Pose, _ rub: Rub) -> Pose {
        guard rub.press > 0.01 else { return pose }
        var next = pose
        var radii = pose.sil.radii
        for i in radii.indices {
            let ang = CGFloat(i) / CGFloat(samples) * tau
            let align = cos(ang) * rub.nx + sin(ang) * rub.ny
            radii[i] *= 1 - 0.24 * rub.press * max(0, align) + 0.12 * rub.press * max(0, -align)
        }
        next.sil.radii = radii
        next.sil.sx = 1 + 0.16 * rub.press * abs(rub.nx)
        next.sil.sy = 1 - 0.14 * rub.press
        next.offX += rub.nx * rub.press * 0.1
        next.offY += rub.ny * rub.press * 0.1
        return next
    }
}
