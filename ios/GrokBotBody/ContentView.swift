import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var dock = DockController()
    @StateObject private var cloud = BodyCloud()
    @StateObject private var motion = MotionSense()
    @State private var grabber = FrameGrabber()
    @State private var mouth = EarMouth()
    @State private var showBinding = false
    @State private var cloudURL = CloudConfig.baseURL
    @State private var listenMode = CloudConfig.listenMode
    @State private var faceStyle = CloudConfig.faceStyle
    @State private var voiceId = CloudConfig.voiceId
    @State private var grokKeyDraft = ""
    @State private var grokKeySaved = CloudConfig.hasGrokVoice
    @State private var wakeURLDraft = CloudConfig.wakeURL
    @State private var wakeSecretDraft = ""
    @State private var wakeSaved = CloudConfig.hasWakeHook
    @State private var copiedHint = ""
    @GestureState private var holdingTalk = false
    @State private var holdReset: Task<Void, Never>?
    @State private var activityClear: Task<Void, Never>?
    @State private var flash = false
    @State private var snapshot: UIImage?
    private let frameQueue = DispatchQueue(label: "GrokBotBody.frames")

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height + 12
            let orbSize = landscape
                ? min(proxy.size.height * 0.88, proxy.size.width * 0.58)
                : min(proxy.size.width, proxy.size.height) * 0.72
            ZStack {
                Color.black.ignoresSafeArea()
                OrbFaceView(
                    expression: displayExpression,
                    size: orbSize,
                    style: faceStyle,
                    motion: motion
                )
                    .scaleEffect(holdingTalk ? 0.96 : 1)
                    .gesture(talkGesture)
                    .animation(.easeOut(duration: 0.12), value: holdingTalk)

                Color.white.opacity(flash ? 0.55 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.16), value: flash)

                if camera.isRecording {
                    VStack {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                            Text(camera.recordingElapsed > 0 ? "录像 \(camera.recordingElapsed)s" : "录像中")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.red.opacity(0.55), in: Capsule())
                        .padding(.top, 58)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                chromeOverlay(landscape: landscape)
            }
        }
        .statusBarHidden()
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            camera.syncVideoOrientation()
        }
        .sheet(isPresented: $showBinding) {
            bindingSheet
        }
        .task {
            motion.start()
            await boot()
        }
        .onDisappear { motion.stop() }
        .onChange(of: dock.connected) { _, _ in pushStatus() }
        .onChange(of: cloud.connected) { _, ok in
            if ok {
                pushStatus()
                pushWakeHook()
            }
        }
        .onChange(of: dock.status) { _, _ in pushStatus() }
        .onChange(of: cloud.allowFrame) { _, _ in pushStatus() }
        .onChange(of: cloud.allowVideo) { _, _ in pushStatus() }
        .onChange(of: listenMode) { _, mode in
            CloudConfig.setListenMode(mode)
            applyListenMode()
        }
        .onChange(of: faceStyle) { _, style in
            CloudConfig.setFaceStyle(style)
        }
        .onChange(of: voiceId) { _, id in
            CloudConfig.setVoiceId(id)
            pushStatus()
        }
        .onChange(of: cloud.boundLabel) { _, _ in
            applyListenMode()
        }
        .onChange(of: holdingTalk) { _, holding in
            if listenMode == "record" {
                if holding {
                    Task { await beginHoldRecord() }
                } else {
                    camera.stopRecording()
                }
                return
            }
            guard listenMode == "hold", cloud.boundLabel != nil else { return }
            if holding {
                cloud.heardText = ""
                cloud.heardStatus = "在听"
                mouth.beginTalk()
                cloud.voiceState = "listen"
            } else {
                mouth.endTalk()
                Task {
                    try? await Task.sleep(for: .milliseconds(550))
                    if cloud.heardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        cloud.heardStatus = "没听清"
                    }
                }
            }
        }
    }

    private var bindButton: some View {
        Button("绑定") { showBinding = true }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func chromeOverlay(landscape: Bool) -> some View {
        if landscape {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    statusChip
                    Spacer()
                    captionBlock(alignment: .leading)
                }
                Spacer()
                bindButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        } else {
            VStack {
                HStack {
                    statusChip
                    Spacer()
                    bindButton
                }
                Spacer()
                captionBlock(alignment: .center)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    @ViewBuilder
    private func captionBlock(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .padding(.bottom, 8)
            }
            if !CloudConfig.hasCloudURL {
                Text("绑定页填云地址")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 20)
            } else if cloud.boundLabel == nil {
                Text(cloud.pairingCode)
                    .font(.system(size: landscapeCaptionSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                Text(holdHint)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 20)
            } else {
                Text(cloud.boundLabel ?? "")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                if !cloud.heardText.isEmpty {
                    Text(cloud.heardText)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(alignment == .leading ? .leading : .center)
                        .lineLimit(3)
                }
                if !cloud.heardStatus.isEmpty {
                    Text(cloud.heardStatus)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
                if !cloud.activity.isEmpty {
                    Text(cloud.activity)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Text(holdHint)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 20)
            }
        }
    }

    private var landscapeCaptionSize: CGFloat { 36 }

    private static let wakeRoutineText =
        "身体有人说话了。立刻 wait_for_speech。把听到的原话写进对话框，用 speak 在手机上读出回答，然后再听。不要编。"

    private var claimPhrase: String {
        "用配对码 \(cloud.pairingCode) 认领身体。认领后立刻 wait_for_speech。"
    }

    private var doorbellCode: String {
        if !cloud.setupCode.isEmpty { return cloud.setupCode }
        if cloud.pairingCode != "------" { return cloud.pairingCode }
        return "------"
    }

    private func copyText(_ text: String, label: String) {
        UIPasteboard.general.string = text
        copiedHint = "已复制 · \(label)"
    }

    private var holdHint: String {
        if listenMode == "record" {
            return holdingTalk || camera.isRecording ? "松手存到相册" : "按住录像"
        }
        if listenMode == "always" { return "一直在听" }
        if holdingTalk { return "松手发送" }
        return "按住说话"
    }

    private var talkGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($holdingTalk) { _, state, _ in
                if listenMode == "record" {
                    state = true
                    return
                }
                guard listenMode == "hold", cloud.boundLabel != nil else { return }
                state = true
            }
    }

    private var displayExpression: String {
        if camera.permissionDenied { return "error" }
        if !cloud.connected { return CloudConfig.hasCloudURL ? "error" : "idle" }
        if cloud.voiceState == "listen" { return "listen" }
        if cloud.voiceState == "speak" { return "speak" }
        if motion.dizzy > 0.25 { return "shake" }
        if motion.shaking { return "surprised" }
        if dock.isMoving { return "look" }
        if dock.status.contains("点头") { return "nod" }
        if dock.status.contains("摇头") { return "shake" }
        if dock.status.contains("左转") || dock.status.contains("右转") || dock.status.contains("转圈") { return "look" }
        if dock.tracking { return "curious" }
        return cloud.expression
    }

    private var statusChip: some View {
        let text: String = {
            if camera.permissionDenied { return "需要相机" }
            if !CloudConfig.hasCloudURL { return "未填云地址" }
            if !cloud.connected { return "未联网" }
            if holdingTalk { return "在听" }
            if motion.dizzy > 0.4 { return "发晕" }
            if cloud.voiceState == "listen" { return "在听" }
            if cloud.voiceState == "speak" { return "在说" }
            if camera.isRecording { return camera.recordingElapsed > 0 ? "录像 \(camera.recordingElapsed)s" : "录像中" }
            if !cloud.activity.isEmpty { return cloud.activity }
            if dock.tracking { return "跟着你" }
            if let label = cloud.boundLabel { return "已绑定 · \(label)" }
            if dock.connected { return "云台已吸附" }
            return "等待吸附"
        }()
        return Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.1), in: Capsule())
    }

    private var bindingSheet: some View {
        NavigationStack {
            Form {
                Section("云") {
                    TextField("https://xxx.workers.dev", text: $cloudURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    Button("保存并重连") {
                        CloudConfig.setBaseURL(cloudURL)
                        cloudURL = CloudConfig.baseURL
                        cloud.disconnect()
                        if CloudConfig.hasCloudURL {
                            cloud.connect()
                        }
                    }
                    .disabled(!CloudConfig.isUsableCloudURL(cloudURL) && !cloudURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("填自己部署的 Worker 地址。空着不连云。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("配对") {
                    LabeledContent("配对码", value: cloud.pairingCode)
                    if !CloudConfig.hasCloudURL {
                        Text("先填云地址。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let label = cloud.boundLabel {
                        LabeledContent("已绑定", value: label)
                        Button("解绑", role: .destructive) {
                            cloud.requestNewPairing()
                        }
                    } else {
                        Text("对选定的 Bot 说：用配对码 \(cloud.pairingCode) 认领身体")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("复制口令") {
                            copyText(claimPhrase, label: "口令")
                        }
                        Button("换一组配对码") {
                            cloud.requestNewPairing()
                        }
                    }
                    if !copiedHint.isEmpty {
                        Text(copiedHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("连接") {
                    if cloud.mcpURL.isEmpty {
                        Text("等联网后显示地址。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(cloud.mcpURL)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        Button("复制地址") {
                            copyText(cloud.mcpURL, label: "地址")
                        }
                        Text("Grok Custom Connector 贴这条，只贴一次。换过之后 Bot 不用记密钥。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("脸") {
                    Picker("脸", selection: $faceStyle) {
                        Text("Orb").tag("orb")
                        Text("暗球").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    Text(faceStyle == "orb"
                         ? "思考绕彩带，出错变感叹号，还能变成六边形。"
                         : "黑球白眼。思考、出错、六边形同一套变形。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("听") {
                    Picker("听", selection: $listenMode) {
                        Text("按住说话").tag("hold")
                        Text("一直听").tag("always")
                        Text("按住录像").tag("record")
                    }
                    .pickerStyle(.segmented)
                    Text(listenMode == "always"
                         ? "周围说话也会收进去。"
                         : listenMode == "record"
                            ? "按住球体录像，松手存到相册。"
                            : "按住球体说话，松手发出去。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("认领后应自己循环听。一次大约 18 秒，没人说话也要马上再听。屏幕若显示已记下，是这一回合停了。门铃设好后可再叫醒。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("门铃") {
                    if wakeSaved {
                        LabeledContent("门铃", value: cloud.wakeReady ? "已接通" : "已保存，等联网")
                        Button("关掉门铃") {
                            CloudConfig.setWakeHook(url: "", secret: nil)
                            wakeURLDraft = ""
                            wakeSecretDraft = ""
                            wakeSaved = false
                            cloud.sendWakeHook(url: "", secret: "")
                        }
                        Text("没在听时，对着手机说话会按这个门铃。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("1. 电脑打开这个 Bot")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("2. 新建自动化，触发选「当 webhook 响起」")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("3. 说明贴这段")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("复制说明") {
                            copyText(Self.wakeRoutineText, label: "说明")
                        }
                        Text("4. 打开触发卡片，网址和密钥贴到下面；或电脑打开 setup 页贴")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !cloud.setupURL.isEmpty {
                            Button("复制 setup 页") {
                                copyText(cloud.setupURL, label: "setup 页")
                            }
                        }
                        LabeledContent("电脑用码", value: doorbellCode)
                        TextField("webhook 网址", text: $wakeURLDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("发送密钥，选填", text: $wakeSecretDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("保存门铃") {
                            CloudConfig.setWakeHook(url: wakeURLDraft, secret: wakeSecretDraft)
                            wakeSecretDraft = ""
                            wakeSaved = CloudConfig.hasWakeHook
                            pushWakeHook()
                        }
                        .disabled(wakeURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("嘴") {
                    if grokKeySaved {
                        LabeledContent("Grok 音色", value: "这台手机已开")
                        Picker("声", selection: $voiceId) {
                            Text("Eve 活泼").tag("eve")
                            Text("Ara 暖和").tag("ara")
                            Text("Leo 沉").tag("leo")
                            Text("Rex 清楚").tag("rex")
                            Text("Sal 稳").tag("sal")
                        }
                        Button("关掉 Grok 音色") {
                            CloudConfig.setXaiAPIKey(nil)
                            grokKeySaved = false
                            grokKeyDraft = ""
                        }
                        Text("开口用 Grok。密钥只留在这台手机，不过云。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        SecureField("xAI API 密钥，选填", text: $grokKeyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("使用 Grok 音色") {
                            CloudConfig.setXaiAPIKey(grokKeyDraft)
                            grokKeyDraft = ""
                            grokKeySaved = CloudConfig.hasGrokVoice
                        }
                        .disabled(grokKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("不填就用系统声。Grok 官方音色必须有自己的 xAI 密钥，没有别的办法。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("身体") {
                    LabeledContent("听和说", value: "有")
                    LabeledContent("换脸", value: "有")
                    LabeledContent("转头点头", value: "有")
                    LabeledContent("跟着人", value: dock.tracking ? "开着" : "关着")
                    LabeledContent("拍一张", value: cloud.allowFrame ? "开着" : "关着")
                    LabeledContent("录像", value: cloud.allowVideo ? "最长 12 秒" : "关着")
                    Text("吸上云台默认跟着脸。对着手机说左转、点头、跟着我，支架当场动，不等 Bot。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("看一眼") {
                    Toggle("允许拍一张", isOn: $cloud.allowFrame)
                    Toggle("允许录像", isOn: $cloud.allowVideo)
                    Text("打开后，被绑定的 Bot 可以拍一张或录最长 12 秒。文件会过云。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("绑定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { showBinding = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func boot() async {
        cloudURL = CloudConfig.baseURL
        camera.attachFrameConsumer(grabber, on: frameQueue)
        cloud.onCommand = handleCommand
        mouth.onUtterance = { text in
            handleHeard(text)
        }
        mouth.onPartial = { text in
            cloud.heardText = text
            if cloud.heardStatus.isEmpty || cloud.heardStatus == "在听" || cloud.heardStatus == "没听清" {
                cloud.heardStatus = "在听"
            }
        }
        mouth.onError = { message in
            cloud.heardStatus = message
        }
        mouth.onListening = { listening in
            if listening {
                cloud.voiceState = "listen"
            } else if cloud.voiceState == "listen" {
                cloud.voiceState = "idle"
            }
        }
        let cameraReady = await camera.start()
        if cameraReady {
            dock.startListening()
        }
        _ = await mouth.authorize()
        if CloudConfig.hasCloudURL {
            cloud.connect()
        } else {
            showBinding = true
        }
    }

    private func applyListenMode() {
        mouth.alwaysListen = listenMode == "always"
        if listenMode == "record" {
            mouth.stopListening()
            if cloud.voiceState == "listen" { cloud.voiceState = "idle" }
            return
        }
        guard cloud.boundLabel != nil else {
            mouth.stopListening()
            if cloud.voiceState == "listen" { cloud.voiceState = "idle" }
            return
        }
        if listenMode == "always" {
            mouth.startListening()
        } else {
            mouth.stopListening()
            if cloud.voiceState == "listen" { cloud.voiceState = "idle" }
        }
    }

    private func beginHoldRecord() async {
        guard cloud.allowVideo else {
            showActivity("录像关着")
            return
        }
        guard !camera.isRecording else { return }
        mouth.stopListening()
        showActivity("正在录像", sticky: true)
        do {
            let fileURL = try await camera.recordUntilStopped()
            try await PhotoSaver.saveVideo(at: fileURL)
            showActivity("已存到相册")
            try? FileManager.default.removeItem(at: fileURL)
        } catch {
            showActivity(error.localizedDescription)
        }
    }

    private func handleHeard(_ text: String) {
        let parsed = DockVoice.interpret(text)
        if let command = parsed.command {
            Task { await runLocalDock(command) }
        }
        if let forward = parsed.forward {
            cloud.sendUtterance(forward)
        } else if parsed.command != nil {
            cloud.heardText = text
            cloud.heardStatus = "支架已动"
        }
    }

    private func runLocalDock(_ command: DockVoice.Command) async {
        switch command {
        case .action(let action):
            let labels = dockLabel(action)
            showActivity(labels.doing)
            let result = await dock.performAction(action)
            if result.ok {
                cloud.expression = expressionForDock(action)
                showActivity(labels.done)
            } else {
                showActivity(result.message)
            }
        case .tracking(let enabled):
            showActivity(enabled ? "开始跟着你" : "停止跟随", sticky: enabled)
            await dock.setTrackingEnabled(enabled)
            if !dock.connected {
                showActivity("还没连上云台")
            }
        case .stop:
            dock.stopMotion()
            showActivity("已停下")
        }
    }

    private func pushStatus() {
        cloud.sendStatus(
            dockConnected: dock.connected,
            tracking: dock.tracking,
            expression: displayExpression,
            voiceId: voiceId
        )
    }

    private func pushWakeHook() {
        guard CloudConfig.hasWakeHook else { return }
        cloud.sendWakeHook(url: CloudConfig.wakeURL, secret: CloudConfig.wakeSecret ?? "")
    }

    @MainActor
    private func handleCommand(_ json: [String: Any]) async -> [String: Any] {
        let type = json["type"] as? String ?? ""
        switch type {
        case "set_expression":
            let name = json["name"] as? String ?? "idle"
            cloud.expression = name
            showActivity(name == "idle" ? "恢复待机" : "换脸")
            let hold = (json["hold_ms"] as? Double) ?? 1800
            holdReset?.cancel()
            if hold > 0 && name != "idle" {
                holdReset = Task {
                    try? await Task.sleep(for: .milliseconds(Int64(hold)))
                    if !Task.isCancelled { cloud.expression = "idle" }
                }
            }
            return ["type": "ack", "ok": true]
        case "control_dock":
            let action = json["action"] as? String ?? ""
            let labels = dockLabel(action)
            showActivity(labels.doing)
            let result = await dock.performAction(action)
            if result.ok {
                cloud.expression = expressionForDock(action)
                showActivity(labels.done)
            } else {
                showActivity(result.message)
            }
            return ["type": "ack", "ok": result.ok, "message": result.message]
        case "set_tracking":
            let enabled = json["enabled"] as? Bool ?? false
            showActivity(enabled ? "开始跟着你" : "停止跟随", sticky: enabled)
            await dock.setTrackingEnabled(enabled)
            if !dock.connected {
                showActivity("还没连上云台")
            }
            return ["type": "ack", "ok": dock.connected, "message": dock.status]
        case "get_frame":
            guard cloud.allowFrame, let data = grabber.jpegData, let jpeg = grabber.jpegBase64 else {
                showActivity("没有画面")
                return ["type": "ack", "ok": false, "error": "没有画面"]
            }
            flash = true
            snapshot = UIImage(data: data)
            showActivity("拍了一张")
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                flash = false
            }
            Task {
                try? await Task.sleep(for: .seconds(3.2))
                if !Task.isCancelled { snapshot = nil }
            }
            return ["type": "frame", "ok": true, "jpeg": jpeg]
        case "record_video":
            guard cloud.allowVideo else {
                showActivity("录像关着")
                return ["type": "ack", "ok": false, "error": "录像关着"]
            }
            let duration = min(12, max(1, (json["duration_s"] as? Double) ?? 6))
            let clipId = json["clip_id"] as? String ?? UUID().uuidString
            mouth.stopListening()
            showActivity("正在录像", sticky: true)
            do {
                let fileURL = try await camera.recordClip(duration: duration)
                try? await PhotoSaver.saveVideo(at: fileURL)
                showActivity("正在上传")
                let uploaded = try await cloud.uploadClip(fileURL: fileURL, clipId: clipId)
                try? FileManager.default.removeItem(at: fileURL)
                showActivity("录像完成")
                if listenMode == "always", cloud.boundLabel != nil {
                    mouth.startListening()
                }
                return [
                    "type": "ack",
                    "ok": true,
                    "url": uploaded.url,
                    "bytes": uploaded.bytes,
                    "duration_s": duration,
                ]
            } catch {
                showActivity("录像失败")
                if listenMode == "always", cloud.boundLabel != nil {
                    mouth.startListening()
                }
                return ["type": "ack", "ok": false, "error": error.localizedDescription]
            }
        case "speak":
            let text = json["text"] as? String ?? ""
            cloud.voiceState = "speak"
            cloud.heardText = text
            cloud.heardStatus = "在说"
            let audio: Data? = (json["audio_base64"] as? String).flatMap { Data(base64Encoded: $0) }
            await mouth.speak(text, audio: audio, apiKey: CloudConfig.xaiAPIKey, voiceId: voiceId)
            if listenMode != "always" {
                cloud.voiceState = "idle"
            }
            if cloud.heardStatus == "在说" {
                cloud.heardStatus = ""
            }
            return ["type": "ack", "ok": true]
        default:
            return ["type": "ack", "ok": false, "error": "unknown command"]
        }
    }

    private func expressionForDock(_ action: String) -> String {
        switch action {
        case "nod": return "nod"
        case "shake": return "shake"
        case "turn_left", "turn_right", "spin": return "look"
        case "head_down": return "sleepy"
        default: return "look"
        }
    }

    private func dockLabel(_ action: String) -> (doing: String, done: String) {
        switch action {
        case "nod": return ("正在点头", "点头完成")
        case "shake": return ("正在摇头", "摇头完成")
        case "turn_left": return ("正在左转", "左转完成")
        case "turn_right": return ("正在右转", "右转完成")
        case "spin": return ("正在转圈", "转圈完成")
        case "head_up": return ("正在抬头", "抬头完成")
        case "head_down": return ("正在低头", "低头完成")
        default: return ("正在动", "动作完成")
        }
    }

    private func showActivity(_ text: String, sticky: Bool = false) {
        cloud.activity = text
        activityClear?.cancel()
        guard !sticky else { return }
        activityClear = Task {
            try? await Task.sleep(for: .seconds(2.4))
            if !Task.isCancelled, cloud.activity == text {
                cloud.activity = ""
            }
        }
    }
}
