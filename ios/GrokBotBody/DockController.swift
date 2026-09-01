import Foundation
import Combine    // ObservableObject / @Published（Xcode 26 需显式导入）
import DockKit
import Spatial   // Rotation3D / Angle2D / RotationAxis3D

// 云台控制器。
//  1) 监听连接；吸上后默认开人脸/人体追踪
//  2) 语音或 Bot 要做点头左转时，先让一下追踪，做完再跟回去
//
// 注意：DockKit 的类型/字段名以 Xcode 的自动补全为准。若某行编译报错，多半是
// 名字或签名和这里略有出入——把报错发我，或按补全改（常见出入点见 ios/README.md）。

@MainActor
final class DockController: ObservableObject {
    @Published var status: String = "先启动相机，等 DockKit 连接…"
    @Published var detail: String = "DockKit 需要相机运行后才会报告 docked/undocked。"
    @Published var connected: Bool = false
    @Published var isMoving: Bool = false     // 云台正在执行动作（用来区分"被人转"和"自己动"）
    @Published var tracking: Bool = false
    private var trackingWanted = true
    private var wasDocked = false
    private var lookAtTask: Task<Void, Never>?
    private var enablingTracking = false

    private var accessory: DockAccessory?
    private var listenerTask: Task<Void, Never>?
    private var motionTask: Task<Void, Never>?
    private var soulPanOffset = 0.0
    private var soulTiltOffset = 0.0
    private let soulPanLimit = 42.0
    private let soulTiltLimit = 22.0
    private let soulPanStepLimit = 24.0
    private let soulTiltStepLimit = 14.0

    // 监听云台的连接/断开
    func startListening() {
        guard listenerTask == nil else { return }

        connected = false
        status = "等云台 DockKit 连接…"
        detail = "把 iPhone 吸到 Flow 2 Pro 磁吸座，保持 app 在前台。"

        listenerTask = Task {
            do {
                for try await event in try DockAccessoryManager.shared.accessoryStateChanges {
                    await self.handle(event)
                }
            } catch {
                self.connected = false
                self.status = "DockKit 出错：\(error.localizedDescription)"
                self.detail = "如果刚拒绝了相机权限，请到系统设置里打开相机。"
            }
        }
    }

    func restartListening() {
        listenerTask?.cancel()
        listenerTask = nil
        accessory = nil
        connected = false
        status = "重新检测 DockKit…"
        detail = "如果云台已配对但仍是 undocked，先把手机拿下再重新吸到磁吸座。"
        startListening()
    }

    private func handle(_ event: DockAccessory.StateChange) async {
        detail = describe(event)

        switch event.state {
        case .docked:
            guard let dockAccessory = event.accessory else {
                accessory = nil
                connected = false
                status = "DockKit 已 docked，但没有返回云台对象"
                return
            }

            let firstDock = !wasDocked
            wasDocked = true
            accessory = dockAccessory
            connected = true
            resetSoulOffset()
            status = "\(dockAccessory.identifier.name) 已连接"
            if firstDock {
                trackingWanted = true
                scheduleLookAtMe()
            }
        case .undocked:
            wasDocked = false
            lookAtTask?.cancel()
            accessory = nil
            connected = false
            tracking = false
            enablingTracking = false
            resetSoulOffset()
            status = "DockKit 仍是 undocked"
            detail += "\n蓝牙/NFC 配对成功不等于 DockKit docked。请确认手机已经吸在云台磁吸座上，并且相机权限已允许。"
        @unknown default:
            accessory = nil
            connected = false
            status = "DockKit 返回了未知状态"
            detail += "\n这可能是新版 iOS/DockKit 新增状态。先重新检测一次。"
        }
    }

    private func describe(_ event: DockAccessory.StateChange) -> String {
        var parts = [
            "state: \(event.state.debugDescription)",
            "tracking button: \(event.trackingButtonEnabled ? "on" : "off")",
            "system tracking: \(DockAccessoryManager.shared.isSystemTrackingEnabled ? "on" : "off")"
        ]

        if let accessory = event.accessory {
            parts.append("name: \(accessory.identifier.name)")
            if let model = accessory.hardwareModel {
                parts.append("model: \(model)")
            }
            if let firmware = accessory.firmwareVersion {
                parts.append("fw: \(firmware)")
            }
        } else {
            parts.append("accessory: nil")
        }

        return parts.joined(separator: " · ")
    }

    private struct MotionStep {
        let axis: RotationAxis3D
        let degrees: Double
        let duration: TimeInterval
        let pauseAfter: Duration

        init(_ axis: RotationAxis3D, _ degrees: Double, _ duration: TimeInterval, pauseAfter: Duration = .milliseconds(80)) {
            self.axis = axis
            self.degrees = degrees
            self.duration = duration
            self.pauseAfter = pauseAfter
        }
    }

    private struct VelocityStep {
        let velocity: Vector3D
        let duration: Duration

        init(yaw: Double, duration: Duration) {
            self.velocity = Vector3D(x: 0, y: yaw, z: 0)
            self.duration = duration
        }
    }

    private func runAnimation(_ animation: DockAccessory.Animation, named name: String, fallback: [MotionStep]) {
        guard let accessory else {
            status = "还没连上云台"
            return
        }

        motionTask?.cancel()
        status = "正在\(name)…"
        isMoving = true

        motionTask = Task {
            defer { finishScriptedMove() }
            do {
                try? await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
                tracking = false
                let progress = try await accessory.animate(motion: animation)
                try await waitFor(progress, timeout: 2.0)
                status = "\(name)完成"
            } catch is CancellationError {
                // Newer button tap replaced this motion.
            } catch {
                await runMotionSteps(fallback, named: name, using: accessory)
            }
        }
    }

    private func runMotion(_ steps: [MotionStep], named name: String) {
        guard let accessory else {
            status = "还没连上云台"
            return
        }

        motionTask?.cancel()
        status = "正在\(name)…"
        isMoving = true
        motionTask = Task {
            defer { finishScriptedMove() }
            try? await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
            tracking = false
            await runMotionSteps(steps, named: name, using: accessory)
        }
    }

    // ---- Mac 运动皮层编的动作谱 → 云台 ----
    // 每帧 pan(左右,+右) / tilt(上下,+抬头) / speed(0..1) / hold(停几秒)，都是相对当前再转多少。
    struct Keyframe {
        let pan: Double
        let tilt: Double
        let speed: Double
        let hold: Double
    }

    func playScore(_ frames: [Keyframe]) {
        guard !frames.isEmpty else { return }
        let steps = stepsForSoulScore(frames)
        guard !steps.isEmpty else { return }
        runMotion(steps, named: "反应")
    }

    private func stepsForSoulScore(_ frames: [Keyframe]) -> [MotionStep] {
        var steps: [MotionStep] = []
        var nextPan = soulPanOffset
        var nextTilt = soulTiltOffset

        for f in frames.prefix(5) {
            let dur = max(0.12, min(0.9, 0.15 + (1 - f.speed) * 0.6))   // 快=短
            let hold = Duration.seconds(max(0, min(2, f.hold)))
            let pan = clampedSoulDelta(f.pan, current: &nextPan, limit: soulPanLimit, stepLimit: soulPanStepLimit)
            let tilt = clampedSoulDelta(f.tilt, current: &nextTilt, limit: soulTiltLimit, stepLimit: soulTiltStepLimit)
            let hasPan = abs(pan) > 0.5
            let hasTilt = abs(tilt) > 0.5
            if hasPan {
                steps.append(MotionStep(.y, pan, dur, pauseAfter: hasTilt ? .milliseconds(30) : hold))
            }
            if hasTilt {
                steps.append(MotionStep(.x, -tilt, dur, pauseAfter: hold))  // X- = 抬头，故 tilt 取反
            }
            if !hasPan && !hasTilt {
                steps.append(MotionStep(.x, 0, dur, pauseAfter: hold))        // 纯停顿
            }
        }

        // LLM 给的是相对动作；真实云台也按相对动作执行。这里给每段反应一点回收，
        // 避免一连串视觉反应把头越带越偏，最后变成一直右转或一直仰头。
        let recenterPan = abs(nextPan) > 4 ? -nextPan * 0.72 : 0
        let recenterTilt = abs(nextTilt) > 4 ? -nextTilt * 0.55 : 0
        if abs(recenterPan) > 1.5 {
            steps.append(MotionStep(.y, recenterPan, 0.42, pauseAfter: abs(recenterTilt) > 1.5 ? .milliseconds(30) : .milliseconds(120)))
            nextPan += recenterPan
        }
        if abs(recenterTilt) > 1.5 {
            steps.append(MotionStep(.x, -recenterTilt, 0.42, pauseAfter: .milliseconds(120)))
            nextTilt += recenterTilt
        }

        soulPanOffset = nextPan
        soulTiltOffset = nextTilt
        return steps
    }

    private func clampedSoulDelta(_ requested: Double, current: inout Double, limit: Double, stepLimit: Double) -> Double {
        var delta = max(-stepLimit, min(stepLimit, requested))
        let projected = current + delta
        if projected > limit {
            delta = limit - current
        } else if projected < -limit {
            delta = -limit - current
        }
        if abs(delta) < 0.5 {
            delta = 0
        }
        current += delta
        return delta
    }

    private func resetSoulOffset() {
        soulPanOffset = 0
        soulTiltOffset = 0
    }

    func prepareForUserControl() {
        motionTask?.cancel()
        resetSoulOffset()
        isMoving = false
    }

    private func runVelocity(_ steps: [VelocityStep], named name: String) {
        guard let accessory else {
            status = "还没连上云台"
            return
        }

        motionTask?.cancel()
        status = "正在\(name)…"
        isMoving = true
        motionTask = Task {
            defer { finishScriptedMove() }
            do {
                try? await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
                tracking = false
                for step in steps {
                    try Task.checkCancellation()
                    try await accessory.setAngularVelocity(step.velocity)
                    try await Task.sleep(for: step.duration)
                }
                try await accessory.setAngularVelocity(.zero)
                status = "\(name)完成"
            } catch is CancellationError {
                try? await accessory.setAngularVelocity(.zero)
            } catch {
                try? await accessory.setAngularVelocity(.zero)
                status = "\(name)出错：\(error.localizedDescription)"
            }
        }
    }

    private func runMotionSteps(_ steps: [MotionStep], named name: String, using accessory: DockAccessory) async {
        do {
            for step in steps {
                try Task.checkCancellation()
                let rotation = Rotation3D(angle: Angle2D(degrees: step.degrees), axis: step.axis)
                let progress = try await accessory.setOrientation(rotation, duration: .seconds(step.duration), relative: true)
                try await waitFor(progress, timeout: step.duration + 0.7)
                if step.pauseAfter > .zero {
                    try await Task.sleep(for: step.pauseAfter)
                }
            }
            status = "\(name)完成"
        } catch is CancellationError {
            // Newer button tap replaced this motion.
        } catch {
            status = "\(name)出错：\(error.localizedDescription)"
        }
    }

    private func waitFor(_ progress: Progress, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !progress.isFinished && !progress.isCancelled && Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    // ---- 四个基本动作（G0）----

    func nod() {
        runAnimation(
            .yes,
            named: "点头",
            fallback: [
                // Flow 2 Pro 实测：X 轴正方向是低头，负方向是抬头。
                MotionStep(.x, 12, 0.28),
                MotionStep(.x, -12, 0.28)
            ]
        )
    }

    func shake() {
        runVelocity([
            VelocityStep(yaw: -0.9, duration: .milliseconds(280)),
            VelocityStep(yaw: 0.9, duration: .milliseconds(560)),
            VelocityStep(yaw: -0.9, duration: .milliseconds(280))
        ], named: "摇头")
    }

    func turnLeft() {
        runMotion([MotionStep(.y, -12, 0.24)], named: "左转")
    }

    func turnRight() {
        runMotion([MotionStep(.y, 12, 0.24)], named: "右转")
    }

    func perk() {
        runMotion([MotionStep(.x, -15, 0.32)], named: "抬头")
    }

    func droop() {
        runMotion([MotionStep(.x, 15, 0.45)], named: "耷下")
    }

    func lookAtMe() {
        trackingWanted = true
        scheduleLookAtMe(soon: true)
    }

    private func scheduleLookAtMe(soon: Bool = false) {
        guard trackingWanted, accessory != nil else { return }
        lookAtTask?.cancel()
        lookAtTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(soon ? 120 : 450))
            guard !Task.isCancelled else { return }
            await self?.enableTrackingNow()
        }
    }

    private func enableTrackingNow() async {
        guard trackingWanted, let accessory, !enablingTracking else { return }
        if tracking { return }
        enablingTracking = true
        defer { enablingTracking = false }
        do {
            try? await accessory.setAngularVelocity(.zero)
            try await DockAccessoryManager.shared.setSystemTrackingEnabled(true)
            try await accessory.setFramingMode(.center)
            tracking = true
            status = "正在看着你"
            detail = "人脸追踪开着。人在画面里会跟。"
        } catch {
            tracking = false
            status = "看着我失败：\(error.localizedDescription)"
        }
    }

    func stopMotion() {
        guard let accessory else {
            status = "还没连上云台"
            return
        }

        motionTask?.cancel()
        motionTask = Task {
            try? await accessory.setAngularVelocity(.zero)
            isMoving = false
            status = "已停止"
            if trackingWanted {
                scheduleLookAtMe()
            }
        }
    }

    func spin() {
        runVelocity([
            VelocityStep(yaw: 0.8, duration: .milliseconds(400)),
            VelocityStep(yaw: 0.8, duration: .milliseconds(400)),
            VelocityStep(yaw: 0.8, duration: .milliseconds(400)),
            VelocityStep(yaw: 0.8, duration: .milliseconds(400)),
        ], named: "转圈")
    }

    func setTrackingEnabled(_ enabled: Bool) async {
        trackingWanted = enabled
        guard accessory != nil else {
            status = "还没连上云台"
            return
        }
        if enabled {
            lookAtMe()
            return
        }
        motionTask?.cancel()
        do {
            try await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
            tracking = false
            status = "已停止跟随"
        } catch {
            status = "停止跟随失败：\(error.localizedDescription)"
        }
    }

    private func finishScriptedMove() {
        isMoving = false
        if trackingWanted {
            scheduleLookAtMe()
        }
    }

    func performAction(_ action: String) async -> (ok: Bool, message: String) {
        switch action {
        case "nod": nod()
        case "shake": shake()
        case "turn_left": turnLeft()
        case "turn_right": turnRight()
        case "spin": spin()
        case "head_up": perk()
        case "head_down": droop()
        default:
            return (false, "unknown action")
        }
        await waitUntilIdle(timeout: 6)
        return (connected, status)
    }

    private func waitUntilIdle(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(80))
        while isMoving && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(80))
        }
    }
}
