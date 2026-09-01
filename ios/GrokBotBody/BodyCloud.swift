import Foundation
import Combine

@MainActor
final class BodyCloud: ObservableObject {
    @Published var connected = false
    @Published var pairingCode = "------"
    @Published var pairingExpires: Date?
    @Published var boundLabel: String?
    @Published var expression = "idle"
    @Published var lastError: String?
    @Published var allowFrame = true
    @Published var allowVideo = true
    @Published var voiceReady = false
    @Published var voiceState = "idle"
    @Published var heardText = ""
    @Published var heardStatus = ""
    @Published var activity = ""
    @Published var wakeReady = false
    @Published var mcpURL = ""
    @Published var setupURL = ""
    @Published var setupCode = ""



    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    var onCommand: (([String: Any]) async -> [String: Any])?

    func connect() {
        reconnectTask?.cancel()
        guard CloudConfig.hasCloudURL else {
            connected = false
            lastError = "未填云地址"
            return
        }
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.openOnce()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        connected = false
    }

    func requestNewPairing() {
        send(["type": "unbind"])
    }

    func sendUtterance(_ text: String) {
        heardText = text
        heardStatus = connected ? "已发出" : (CloudConfig.hasCloudURL ? "未联网" : "未填云地址")
        send(["type": "utterance", "text": text])
    }

    func sendWakeHook(url: String, secret: String) {
        send(["type": "set_wake_hook", "url": url, "secret": secret])
    }

    func sendStatus(dockConnected: Bool, tracking: Bool, expression: String, voiceId: String) {
        send([
            "type": "status",
            "dock_connected": dockConnected,
            "tracking": tracking,
            "expression": expression,
            "allow_frame": allowFrame,
            "allow_video": allowVideo,
            "voice_id": voiceId,
        ])
    }

    func uploadClip(fileURL: URL, clipId: String) async throws -> (url: String, bytes: Int) {
        let base = CloudConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encoded = clipId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clipId
        guard let url = URL(string: "\(base)/body/\(CloudConfig.bodyId)/clip?device_secret=\(CloudConfig.deviceSecret)&clip_id=\(encoded)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 40
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true,
              let clipURL = json["url"] as? String
        else {
            lastError = "录像没传上去"
            throw URLError(.cannotWriteToFile)
        }
        return (clipURL, json["bytes"] as? Int ?? 0)
    }

    private func openOnce() async {
        guard CloudConfig.hasCloudURL else {
            connected = false
            lastError = "未填云地址"
            return
        }
        let base = CloudConfig.baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        let urlString = "\(base)/body/\(CloudConfig.bodyId)/ws?device_secret=\(CloudConfig.deviceSecret)"
        guard let url = URL(string: urlString) else {
            lastError = "云地址无效"
            return
        }

        let session = URLSession(configuration: .default)
        self.session = session
        let socket = session.webSocketTask(with: url)
        task = socket
        socket.resume()
        startPing()

        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                connected = true
                lastError = nil
                switch message {
                case .string(let text):
                    await handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handle(text)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            connected = false
            lastError = "未联网"
        }
        pingTask?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.task?.sendPing { _ in }
            }
        }
    }

    private func handle(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let type = json["type"] as? String ?? ""
        switch type {
        case "hello", "unbound":
            if let code = json["pairing_code"] as? String, !code.isEmpty {
                pairingCode = code
            }
            if let expires = json["pairing_expires_at"] as? Double, expires > 0 {
                pairingExpires = Date(timeIntervalSince1970: expires / 1000)
            }
            if let setup = json["setup_code"] as? String, !setup.isEmpty {
                setupCode = setup
            } else if pairingCode != "------" {
                setupCode = pairingCode
            }
            if let mcp = json["mcp_url"] as? String {
                mcpURL = mcp
            }
            if let setup = json["setup_url"] as? String {
                setupURL = setup
            }
            boundLabel = nil
            if let bound = json["bound_bot"] as? [String: Any],
               bound["claimed"] as? Bool == true {
                boundLabel = bound["label"] as? String
            }
            if let ready = json["voice_ready"] as? Bool {
                voiceReady = ready
            }
            if let wake = json["wake_ready"] as? Bool {
                wakeReady = wake
            }
        case "bound":
            if let bound = json["bound_bot"] as? [String: Any] {
                boundLabel = bound["label"] as? String
            }
            pairingCode = "------"
            if let setup = json["setup_code"] as? String, !setup.isEmpty {
                setupCode = setup
            }
        case "set_expression", "control_dock", "set_tracking", "get_frame", "record_video", "speak":
            var reply = await onCommand?(json) ?? ["ok": false, "error": "no handler"]
            reply["id"] = json["id"] as Any
            reply["type"] = reply["type"] ?? "ack"
            send(reply)
        case "status_sync":
            break
        case "voice_state":
            if let state = json["state"] as? String {
                voiceState = state
                if state == "listen" || state == "speak" {
                    expression = state
                } else if state == "idle", expression == "listen" || expression == "speak" {
                    expression = "idle"
                }
            }
        case "utterance_ack":
            if let text = json["text"] as? String, !text.isEmpty {
                heardText = text
            }
            if json["delivered"] as? Bool == true {
                heardStatus = "已交给 Bot"
            } else if json["waking"] as? Bool == true {
                heardStatus = "正在按门铃"
            } else {
                heardStatus = wakeReady ? "已记下 · 现在没在听" : "已记下 · 去绑定页设门铃"
            }
        case "wake_ready":
            if let ready = json["wake_ready"] as? Bool {
                wakeReady = ready
            }
            if json["ok"] as? Bool == false {
                lastError = json["error"] as? String ?? "门铃地址无效"
            }
        case "wake_result":
            if json["ok"] as? Bool == true {
                heardStatus = "已交给 Bot"
            } else if heardStatus == "正在按门铃" {
                heardStatus = "已记下 · 门铃没响"
            }
        case "voice_error":
            lastError = json["error"] as? String ?? "身体离线"
        default:
            break
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(text)) { _ in }
    }
}
