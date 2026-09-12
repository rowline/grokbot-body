// Face painter. Morphs follow jeremy-prt/bloub: radial silhouette,
// spherical capsule eyes, exponential ease-out. No springs.

import QuartzCore
import SwiftUI
import UIKit

final class GrokBotCanvasView: UIView {
    var lightTheme = true {
        didSet { setNeedsDisplay() }
    }
    var bodyColor = UIColor(red: 0.95, green: 0.94, blue: 0.90, alpha: 1) {
        didSet { setNeedsDisplay() }
    }
    var eyeColor = UIColor(red: 0.09, green: 0.10, blue: 0.08, alpha: 1) {
        didSet { setNeedsDisplay() }
    }
    weak var motion: MotionSense?
    private let engine = BloubEngine()
    private var displayLink: CADisplayLink?
    private var start: CFTimeInterval?
    private var lastIMULook = Bloub.Look.none
    private var lastRub = Bloub.Rub.none
    private var lastTouch: CGPoint?
    private var orbitAngle: CGFloat = 0
    private var lastTick: CFTimeInterval?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { nil }

    deinit { displayLink?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else {
            ensureLink()
        }
    }

    func setExpression(_ name: String) {
        engine.setState(name, now: now())
        ensureLink()
        setNeedsDisplay()
    }

    func setSkin(rest: String, shape: String) {
        engine.setSkin(rest: rest, shape: shape, now: now())
        ensureLink()
        setNeedsDisplay()
    }

    func setTouch(_ point: CGPoint?, in size: CGSize) {
        if point == nil, lastTouch == nil { return }
        if let point, let lastTouch, hypot(point.x - lastTouch.x, point.y - lastTouch.y) < 0.6 {
            return
        }
        lastTouch = point
        let t = now()
        if let point, size.width > 1, size.height > 1 {
            let dx = (point.x - size.width / 2) / (size.width / 2)
            let dy = (point.y - size.height / 2) / (size.height / 2)
            let dist = hypot(dx, dy)
            let nx = dist > 0.001 ? dx / dist : 0
            let ny = dist > 0.001 ? dy / dist : 0
            let look = Bloub.Look(
                yaw: Bloub.clamp(dx, -1, 1) * 48,
                pitch: Bloub.clamp(-dy, -1, 1) * 36,
                mix: 1,
                wander: 0
            )
            engine.setLook(look, now: t)
            lastIMULook = look
            let rub = Bloub.Rub(nx: nx, ny: ny, press: max(Bloub.clamp(dist, 0, 1), 0.2))
            engine.setRub(rub, now: t)
            lastRub = rub
        } else {
            engine.setLook(imuLook(), now: t)
            lastIMULook = imuLook()
            engine.setRub(.none, now: t)
            lastRub = .none
        }
        ensureLink()
        setNeedsDisplay()
    }

    func setIMULook() {
        guard lastRub.press < 0.02 else { return }
        let look = imuLook()
        if abs(look.yaw - lastIMULook.yaw) > 1.2 || abs(look.pitch - lastIMULook.pitch) > 1.2 {
            engine.setLook(look, now: now())
            lastIMULook = look
        }
    }

    private func imuLook() -> Bloub.Look {
        let gaze = motion?.gaze ?? .zero
        let turn = motion?.turn ?? 0
        let mix = (abs(gaze.x) + abs(gaze.y) + abs(turn)) > 0.08 ? 0.55 : 0
        return Bloub.Look(
            yaw: Bloub.clamp(gaze.x, -1, 1) * 38 + turn * 40,
            pitch: Bloub.clamp(-gaze.y, -1, 1) * 26,
            mix: mix,
            wander: mix > 0.2 ? 0.25 : 1
        )
    }

    private func now() -> CGFloat {
        CGFloat(CACurrentMediaTime() - (start ?? CACurrentMediaTime()))
    }

    private func ensureLink() {
        if start == nil { start = CACurrentMediaTime() }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt: CGFloat
        if let lastTick {
            dt = CGFloat(min(link.timestamp - lastTick, 0.05))
        } else {
            dt = 0.016
        }
        lastTick = link.timestamp
        orbitAngle += dt * 2.2
        setIMULook()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let side = min(bounds.width, bounds.height)
        guard side > 1 else { return }
        let pose = engine.sample(now())
        let scale = side * 0.38
        let origin = CGPoint(x: bounds.midX, y: bounds.midY)

        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)

        let bodyColor = self.bodyColor
        let eyeColor = self.eyeColor

        let dizzy = motion?.dizzy ?? 0
        if pose.orbit > 0.04 || dizzy > 0.04 {
            drawOrbit(ctx: ctx, amount: max(pose.orbit, dizzy), scale: scale)
        }
        if dizzy > 0.04 {
            ctx.rotate(by: sin(orbitAngle * 1.4) * 0.2 * dizzy)
        }

        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 18, color: UIColor.black.withAlphaComponent(0.28).cgColor)
        if pose.showBang {
            drawBang(ctx: ctx, color: bodyColor, scale: scale)
        } else {
            let body = Bloub.closedPath(Bloub.points(pose.sil, scale: scale))
            ctx.setFillColor(bodyColor.withAlphaComponent(pose.bodyAlpha).cgColor)
            ctx.addPath(body.cgPath)
            ctx.fillPath()
        }
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        if pose.eyeAlpha > 0.02, !pose.showBang {
            drawEyes(ctx: ctx, pose: pose, scale: scale, color: eyeColor)
        }
        ctx.restoreGState()
    }

    private func drawEyes(ctx: CGContext, pose: Bloub.Pose, scale: CGFloat, color: UIColor) {
        let poses = Bloub.eyePoses(pose.gaze, scale: scale, split: pose.split)
        let pair = [pose.eyes.0, pose.eyes.1]
        let eyePos = [poses.0, poses.1]
        for i in 0..<2 {
            let e = eyePos[i]
            guard e.depth > 0.02 else { continue }
            let cfg = pair[i]
            let fit = Bloub.radiusAtAngle(pose.sil.radii, atan2(e.y, e.x) - pose.sil.rot)
            let phi = cfg.tilt * .pi / 180
            let cp = cos(phi)
            let sp = sin(phi)
            let ax = e.a * cp + e.c * sp
            let ay = e.b * cp + e.d * sp
            let cx2 = -e.a * sp + e.c * cp
            let cy2 = -e.b * sp + e.d * cp
            let k = Bloub.blinkScale(cfg.open)
            ctx.saveGState()
            ctx.translateBy(x: e.x * fit + pose.offX * scale, y: e.y * fit + pose.offY * scale)
            ctx.concatenate(CGAffineTransform(a: ax, b: ay * k, c: cx2, d: cy2 * k, tx: 0, ty: 0))
            ctx.setFillColor(color.withAlphaComponent(pose.eyeAlpha * Bloub.clamp(e.depth / 0.12)).cgColor)
            ctx.addPath(Bloub.capsule(w: cfg.w * scale, h: cfg.h * scale).cgPath)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    private func drawBang(ctx: CGContext, color: UIColor, scale: CGFloat) {
        ctx.setFillColor(color.cgColor)
        let bar = UIBezierPath(roundedRect: CGRect(x: -0.13 * scale, y: -0.72 * scale, width: 0.26 * scale, height: 0.92 * scale), cornerRadius: 0.13 * scale)
        ctx.addPath(bar.cgPath)
        ctx.fillPath()
        ctx.fillEllipse(in: CGRect(x: -0.12 * scale, y: 0.38 * scale, width: 0.24 * scale, height: 0.24 * scale))
    }

    private func drawOrbit(ctx: CGContext, amount: CGFloat, scale: CGFloat) {
        let hues: [(CGFloat, CGFloat, CGFloat)] = [
            (0.95, 0.42, 0.72),
            (0.45, 0.72, 1.0),
            (0.45, 0.95, 0.62),
            (0.98, 0.72, 0.28),
            (0.62, 0.48, 1.0),
            (1.0, 0.55, 0.38),
        ]
        ctx.saveGState()
        ctx.setAlpha(0.82 * amount)
        ctx.setLineCap(.round)
        for (i, hue) in hues.enumerated() {
            ctx.saveGState()
            ctx.rotate(by: orbitAngle * (i.isMultiple(of: 2) ? 1 : -0.72) + CGFloat(i) * 0.45)
            ctx.setStrokeColor(UIColor(red: hue.0, green: hue.1, blue: hue.2, alpha: 1).cgColor)
            ctx.setLineWidth((0.055 - CGFloat(i) * 0.004) * scale)
            let a = (1.32 + CGFloat(i) * 0.02) * scale
            let k: CGFloat = 0.18 + CGFloat(i) * 0.05
            ctx.strokeEllipse(in: CGRect(x: -a, y: -a * k, width: a * 2, height: a * 2 * k))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}

struct GrokBotFaceView: UIViewRepresentable {
    var expression: String
    var size: CGFloat
    var light: Bool
    var color: String = "creme"
    var shape: String = "cercle"
    var rest: String = "idle"
    var motion: MotionSense
    var touch: CGPoint?

    func makeUIView(context: Context) -> GrokBotCanvasView {
        let view = GrokBotCanvasView()
        view.lightTheme = light
        view.bodyColor = BloubSkin.bodyUIColor(for: color)
        view.eyeColor = BloubSkin.eyeUIColor(for: color)
        view.motion = motion
        view.setSkin(rest: rest, shape: shape)
        view.setExpression(expression)
        return view
    }

    func updateUIView(_ view: GrokBotCanvasView, context: Context) {
        view.lightTheme = light
        view.bodyColor = BloubSkin.bodyUIColor(for: color)
        view.eyeColor = BloubSkin.eyeUIColor(for: color)
        view.motion = motion
        view.setSkin(rest: rest, shape: shape)
        view.setExpression(expression)
        view.setTouch(touch, in: CGSize(width: size, height: size))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: GrokBotCanvasView, context: Context) -> CGSize {
        CGSize(width: size, height: size)
    }
}
