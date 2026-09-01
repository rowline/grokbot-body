// Face painter ported from nasawz/GrokBot (BSD-3-Clause).
// Cubic eye outlines follow the same Catmull-style conversion used by
// iduu/grokbot-animation. See THIRD_PARTY.md.

import QuartzCore
import SwiftUI
import UIKit

enum GrokBotGeometry {
    static let faceCenter: CGFloat = 114.2705
    static let bodyWidth: CGFloat = 228.541
    static let viewBox: CGFloat = 259
    static let inset: CGFloat = 15
    static let springFrequency: CGFloat = 7
    static let blinkDuration: CGFloat = 0.32

    static func clamp(_ value: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        max(a, min(b, value))
    }

    static func centroid(_ ring: [CGPoint]) -> CGPoint {
        var x: CGFloat = 0
        var y: CGFloat = 0
        for p in ring {
            x += p.x
            y += p.y
        }
        let n = CGFloat(max(ring.count, 1))
        return CGPoint(x: x / n, y: y / n)
    }

    static func lerp(_ a: [[CGPoint]], _ b: [[CGPoint]], _ t: CGFloat) -> [[CGPoint]] {
        let amount = clamp(t, 0, 1)
        return zip(a, b).map { left, right in
            zip(left, right).map { p, q in
                CGPoint(x: p.x + (q.x - p.x) * amount, y: p.y + (q.y - p.y) * amount)
            }
        }
    }

    static func cubicPath(_ ring: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        guard ring.count >= 4 else { return path }
        let n = ring.count
        func at(_ i: Int) -> CGPoint { ring[(i % n + n) % n] }
        path.move(to: ring[0])
        for i in 0..<n {
            let previous = at(i - 1)
            let point = at(i)
            let next = at(i + 1)
            let after = at(i + 2)
            let c1 = CGPoint(
                x: point.x + (next.x - previous.x) / 6,
                y: point.y + (next.y - previous.y) / 6
            )
            let c2 = CGPoint(
                x: next.x - (after.x - point.x) / 6,
                y: next.y - (after.y - point.y) / 6
            )
            path.addCurve(to: next, controlPoint1: c1, controlPoint2: c2)
        }
        path.close()
        return path
    }

    static func projectEye(
        centroid: CGPoint,
        origin: CGPoint,
        radius: CGFloat,
        turn: CGFloat,
        gaze: CGPoint,
        scale: CGFloat,
        blinkScale: CGFloat
    ) -> (center: CGPoint, scaleX: CGFloat, scaleY: CGFloat, visible: Bool) {
        let offset = centroid.x - origin.x
        let baseLongitude = asin(Double(clamp(offset / max(radius, 1), -1, 1)))
        let longitude = baseLongitude + Double(turn)
        let depth = cos(longitude)
        let perspective = max(depth, 0.02) / max(cos(baseLongitude), 0.02)
        let center = CGPoint(
            x: origin.x + radius * CGFloat(sin(longitude)) + gaze.x,
            y: centroid.y + gaze.y
        )
        return (
            center,
            clamp(CGFloat(perspective) * scale, 0.02, 2.4),
            clamp(blinkScale * scale, 0.02, 2.4),
            depth > 0.02
        )
    }

    static func expressionIndex(for name: String) -> Int {
        switch name {
        case "listen": return 10
        case "speak": return 1
        case "think": return 8
        case "happy": return 2
        case "curious": return 3
        case "surprised": return 21
        case "sleepy": return 4
        case "look": return 0
        case "nod": return 2
        case "shake": return 14
        case "error": return 3
        case "hex": return 0
        default: return 0
        }
    }

    static func gaze(for name: String) -> CGPoint {
        switch name {
        case "look": return CGPoint(x: 0.85, y: -0.05)
        case "curious": return CGPoint(x: 0.45, y: -0.25)
        case "think": return CGPoint(x: 0.15, y: -0.55)
        case "listen": return CGPoint(x: 0.12, y: 0.08)
        default: return .zero
        }
    }

    static func turn(for name: String) -> CGFloat {
        switch name {
        case "look": return 0.22
        case "shake": return -0.28
        default: return 0
        }
    }

    static func mappedGaze(_ gaze: CGPoint) -> CGPoint {
        CGPoint(x: clamp(gaze.x, -1, 1) * 13.2, y: clamp(gaze.y, -1, 1) * 8.4)
    }

    static func circleRing(count: Int = 48) -> [CGPoint] {
        (0..<count).map { index in
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi - .pi / 2
            return CGPoint(x: faceCenter + 105 * cos(angle), y: faceCenter + 105 * sin(angle))
        }
    }

    static func hexRing(count: Int = 48) -> [CGPoint] {
        let sides = 6
        let verts: [CGPoint] = (0..<sides).map { index in
            let angle = CGFloat(index) / CGFloat(sides) * 2 * .pi - .pi / 2
            return CGPoint(x: faceCenter + 112 * cos(angle), y: faceCenter + 112 * sin(angle))
        }
        let perSide = max(1, count / sides)
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for index in 0..<sides {
            let start = verts[index]
            let end = verts[(index + 1) % sides]
            for step in 0..<perSide {
                let t = CGFloat(step) / CGFloat(perSide)
                points.append(CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            }
        }
        return points
    }

    static func lerpRing(_ a: [CGPoint], _ b: [CGPoint], _ t: CGFloat) -> [CGPoint] {
        let amount = clamp(t, 0, 1)
        return zip(a, b).map { p, q in
            CGPoint(x: p.x + (q.x - p.x) * amount, y: p.y + (q.y - p.y) * amount)
        }
    }

    static func bodyRing(for name: String) -> [CGPoint] {
        name == "hex" ? hexRing() : circleRing()
    }

    static func showsBang(_ name: String) -> Bool { name == "error" }
    static func showsOrbit(_ name: String) -> Bool { name == "think" }
    static func hidesEyes(_ name: String) -> Bool { name == "error" }
}

final class GrokBotCanvasView: UIView {
    var lightTheme = true {
        didSet { setNeedsDisplay() }
    }
    var liveGaze = CGPoint.zero {
        didSet { if oldValue != liveGaze { setNeedsDisplay() } }
    }
    var liveTurn: CGFloat = 0 {
        didSet { if abs(oldValue - liveTurn) > 0.008 { setNeedsDisplay() } }
    }
    var jiggle: CGFloat = 0 {
        didSet { if abs(oldValue - jiggle) > 0.3 { setNeedsDisplay() } }
    }
    var dizzy: CGFloat = 0 {
        didSet {
            if abs(oldValue - dizzy) > 0.02 {
                if dizzy > 0.02 { ensureLink() }
                setNeedsDisplay()
            }
        }
    }
    weak var motion: MotionSense?
    private var dizzySpin: CGFloat = 0

    private var expressionName = "idle"
    private var currentRings = GrokBotRingData.rings(expression: 0)
    private var targetRings = GrokBotRingData.rings(expression: 0)
    private var currentBody = GrokBotGeometry.circleRing()
    private var targetBody = GrokBotGeometry.circleRing()
    private var bangFrom: CGFloat = 0
    private var bangTo: CGFloat = 0
    private var orbitFrom: CGFloat = 0
    private var orbitTo: CGFloat = 0
    private var orbitAngle: CGFloat = 0
    private var morph: CGFloat = 1
    private var velocity: CGFloat = 0
    private var blinkT: CGFloat?
    private var blinkScale: CGFloat = 1
    private var lastTick: CFTimeInterval?
    private var displayLink: CADisplayLink?
    private var blinkWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        displayLink?.invalidate()
        blinkWork?.cancel()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
            lastTick = nil
        } else {
            ensureLink()
            scheduleBlink()
        }
    }

    func setExpression(_ name: String) {
        if name == expressionName { return }
        currentRings = displayedRings()
        currentBody = displayedBody()
        bangFrom = displayedBang
        orbitFrom = displayedOrbit
        expressionName = name
        targetRings = GrokBotRingData.rings(expression: GrokBotGeometry.expressionIndex(for: name))
        targetBody = GrokBotGeometry.bodyRing(for: name)
        bangTo = GrokBotGeometry.showsBang(name) ? 1 : 0
        orbitTo = GrokBotGeometry.showsOrbit(name) ? 1 : 0
        morph = 0
        velocity = 0
        ensureLink()
        setNeedsDisplay()
    }

    func blink() {
        blinkT = 0
        ensureLink()
    }

    private func displayedRings() -> [[CGPoint]] {
        GrokBotGeometry.lerp(currentRings, targetRings, morph)
    }

    private func displayedBody() -> [CGPoint] {
        GrokBotGeometry.lerpRing(currentBody, targetBody, morph)
    }

    private var displayedBang: CGFloat {
        bangFrom + (bangTo - bangFrom) * GrokBotGeometry.clamp(morph, 0, 1)
    }

    private var displayedOrbit: CGFloat {
        orbitFrom + (orbitTo - orbitFrom) * GrokBotGeometry.clamp(morph, 0, 1)
    }

    private func ensureLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTick = nil
    }

    private func stopLinkIfIdle() {
        if window != nil { return }
        displayLink?.invalidate()
        displayLink = nil
        lastTick = nil
    }

    private func scheduleBlink() {
        blinkWork?.cancel()
        if expressionName == "sleepy" || expressionName == "error" { return }
        let delay = Double.random(in: 6...12)
        let work = DispatchWorkItem { [weak self] in
            self?.blink()
            self?.scheduleBlink()
        }
        blinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let previous = lastTick
        lastTick = now
        guard let previous else { return }
        let rawDt = min(now - previous, 0.1)

        let morphing = abs(morph - 1) >= 0.001 || abs(velocity) >= 0.001
        if morphing {
            var remaining = CGFloat(rawDt)
            let omega = GrokBotGeometry.springFrequency
            while remaining > 0 {
                let step = min(remaining, 1 / 120)
                velocity += (-2 * omega * velocity - omega * omega * (morph - 1)) * step
                morph += velocity * step
                remaining -= step
            }
            if abs(morph - 1) < 0.001, abs(velocity) < 0.001 {
                morph = 1
                velocity = 0
                currentRings = targetRings
            }
        }

        if var t = blinkT {
            t += CGFloat(rawDt)
            if t >= GrokBotGeometry.blinkDuration {
                blinkT = nil
                blinkScale = 1
            } else {
                blinkT = t
                let progress = t / GrokBotGeometry.blinkDuration
                let open = progress < 0.42 ? 1 - progress / 0.42 : (progress - 0.42) / 0.58
                blinkScale = max(open, 0.04)
            }
        }

        if displayedOrbit > 0.02 {
            orbitAngle += CGFloat(rawDt) * 0.85
        }
        if let motion {
            liveGaze = motion.gaze
            liveTurn = motion.turn
            jiggle = motion.jiggle
            dizzy = motion.dizzy
        }
        if dizzy > 0.02 {
            dizzySpin += CGFloat(rawDt) * (7 + 6 * dizzy)
        }

        setNeedsDisplay()
        stopLinkIfIdle()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let side = min(bounds.width, bounds.height)
        guard side > 1 else { return }

        ctx.saveGState()
        ctx.translateBy(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2)
        ctx.scaleBy(x: side / GrokBotGeometry.viewBox, y: side / GrokBotGeometry.viewBox)
        ctx.translateBy(x: GrokBotGeometry.inset + jiggle * 0.35, y: GrokBotGeometry.inset)
        if dizzy > 0.02 {
            let origin = CGPoint(x: GrokBotGeometry.faceCenter, y: GrokBotGeometry.faceCenter)
            let wobble = sin(dizzySpin * 1.7) * 0.22 * dizzy
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.rotate(by: wobble)
            ctx.scaleBy(x: 1 + 0.05 * sin(dizzySpin * 2.3) * dizzy, y: 1 - 0.04 * sin(dizzySpin * 2.3) * dizzy)
            ctx.translateBy(x: -origin.x, y: -origin.y)
        }

        let bodyColor = lightTheme
            ? UIColor(red: 0.95, green: 0.94, blue: 0.90, alpha: 1)
            : UIColor(red: 0.07, green: 0.07, blue: 0.06, alpha: 1)
        let eyeColor = lightTheme
            ? UIColor(red: 0.09, green: 0.10, blue: 0.08, alpha: 1)
            : UIColor(red: 1, green: 0.99, blue: 0.97, alpha: 1)

        let origin = CGPoint(x: GrokBotGeometry.faceCenter, y: GrokBotGeometry.faceCenter)
        let bang = displayedBang
        let orbit = displayedOrbit
        let body = GrokBotGeometry.cubicPath(displayedBody())

        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 18, color: UIColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(bodyColor.withAlphaComponent(1 - 0.92 * bang).cgColor)
        ctx.addPath(body.cgPath)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        if bang > 0.04 {
            let shake = 2.2 * sin(42 * bang) * (0.4 + 0.6 * bang)
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y + 8 * bang)
            ctx.rotate(by: shake * .pi / 180)
            ctx.translateBy(x: -origin.x, y: -origin.y)
            ctx.setFillColor(bodyColor.withAlphaComponent(min(1, bang * 1.2)).cgColor)
            let bar = UIBezierPath(
                roundedRect: CGRect(x: origin.x - 16, y: origin.y - 78, width: 32, height: 98),
                cornerRadius: 16
            )
            ctx.addPath(bar.cgPath)
            ctx.fillPath()
            let dot = UIBezierPath(ovalIn: CGRect(x: origin.x - 13, y: origin.y + 38, width: 26, height: 26))
            ctx.addPath(dot.cgPath)
            ctx.fillPath()
            ctx.restoreGState()
        }

        let whirl = max(orbit, dizzy * 0.95)
        if whirl > 0.04 {
            drawOrbit(ctx: ctx, origin: origin, amount: whirl, angle: orbitAngle + dizzySpin * 0.65)
        }

        if bang < 0.85 {
            ctx.saveGState()
            ctx.addPath(body.cgPath)
            ctx.clip()
            ctx.setAlpha(1 - bang)

            let rings = displayedRings()
            let poseGaze = GrokBotGeometry.gaze(for: expressionName)
            let blend: CGFloat = (expressionName == "listen" || expressionName == "speak" || expressionName == "error") ? 0.12 : 0.22
            let gaze = GrokBotGeometry.mappedGaze(CGPoint(
                x: poseGaze.x + liveGaze.x * blend,
                y: poseGaze.y + liveGaze.y * blend
            ))
            let turn = GrokBotGeometry.turn(for: expressionName) + liveTurn * blend
            let radius: CGFloat = 105

            for ring in rings {
                let center = GrokBotGeometry.centroid(ring)
                let projection = GrokBotGeometry.projectEye(
                    centroid: center,
                    origin: origin,
                    radius: radius,
                    turn: turn,
                    gaze: gaze,
                    scale: 1,
                    blinkScale: blinkScale
                )
                guard projection.visible else { continue }
                ctx.saveGState()
                ctx.translateBy(x: projection.center.x, y: projection.center.y)
                if dizzy > 0.04 {
                    ctx.rotate(by: dizzySpin * (0.9 + dizzy))
                }
                ctx.scaleBy(x: projection.scaleX, y: projection.scaleY)
                ctx.translateBy(x: -center.x, y: -center.y)
                ctx.setFillColor(eyeColor.cgColor)
                ctx.addPath(GrokBotGeometry.cubicPath(ring).cgPath)
                ctx.fillPath()
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private func drawOrbit(ctx: CGContext, origin: CGPoint, amount: CGFloat, angle: CGFloat) {
        let colors: [UIColor] = [
            UIColor(red: 0.95, green: 0.42, blue: 0.72, alpha: 1),
            UIColor(red: 0.45, green: 0.72, blue: 1.0, alpha: 1),
            UIColor(red: 0.45, green: 0.95, blue: 0.62, alpha: 1),
            UIColor(red: 0.98, green: 0.72, blue: 0.28, alpha: 1),
        ]
        ctx.saveGState()
        ctx.setAlpha(0.88 * amount)
        ctx.translateBy(x: origin.x, y: origin.y)
        for (index, color) in colors.enumerated() {
            ctx.saveGState()
            ctx.rotate(by: angle * (index.isMultiple(of: 2) ? 1 : -0.7) + CGFloat(index) * 0.4)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(3.2 - CGFloat(index) * 0.35)
            ctx.setLineCap(.round)
            let inset = 18 + CGFloat(index) * 7
            ctx.strokeEllipse(in: CGRect(x: -118 - inset * 0.08, y: -46 - CGFloat(index) * 4, width: 236, height: 92 + CGFloat(index) * 6))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}

struct GrokBotFaceView: UIViewRepresentable {
    var expression: String
    var size: CGFloat
    var light: Bool
    var motion: MotionSense

    func makeUIView(context: Context) -> GrokBotCanvasView {
        let view = GrokBotCanvasView()
        view.lightTheme = light
        view.motion = motion
        view.setExpression(expression)
        return view
    }

    func updateUIView(_ view: GrokBotCanvasView, context: Context) {
        view.lightTheme = light
        view.motion = motion
        view.setExpression(expression)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: GrokBotCanvasView, context: Context) -> CGSize {
        CGSize(width: size, height: size)
    }
}
