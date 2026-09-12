// Body shapes and colours from jeremy-prt/bloub skins.ts (MIT).
// Rest expressions are in Bloub.pose; this file is the customiser grid.

import CoreGraphics
import UIKit

enum BloubSkin {
    static let samples = Bloub.samples
    static let tau = Bloub.tau

    struct Shape: Identifiable, Hashable {
        let id: String
        let label: String
    }

    struct Color: Identifiable, Hashable {
        let id: String
        let label: String
        let hex: String
    }

    struct Face: Identifiable, Hashable {
        let id: String
        let label: String
    }

    static func sanityIssues() -> [String] {
        var issues: [String] = []
        for shape in shapes {
            let r = radii(for: shape.id)
            if r.count != samples {
                issues.append("\(shape.id) count \(r.count)")
                continue
            }
            if let bad = r.first(where: { !$0.isFinite || $0 < 0.15 || $0 > 2.5 }) {
                issues.append("\(shape.id) radius \(bad)")
            }
        }
        let idle = Bloub.pose(for: "idle", t: 0, rest: "idle", shape: "cercle")
        let happy = Bloub.pose(for: "idle", t: 0, rest: "happy", shape: "cercle")
        if abs(idle.eyes.0.h - happy.eyes.0.h) < 0.01 {
            issues.append("happy rest matches idle eyes")
        }
        let angry = Bloub.pose(for: "idle", t: 0, rest: "angry", shape: "cercle")
        if abs(happy.eyes.0.tilt - angry.eyes.0.tilt) < 0.5 {
            issues.append("angry rest matches happy tilt")
        }
        let tri = Bloub.pose(for: "idle", t: 0, rest: "idle", shape: "triangle")
        let sameShape = zip(idle.sil.radii, tri.sil.radii).allSatisfy { abs($0 - $1) < 0.001 }
        if sameShape { issues.append("triangle matches circle") }
        var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
        bodyUIColor(for: "creme").getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
        if cr < 0.8 { issues.append("creme not light") }
        var ir: CGFloat = 0, ig: CGFloat = 0, ib: CGFloat = 0, ia: CGFloat = 0
        bodyUIColor(for: "encre").getRed(&ir, green: &ig, blue: &ib, alpha: &ia)
        if ir > 0.2 { issues.append("encre not dark") }
        for face in faces {
            let pose = Bloub.pose(for: "idle", t: 0, rest: face.id, shape: "cercle")
            if !pose.gaze.yaw.isFinite || pose.eyes.0.w <= 0 || pose.eyes.0.h <= 0 {
                issues.append("\(face.id) pose")
            }
        }
        let engine = BloubEngine()
        engine.setSkin(rest: "happy", shape: "triangle", now: 0)
        let settled = engine.sample(1)
        let expected = Bloub.pose(for: "idle", t: 0, rest: "happy", shape: "triangle")
        if abs(settled.eyes.0.h - expected.eyes.0.h) > 0.03 {
            issues.append("engine rest happy not applied")
        }
        let shapeDelta = zip(settled.sil.radii, expected.sil.radii).map { abs($0 - $1) }.max() ?? 1
        if shapeDelta > 0.03 {
            issues.append("engine triangle not applied")
        }
        engine.setSkin(rest: "angry", shape: "triangle", now: 1)
        let next = engine.sample(2)
        let expectedAngry = Bloub.pose(for: "idle", t: 0, rest: "angry", shape: "triangle")
        if abs(next.eyes.0.tilt - expectedAngry.eyes.0.tilt) > 1 {
            issues.append("engine rest angry not applied")
        }
        return issues
    }

    static let shapes: [Shape] = [
        Shape(id: "cercle", label: "圆"),
        Shape(id: "galet", label: "卵石"),
        Shape(id: "squircle", label: "方圆"),
        Shape(id: "capsule", label: "胶囊"),
        Shape(id: "triangle", label: "三角"),
        Shape(id: "hexagone", label: "六边"),
        Shape(id: "nuage", label: "云"),
        Shape(id: "goutte", label: "水滴"),
    ]

    static let colors: [Color] = [
        Color(id: "encre", label: "墨黑", hex: "#0a0a0c"),
        Color(id: "creme", label: "奶油白", hex: "#f1efe9"),
        Color(id: "brun", label: "棕", hex: "#8b5e3c"),
        Color(id: "rouge", label: "红", hex: "#e8483f"),
        Color(id: "orange", label: "橙", hex: "#f08a24"),
        Color(id: "ambre", label: "琥珀", hex: "#f0b429"),
        Color(id: "vert", label: "绿", hex: "#3ecf8e"),
        Color(id: "turquoise", label: "青", hex: "#2fbfa0"),
        Color(id: "bleu", label: "蓝", hex: "#3b93f0"),
        Color(id: "violet", label: "紫", hex: "#8b5cf6"),
        Color(id: "rose", label: "粉", hex: "#e152b0"),
        Color(id: "gris", label: "灰", hex: "#a3a3a3"),
    ]

    static let faces: [Face] = [
        Face(id: "idle", label: "平静"),
        Face(id: "listen", label: "专注"),
        Face(id: "surprised", label: "惊讶"),
        Face(id: "excited", label: "兴奋"),
        Face(id: "happy", label: "开心"),
        Face(id: "laugh", label: "大笑"),
        Face(id: "angry", label: "生气"),
        Face(id: "sad", label: "难过"),
        Face(id: "scared", label: "害怕"),
        Face(id: "suspicious", label: "怀疑"),
        Face(id: "confused", label: "困惑"),
        Face(id: "curious", label: "好奇"),
        Face(id: "proud", label: "得意"),
        Face(id: "shy", label: "羞怯"),
        Face(id: "bored", label: "无趣"),
        Face(id: "sleepy", label: "困倦"),
    ]

    static func radii(for id: String) -> [CGFloat] {
        switch id {
        case "galet": return pebble
        case "squircle": return squircle
        case "capsule": return capsule
        case "triangle": return triangle
        case "hexagone": return hexagon
        case "nuage": return cloud
        case "goutte": return droplet
        default: return Array(repeating: 1, count: samples)
        }
    }

    static func bodyUIColor(for id: String) -> UIColor {
        let hex = colors.first(where: { $0.id == id })?.hex ?? "#f1efe9"
        return uiColor(hex)
    }

    static func eyeUIColor(for bodyId: String) -> UIColor {
        luminance(bodyUIColor(for: bodyId)) > 0.55
            ? UIColor(red: 0.09, green: 0.10, blue: 0.08, alpha: 1)
            : UIColor(red: 1, green: 0.99, blue: 0.97, alpha: 1)
    }

    private static func uiColor(_ hex: String) -> UIColor {
        var h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if h.count == 3 {
            h = h.map { "\($0)\($0)" }.joined()
        }
        var n: UInt64 = 0
        Scanner(string: h).scanHexInt64(&n)
        return UIColor(
            red: CGFloat((n >> 16) & 0xFF) / 255,
            green: CGFloat((n >> 8) & 0xFF) / 255,
            blue: CGFloat(n & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static let pebble: [CGFloat] = {
        normalize((0..<samples).map { i in
            let a = CGFloat(i) / CGFloat(samples) * tau
            return 1 + 0.075 * cos(2 * a + 0.5) + 0.035 * cos(3 * a + 2.1)
        }, 1.02)
    }()

    private static let squircle: [CGFloat] = {
        normalize(superellipse(4.2), 1.15)
    }()

    private static let capsule: [CGFloat] = {
        profileFromPolygon(hullOfCircles(x1: -0.42, y1: 0, r1: 0.62, x2: 0.42, y2: 0, r2: 0.62))
    }()

    private static let triangle: [CGFloat] = {
        regularPolygon(sides: 3, radius: 1.12, corner: 0.34, rotationDeg: -90)
    }()

    private static let hexagon: [CGFloat] = {
        regularPolygon(sides: 6, radius: 1.04, corner: 0.26, rotationDeg: 0)
    }()

    private static let cloud: [CGFloat] = {
        normalize(
            unionOfCircles([
                (x: -0.44, y: 0.2, r: 0.54),
                (x: 0.46, y: 0.2, r: 0.5),
                (x: 0.02, y: 0.3, r: 0.6),
                (x: -0.24, y: -0.3, r: 0.48),
                (x: 0.3, y: -0.24, r: 0.44),
            ]),
            1.02
        )
    }()

    private static let droplet: [CGFloat] = {
        normalize(
            profileFromPolygon(hullOfCircles(x1: 0, y1: 0.28, r1: 0.66, x2: 0, y2: -0.96, r2: 0.05)),
            1.04
        )
    }()

    private static func normalize(_ radii: [CGFloat], _ maxR: CGFloat) -> [CGFloat] {
        let peak = radii.max() ?? 1
        guard peak > 0 else { return radii }
        let k = maxR / peak
        return radii.map { $0 * k }
    }

    private static func superellipse(_ n: CGFloat) -> [CGFloat] {
        (0..<samples).map { i in
            let a = CGFloat(i) / CGFloat(samples) * tau
            let c = pow(abs(cos(a)), n)
            let s = pow(abs(sin(a)), n)
            return pow(c + s, -1 / n)
        }
    }

    private static func unionOfCircles(_ circles: [(x: CGFloat, y: CGFloat, r: CGFloat)]) -> [CGFloat] {
        (0..<samples).map { i in
            let a = CGFloat(i) / CGFloat(samples) * tau
            let dx = cos(a)
            let dy = sin(a)
            var best: CGFloat = 0
            for c in circles {
                let b = dx * c.x + dy * c.y
                let disc = b * b - (c.x * c.x + c.y * c.y - c.r * c.r)
                guard disc >= 0 else { continue }
                let t = b + sqrt(disc)
                if t > best { best = t }
            }
            return best
        }
    }

    private static func hullOfCircles(
        x1: CGFloat, y1: CGFloat, r1: CGFloat,
        x2: CGFloat, y2: CGFloat, r2: CGFloat,
        steps: Int = 96
    ) -> [CGPoint] {
        let dx = x2 - x1
        let dy = y2 - y1
        let dist = max(hypot(dx, dy), 1e-6)
        let base = atan2(dy, dx)
        let spread = acos(Bloub.clamp((r1 - r2) / dist, -1, 1))
        var pts: [CGPoint] = []
        let half = steps / 2
        for i in 0...half {
            let a = base + spread + (tau - 2 * spread) * CGFloat(i) / CGFloat(half)
            pts.append(CGPoint(x: x1 + cos(a) * r1, y: y1 + sin(a) * r1))
        }
        for i in 0...half {
            let a = base - spread + (2 * spread) * CGFloat(i) / CGFloat(half)
            pts.append(CGPoint(x: x2 + cos(a) * r2, y: y2 + sin(a) * r2))
        }
        return pts
    }

    private static func profileFromPolygon(_ poly: [CGPoint]) -> [CGFloat] {
        let n = poly.count
        return (0..<samples).map { k in
            let ang = CGFloat(k) / CGFloat(samples) * tau
            let dx = cos(ang)
            let dy = sin(ang)
            var best: CGFloat = 0
            for i in 0..<n {
                let a = poly[i]
                let b = poly[(i + 1) % n]
                let ex = b.x - a.x
                let ey = b.y - a.y
                let den = dx * ey - dy * ex
                if abs(den) < 1e-9 { continue }
                let px = a.x
                let py = a.y
                let t = (px * ey - py * ex) / den
                let u = (px * dy - py * dx) / den
                if t > best, u >= 0, u <= 1 { best = t }
            }
            return best
        }
    }

    private static func regularPolygon(sides: Int, radius: CGFloat, corner: CGFloat, rotationDeg: CGFloat) -> [CGFloat] {
        let rot = rotationDeg * .pi / 180
        let verts: [CGPoint] = (0..<sides).map { i in
            let a = rot + CGFloat(i) / CGFloat(sides) * tau
            return CGPoint(x: cos(a) * (radius - corner), y: sin(a) * (radius - corner))
        }
        return profileFromPolygon(roundedPolygon(verts, corner))
    }

    private static func roundedPolygon(_ verts: [CGPoint], _ rc: CGFloat, arcSteps: Int = 10) -> [CGPoint] {
        let n = verts.count
        var out: [CGPoint] = []
        func normal(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len = max(hypot(dx, dy), 1)
            return atan2(-dx / len, dy / len)
        }
        for i in 0..<n {
            let prev = verts[(i - 1 + n) % n]
            let cur = verts[i]
            let next = verts[(i + 1) % n]
            let a0 = normal(prev, cur)
            let a1 = normal(cur, next)
            var d = a1 - a0
            while d > .pi { d -= tau }
            while d < -.pi { d += tau }
            for k in 0...arcSteps {
                let a = a0 + d * CGFloat(k) / CGFloat(arcSteps)
                out.append(CGPoint(x: cur.x + cos(a) * rc, y: cur.y + sin(a) * rc))
            }
        }
        return out
    }
}
