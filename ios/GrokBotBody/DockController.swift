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
    private var listenerStartedAt = Date.distantPast
    private var cameraReady = false
    private var motionTask: Task<Void, Never>?
    private var moveGeneration = 0
    private var moveOutcome: (ok: Bool, message: String) = (false, "还没动过")
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
        listenerStartedAt = Date()
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

    // 相机没真正跑起来之前，DockKit 不会报 docked。启动时 scenePhase 先于 boot() 变 active，
    // 于是监听可能建在相机起来之前——那条流收不到 docked，跟随就一直不开。
    func noteCameraReady() {
        guard !cameraReady else { return }
        cameraReady = true
        if listenerTask != nil, !connected {
            restartListening()
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
            }
            if trackingWanted, !tracking {
                scheduleLookAtMe(soon: true)
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

    private struct MoveTimeout: Error {}

    // 开一个脚本动作。这里必须把排队中的"跟回去"一起取消：lookAtTask 触发的
    // enableTrackingNow 会重新打开系统人脸追踪，云台随即把脚本动作覆盖掉——
    // 看上去就是"没动，但报告完成"。
    private func beginScriptedMove(named name: String) -> Int {
        lookAtTask?.cancel()
        lookAtTask = nil
        motionTask?.cancel()
        moveGeneration += 1
        status = "正在\(name)…"
        moveOutcome = (false, "\(name)没做完")
        isMoving = true
        return moveGeneration
    }

    private func recordOutcome(_ ok: Bool, _ message: String, token: Int) {
        guard token == moveGeneration else { return }   // 已被更新的动作接管
        moveOutcome = (ok, message)
        status = message
    }

    private func failBeforeMoving(_ message: String) {
        status = message
        moveOutcome = (false, message)
    }

    // DockKit 规定：系统追踪开着时调 setAngularVelocity 会直接 fatalError
    // （"API violation: setting velocity only supported when system tracking disabled"），
    // 是 trap 不是抛错，try? 挡不住。所以每次动速度前都得先确认追踪是关的。
    private func stopVelocityIfAllowed(_ accessory: DockAccessory) async {
        guard !DockAccessoryManager.shared.isSystemTrackingEnabled else { return }
        try? await accessory.setAngularVelocity(.zero)
    }

    // 系统人脸追踪开着时云台不听脚本指令。关不掉就别假装动过。
    private func takeManualControl(named name: String, token: Int) async -> Bool {
        do {
            try await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
        } catch {
            recordOutcome(false, "\(name)没做成：关不掉人脸追踪（\(error.localizedDescription)）", token: token)
            return false
        }
        tracking = false
        return true
    }

    // 动作跑完再看一眼：中途要是有人/有代码把系统追踪打开，云台已经把动作拉回去了。
    private func confirmTrackingStayedOff(named name: String, token: Int) {
        guard token == moveGeneration, moveOutcome.ok else { return }
        if DockAccessoryManager.shared.isSystemTrackingEnabled {
            recordOutcome(false, "\(name)被覆盖：人脸追踪中途又打开了，云台转回了人脸", token: token)
        }
    }

    private func runAnimation(_ animation: DockAccessory.Animation, named name: String, fallback: [MotionStep]) {
        guard let accessory else {
            failBeforeMoving("还没连上云台")
            return
        }

        let token = beginScriptedMove(named: name)
        motionTask = Task {
            defer { finishScriptedMove(token) }
            guard await takeManualControl(named: name, token: token) else { return }
            do {
                let progress = try await accessory.animate(motion: animation)
                try await waitFor(progress, timeout: 6.0)
                recordOutcome(true, "\(name)完成", token: token)
            } catch is CancellationError {
                // Newer button tap replaced this motion.
            } catch is MoveTimeout {
                recordOutcome(false, "\(name)没回报完成：云台 6 秒内没执行完", token: token)
            } catch {
                await runMotionSteps(fallback, named: name, using: accessory, token: token)
            }
            confirmTrackingStayedOff(named: name, token: token)
        }
    }

    private func runMotion(_ steps: [MotionStep], named name: String) {
        guard let accessory else {
            failBeforeMoving("还没连上云台")
            return
        }

        let token = beginScriptedMove(named: name)
        motionTask = Task {
            defer { finishScriptedMove(token) }
            guard await takeManualControl(named: name, token: token) else { return }
            await runMotionSteps(steps, named: name, using: accessory, token: token)
            confirmTrackingStayedOff(named: name, token: token)
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
        lookAtTask?.cancel()
        motionTask?.cancel()
        moveGeneration += 1
        resetSoulOffset()
        isMoving = false
    }

    private func runVelocity(_ steps: [VelocityStep], named name: String) {
        guard let accessory else {
            failBeforeMoving("还没连上云台")
            return
        }

        let token = beginScriptedMove(named: name)
        motionTask = Task {
            defer { finishScriptedMove(token) }
            guard await takeManualControl(named: name, token: token) else { return }
            do {
                for step in steps {
                    try Task.checkCancellation()
                    guard !DockAccessoryManager.shared.isSystemTrackingEnabled else {
                        recordOutcome(false, "\(name)被打断：人脸追踪中途被打开", token: token)
                        return
                    }
                    try await accessory.setAngularVelocity(step.velocity)
                    try await Task.sleep(for: step.duration)
                }
                await stopVelocityIfAllowed(accessory)
                recordOutcome(true, "\(name)完成", token: token)
            } catch is CancellationError {
                await stopVelocityIfAllowed(accessory)
            } catch {
                await stopVelocityIfAllowed(accessory)
                recordOutcome(false, "\(name)出错：\(error.localizedDescription)", token: token)
            }
            confirmTrackingStayedOff(named: name, token: token)
        }
    }

    private func runMotionSteps(_ steps: [MotionStep], named name: String, using accessory: DockAccessory, token: Int) async {
        do {
            for step in steps {
                try Task.checkCancellation()
                guard !DockAccessoryManager.shared.isSystemTrackingEnabled else {
                    recordOutcome(false, "\(name)被打断：人脸追踪中途被打开", token: token)
                    return
                }
                let rotation = Rotation3D(angle: Angle2D(degrees: step.degrees), axis: step.axis)
                let progress = try await accessory.setOrientation(rotation, duration: .seconds(step.duration), relative: true)
                try await waitFor(progress, timeout: max(2.0, step.duration + 0.7))
                if step.pauseAfter > .zero {
                    try await Task.sleep(for: step.pauseAfter)
                }
            }
            recordOutcome(true, "\(name)完成", token: token)
        } catch is CancellationError {
            // Newer button tap replaced this motion.
        } catch is MoveTimeout {
            recordOutcome(false, "\(name)没做完：云台没回报执行完", token: token)
        } catch {
            recordOutcome(false, "\(name)出错：\(error.localizedDescription)", token: token)
        }
    }

    // 超时不是"做完了"。转不动、指令被吞掉的时候 progress 不会结束，这里要报失败。
    private func waitFor(_ progress: Progress, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !progress.isFinished && !progress.isCancelled && Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(40))
        }
        if !progress.isFinished && !progress.isCancelled {
            throw MoveTimeout()
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
        guard trackingWanted, accessory != nil, !isMoving else { return }
        lookAtTask?.cancel()
        lookAtTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(soon ? 120 : 450))
            guard !Task.isCancelled else { return }
            await self?.enableTrackingNow()
        }
    }

    func ensureAttachedAndTracking() {
        if connected {
            if trackingWanted {
                scheduleLookAtMe(soon: true)
            }
            return
        }
        guard cameraReady else { return }
        if listenerTask == nil {
            startListening()
            return
        }
        // 刚建的流别再取消：restartListening 会把正要送达的 docked 事件一起取消掉。
        guard Date().timeIntervalSince(listenerStartedAt) > 5 else { return }
        restartListening()
    }

    private func enableTrackingNow() async {
        guard trackingWanted, let accessory, !enablingTracking, !isMoving else { return }
        if tracking, DockAccessoryManager.shared.isSystemTrackingEnabled { return }
        let token = moveGeneration
        enablingTracking = true
        defer { enablingTracking = false }
        var lastError: String?
        for _ in 0..<3 {
            do {
                await stopVelocityIfAllowed(accessory)
                guard token == moveGeneration, !isMoving else { return }
                try await DockAccessoryManager.shared.setSystemTrackingEnabled(true)
                guard token == moveGeneration, !isMoving else {
                    try? await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
                    return
                }
                try await accessory.setFramingMode(.center)
                tracking = true
                status = "正在看着你"
                detail = "人脸追踪开着。人在画面里会跟。"
                return
            } catch {
                lastError = error.localizedDescription
                try? await Task.sleep(for: .milliseconds(350))
                if !trackingWanted || self.accessory == nil || isMoving { return }
            }
        }
        tracking = false
        status = "看着我失败：\(lastError ?? "未知错误")"
    }

    func stopMotion() {
        guard let accessory else {
            failBeforeMoving("还没连上云台")
            return
        }

        lookAtTask?.cancel()
        motionTask?.cancel()
        moveGeneration += 1
        let token = moveGeneration
        motionTask = Task {
            await stopVelocityIfAllowed(accessory)
            guard token == moveGeneration else { return }
            isMoving = false
            status = "已停止"
            moveOutcome = (true, status)
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

    // 同样返回真结果：开跟随要等系统追踪真的打开，别一句"好了"就交差。
    @discardableResult
    func setTrackingEnabled(_ enabled: Bool) async -> (ok: Bool, message: String) {
        trackingWanted = enabled
        guard accessory != nil else {
            failBeforeMoving("还没连上云台")
            return (false, status)
        }
        if enabled {
            lookAtTask?.cancel()
            lookAtTask = nil
            await enableTrackingNow()
            if !tracking, enablingTracking {
                let deadline = Date().addingTimeInterval(3)
                while enablingTracking, !tracking, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
            return (tracking, status)
        }
        lookAtTask?.cancel()
        motionTask?.cancel()
        moveGeneration += 1
        isMoving = false
        do {
            try await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
            tracking = false
            status = "已停止跟随"
            return (true, status)
        } catch {
            status = "停止跟随失败：\(error.localizedDescription)"
            return (false, status)
        }
    }

    private func finishScriptedMove(_ token: Int) {
        guard token == moveGeneration else { return }   // 更新的动作已经接管，别把它的状态清掉
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
        // ok 说的是"这次真的转了"，不是"云台还吸着"。
        return await waitForMoveResult(timeout: 8)
    }

    private func waitForMoveResult(timeout: TimeInterval) async -> (ok: Bool, message: String) {
        let token = moveGeneration
        let deadline = Date().addingTimeInterval(timeout)
        while isMoving, moveGeneration == token, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(60))
        }
        if moveGeneration != token {
            return (false, "被新的动作打断")
        }
        if isMoving {
            return (false, "\(status)：超时没做完")
        }
        return moveOutcome
    }
}
