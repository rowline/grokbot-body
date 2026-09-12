@preconcurrency import AVFoundation
import Combine
import Foundation
import UIKit

private final class MovieTap: NSObject, AVCaptureFileOutputRecordingDelegate {
    var onFinish: ((URL, Error?) -> Void)?

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        onFinish?(outputFileURL, error)
    }
}

@MainActor
final class CameraController: ObservableObject {
    @Published var status: String = "相机准备中…"
    @Published var isRunning: Bool = false
    @Published var permissionDenied: Bool = false
    @Published var isRecording: Bool = false
    @Published var recordingElapsed: Int = 0

    let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()
    let movieOutput = AVCaptureMovieFileOutput()

    private let sessionQueue = DispatchQueue(label: "GrokBotBody.camera.session")
    private let movieTap = MovieTap()
    private var configured = false
    private var recordWait: CheckedContinuation<URL, Error>?
    private var stopRequested = false
    private var audioInput: AVCaptureDeviceInput?

    // 把帧的消费者（FrameUploader）挂到输出上。在采集队列回调。
    func attachFrameConsumer(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate,
                             on queue: DispatchQueue) {
        videoOutput.setSampleBufferDelegate(delegate, queue: queue)
    }

    func start() async -> Bool {
        let granted = await ensureCameraAccess()
        guard granted else {
            status = "没有相机权限，DockKit 不会激活"
            permissionDenied = true
            return false
        }

        do {
            try configureIfNeeded()
        } catch {
            status = "相机启动失败：\(error.localizedDescription)"
            return false
        }

        let running = await waitUntilRunning()
        isRunning = running
        status = running ? "相机运行中，DockKit 可接入" : "相机未能启动"
        if running { syncVideoOrientation() }
        return running
    }

    private func waitUntilRunning() async -> Bool {
        let captureSession = session
        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                if !captureSession.isRunning {
                    captureSession.startRunning()
                }
                continuation.resume(returning: captureSession.isRunning)
            }
        }
    }

    private func ensureCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionDenied = false
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            permissionDenied = !granted
            return granted
        case .denied, .restricted:
            permissionDenied = true
            return false
        @unknown default:
            permissionDenied = true
            return false
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        defer { session.commitConfiguration() }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        else {
            throw CameraError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }

        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        configured = true
    }

    func recordClip(duration: TimeInterval) async throws -> URL {
        let seconds = max(1, min(12, duration))
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try beginRecording(maxSeconds: seconds, wait: continuation)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func recordUntilStopped(maxSeconds: TimeInterval = 120) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try beginRecording(maxSeconds: maxSeconds, wait: continuation)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func stopRecording() {
        stopRequested = true
        sessionQueue.async { [movieOutput] in
            if movieOutput.isRecording {
                movieOutput.stopRecording()
            }
        }
    }

    private func beginRecording(maxSeconds: TimeInterval, wait: CheckedContinuation<URL, Error>) throws {
        guard session.isRunning else { throw CameraError.notRunning }
        guard !movieOutput.isRecording, recordWait == nil else { throw CameraError.busy }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).mp4")
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }

        stopRequested = false
        recordWait = wait
        isRecording = true
        recordingElapsed = 0
        movieOutput.maxRecordedDuration = CMTime(seconds: max(1, maxSeconds), preferredTimescale: 600)
        Task {
            while isRecording {
                try? await Task.sleep(for: .seconds(1))
                if isRecording {
                    recordingElapsed += 1
                }
            }
        }

        movieTap.onFinish = { [weak self] finishedURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                self.recordingElapsed = 0
                self.detachMicAfterRecording()
                let pending = self.recordWait
                self.recordWait = nil
                if let error, !FileManager.default.fileExists(atPath: finishedURL.path) {
                    pending?.resume(throwing: error)
                } else {
                    pending?.resume(returning: finishedURL)
                }
            }
        }
        let captureSession = session
        let output = movieOutput
        let tap = movieTap
        let needsMic = audioInput == nil
        sessionQueue.async { [weak self] in
            if needsMic,
               let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic) {
                captureSession.beginConfiguration()
                if captureSession.canAddInput(micInput) {
                    captureSession.addInput(micInput)
                    Task { @MainActor in self?.audioInput = micInput }
                }
                captureSession.commitConfiguration()
            }
            output.startRecording(to: dest, recordingDelegate: tap)
            Task { @MainActor in
                guard let self else { return }
                if self.stopRequested {
                    self.stopRecording()
                }
            }
        }
    }

    private func detachMicAfterRecording() {
        guard let micInput = audioInput else { return }
        audioInput = nil
        let captureSession = session
        sessionQueue.async {
            captureSession.beginConfiguration()
            captureSession.removeInput(micInput)
            captureSession.commitConfiguration()
        }
    }

    func syncVideoOrientation() {
        let orientation = Self.captureOrientation()
        let video = videoOutput
        let movie = movieOutput
        sessionQueue.async {
            for output in [video, movie] as [AVCaptureOutput] {
                guard let connection = output.connection(with: .video),
                      connection.isVideoOrientationSupported
                else { continue }
                connection.videoOrientation = orientation
            }
        }
    }

    private static func captureOrientation() -> AVCaptureVideoOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }
}

private enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput
    case notRunning
    case busy

    var errorDescription: String? {
        switch self {
        case .noCamera:
            return "没有找到可用摄像头"
        case .cannotAddInput:
            return "无法把摄像头加入采集会话"
        case .notRunning:
            return "相机没在跑"
        case .busy:
            return "正在录像"
        }
    }
}
