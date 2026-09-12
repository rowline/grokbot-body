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
    @State private var announceTasks = CloudConfig.announceTasks
    @State private var faceStyle = CloudConfig.faceStyle
    @State private var faceColor = CloudConfig.faceColor
    @State private var faceShape = CloudConfig.faceShape
    @State private var restFace = CloudConfig.restFace
    @State private var voiceId = CloudConfig.voiceId
    @State private var appleVoiceId = CloudConfig.appleVoiceId
    @State private var appleVoices: [EarMouth.AppleVoiceChoice] = EarMouth.appleVoiceChoices()
    @State private var grokKeyDraft = ""
    @State private var grokKeySaved = CloudConfig.hasGrokVoice
    @State private var wakeURLDraft = CloudConfig.wakeURL
    @State private var wakeSecretDraft = ""
    @State private var wakeSaved = CloudConfig.hasWakeHook
    @State private var copiedHint = ""
    @GestureState private var holdingTalk = false
    @State private var faceTouch: CGPoint?
    @State private var holdReset: Task<Void, Never>?
    @State private var activityClear: Task<Void, Never>?
    @State private var missHearTask: Task<Void, Never>?
    @State private var flash = false
    @State private var snapshot: UIImage?
    @Environment(\.scenePhase) private var scenePhase
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
                    color: faceColor,
                    shape: faceShape,
                    rest: restFace,
                    motion: motion,
                    touch: faceTouch
                )
                    .scaleEffect(holdingTalk && faceTouch == nil ? 0.96 : 1)
                    .gesture(talkGesture)

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

                chromeOverlay(
                    landscape: landscape,
                    sideGutter: max(120, (proxy.size.width - orbSize) / 2 - 8)
                )
            }
        }
        .statusBarHidden()
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            camera.syncVideoOrientation()
        }
        .sheet(isPresented: $showBinding) {
            bindingSheet
                .onAppear { appleVoices = EarMouth.appleVoiceChoices() }
        }
        .task {
            motion.start()
            await boot()
        }
        .onDisappear { motion.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                dock.ensureAttachedAndTracking()
            }
        }
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
        .onChange(of: announceTasks) { _, on in
            CloudConfig.setAnnounceTasks(on)
        }
        .onChange(of: faceStyle) { _, style in
            CloudConfig.setFaceStyle(style)
        }
        .onChange(of: faceColor) { _, color in
            CloudConfig.setFaceColor(color)
        }
        .onChange(of: faceShape) { _, shape in
            CloudConfig.setFaceShape(shape)
        }
        .onChange(of: restFace) { _, face in
            CloudConfig.setRestFace(face)
        }
        .onChange(of: voiceId) { _, id in
            CloudConfig.setVoiceId(id)
            pushStatus()
        }
        .onChange(of: appleVoiceId) { _, id in
            CloudConfig.setAppleVoiceId(id)
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
                missHearTask?.cancel()
                cloud.heardText = ""
                cloud.heardStatus = "在听"
                mouth.beginTalk()
                cloud.voiceState = "listen"
            } else {
                mouth.endTalk()
                missHearTask?.cancel()
                missHearTask = Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
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
    private func chromeOverlay(landscape: Bool, sideGutter: CGFloat) -> some View {
        if landscape {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    statusChip
                    Spacer(minLength: 0)
                    captionBlock(alignment: .leading, compact: true)
                }
                .frame(width: sideGutter, alignment: .leading)
                .allowsHitTesting(false)
                Spacer(minLength: 0)
                bindButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } else {
            VStack {
                HStack {
                    statusChip
                        .allowsHitTesting(false)
                    Spacer()
                    bindButton
                }
                Spacer()
                captionBlock(alignment: .center, compact: false)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }

    @ViewBuilder
    private func captionBlock(alignment: HorizontalAlignment, compact: Bool) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .frame(width: compact ? 56 : 72, height: compact ? 74 : 96)
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
                    .font(.system(size: compact ? 22 : 28, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(holdHint)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 20)
            } else {
                Text(cloud.boundLabel ?? "")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                if !cloud.heardText.isEmpty {
                    Text(cloud.heardText)
                        .font(.system(size: compact ? 15 : 17, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(alignment == .leading ? .leading : .center)
                        .lineLimit(compact ? 6 : 8)
                        .frame(
                            maxWidth: .infinity,
                            alignment: alignment == .leading ? .leading : .center
                        )
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
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
        .allowsHitTesting(false)
    }

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

    private func announceDone(_ phrase: String) {
        guard CloudConfig.announceTasks else { return }
        Task {
            await mouth.speak(
                phrase,
                apiKey: CloudConfig.xaiAPIKey,
                voiceId: CloudConfig.voiceId,
                remember: false
            )
        }
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
            .onChanged { value in
                faceTouch = value.location
            }
            .onEnded { _ in
                faceTouch = nil
            }
    }

    private var displayExpression: String {
        if camera.permissionDenied { return "error" }
        if cloud.voiceState == "listen" { return "listen" }
        if cloud.voiceState == "speak" { return "speak" }
        if motion.dizzy > 0.25 { return "shake" }
        if motion.shaking { return "surprised" }
        if dock.isMoving {
            if dock.status.contains("点头") { return "nod" }
            if dock.status.contains("摇头") { return "shake" }
            if dock.status.contains("低头") { return "sleepy" }
            return "look"
        }
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
                    FaceChooser(
                        color: $faceColor,
                        shape: $faceShape,
                        rest: $restFace,
                        style: $faceStyle,
                        motion: motion
                    )
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
                    Toggle("任务完成出声", isOn: $announceTasks)
                    Text("拍完、转完只说一句短的。长内容写在对话框，不往外念。")
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
                        Text("不填就用系统声。Grok 官方音色必须有自己的 xAI 密钥。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Picker("系统声", selection: $appleVoiceId) {
                        Text("自动").tag("")
                        ForEach(appleVoices) { voice in
                            Text(voice.label).tag(voice.identifier)
                        }
                    }
                    Button("试听系统声") {
                        Task { await mouth.previewAppleVoice() }
                    }
                    if EarMouth.usingCompactAppleVoice(appleVoiceId) {
                        Text("现在是压缩音色，听着机械。去设置 → 辅助功能 → 朗读内容 → 声音 → 中文，下载增强或高级。雨舒、力穆比婷婷自然。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(grokKeySaved
                             ? "Grok 调不通时退回这副系统声。"
                             : "没开 Grok 时用这副声。高级、增强要先在系统设置里下载。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("身体") {
                    LabeledContent("听和说", value: "有")
                    LabeledContent("换脸", value: "有")
                    LabeledContent("转头点头", value: "有")
                    LabeledContent("跟着人", value: dock.tracking ? "开着" : "关着")
                    LabeledContent("云台", value: dock.connected ? "已吸附" : "没吸上")
                    Text(dock.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(dock.detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
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
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
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
            dock.noteCameraReady()
            dock.startListening()
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                dock.ensureAttachedAndTracking()
                try? await Task.sleep(for: .seconds(6))
                dock.ensureAttachedAndTracking()
            }
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
            announceDone("已存到相册")
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
                showActivity(labels.done)
                announceDone(labels.done)
            } else {
                showActivity(result.message)
            }
        case .tracking(let enabled):
            let line = enabled ? "开始跟着你" : "停止跟随"
            showActivity(line, sticky: enabled)
            let result = await dock.setTrackingEnabled(enabled)
            if result.ok {
                announceDone(line)
            } else {
                showActivity(result.message)
            }
        case .stop:
            dock.stopMotion()
            showActivity("已停下")
            announceDone("已停下")
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
            let name = Bloub.canonicalExpression(json["name"] as? String ?? "idle")
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
                showActivity(labels.done)
                announceDone(labels.done)
            } else {
                showActivity(result.message)
            }
            return ["type": "ack", "ok": result.ok, "message": result.message]
        case "set_tracking":
            let enabled = json["enabled"] as? Bool ?? false
            let line = enabled ? "开始跟着你" : "停止跟随"
            showActivity(line, sticky: enabled)
            let result = await dock.setTrackingEnabled(enabled)
            if result.ok {
                announceDone(line)
            } else {
                showActivity(result.message)
            }
            return ["type": "ack", "ok": result.ok, "message": result.message]
        case "get_frame":
            guard cloud.allowFrame, let data = grabber.jpegData, let jpeg = grabber.jpegBase64 else {
                showActivity("没有画面")
                return ["type": "ack", "ok": false, "error": "没有画面"]
            }
            flash = true
            snapshot = UIImage(data: data)
            showActivity("拍好了")
            announceDone("拍好了")
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
                showActivity("录像好了")
                announceDone("录像好了")
                if CloudConfig.listenMode == "always", cloud.boundLabel != nil {
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
                if CloudConfig.listenMode == "always", cloud.boundLabel != nil {
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
            await mouth.speak(text, audio: audio, apiKey: CloudConfig.xaiAPIKey, voiceId: CloudConfig.voiceId)
            if CloudConfig.listenMode != "always" {
                cloud.voiceState = "idle"
            } else if cloud.voiceState == "speak" {
                cloud.voiceState = "listen"
            }
            if cloud.heardStatus == "在说" {
                cloud.heardStatus = ""
            }
            return ["type": "ack", "ok": true]
        default:
            return ["type": "ack", "ok": false, "error": "unknown command"]
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
