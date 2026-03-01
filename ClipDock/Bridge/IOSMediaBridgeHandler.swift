// IOSMediaBridgeHandler.swift
// iOS 专属媒体能力 Bridge Handler
//
// Actions:
//   ios.cameraCapture    — 拍照/选图，返回 base64 JPEG
//   ios.microphoneRecord — 录音，返回 base64 m4a + duration

import UIKit
import AVFoundation

@MainActor
final class IOSMediaBridgeHandler: NSObject {

    static let actions: Set<String> = ["ios.cameraCapture", "ios.microphoneRecord"]

    private var cameraContinuation: CheckedContinuation<[String: Any], Error>?
    private var audioRecorder: AVAudioRecorder?
    private var recordingContinuation: CheckedContinuation<[String: Any], Error>?
    private var recordingStartTime: Date?
    private var recordingTimer: Timer?

    func handle(
        action: String,
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        switch action {
        case "ios.cameraCapture":
            handleCameraCapture(replyHandler: replyHandler)
        case "ios.microphoneRecord":
            handleMicrophoneRecord(body: body, replyHandler: replyHandler)
        default:
            replyHandler(nil, "IOSMediaBridgeHandler: unknown action '\(action)'")
        }
    }

    // MARK: - ios.cameraCapture

    private func handleCameraCapture(
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        Task { @MainActor in
            do {
                let result = try await capturePhoto()
                replyHandler(result, nil)
            } catch {
                replyHandler(nil, "ios.cameraCapture: \(error.localizedDescription)")
            }
        }
    }

    private func capturePhoto() async throws -> [String: Any] {
        guard cameraContinuation == nil else {
            throw IOSBridgeError.alreadyInProgress
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.cameraContinuation = continuation

            let picker = UIImagePickerController()
            picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
                ? .camera : .photoLibrary
            picker.delegate = self

            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.keyWindow?.rootViewController else {
                self.cameraContinuation = nil
                continuation.resume(throwing: IOSBridgeError.noRootViewController)
                return
            }
            root.present(picker, animated: true)
        }
    }

    // MARK: - ios.microphoneRecord

    private func handleMicrophoneRecord(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        let maxSeconds = body["maxSeconds"] as? Double ?? 60
        Task { @MainActor in
            do {
                let result = try await recordAudio(maxSeconds: maxSeconds)
                replyHandler(result, nil)
            } catch {
                replyHandler(nil, "ios.microphoneRecord: \(error.localizedDescription)")
            }
        }
    }

    private func recordAudio(maxSeconds: Double) async throws -> [String: Any] {
        guard recordingContinuation == nil else {
            throw IOSBridgeError.alreadyInProgress
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: tempURL, settings: settings)
        recorder.delegate = self
        self.audioRecorder = recorder

        return try await withCheckedThrowingContinuation { continuation in
            self.recordingContinuation = continuation
            self.recordingStartTime = Date()
            recorder.record()

            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: maxSeconds, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.stopRecording() }
            }
        }
    }

    private func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        audioRecorder?.stop()
    }

    private func finalizeRecording(success: Bool) {
        guard let recorder = audioRecorder,
              let continuation = recordingContinuation else { return }
        self.recordingContinuation = nil

        let duration = -(recordingStartTime?.timeIntervalSinceNow ?? 0)

        guard success else {
            self.audioRecorder = nil
            continuation.resume(throwing: IOSBridgeError.recordingFailed)
            return
        }

        do {
            let data = try Data(contentsOf: recorder.url)
            let base64 = data.base64EncodedString()
            try? FileManager.default.removeItem(at: recorder.url)
            self.audioRecorder = nil

            continuation.resume(returning: [
                "base64":   base64,
                "mimeType": "audio/m4a",
                "duration": round(duration * 100) / 100
            ])
        } catch {
            self.audioRecorder = nil
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - UIImagePickerControllerDelegate

extension IOSMediaBridgeHandler: UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    nonisolated func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        Task { @MainActor in
            picker.dismiss(animated: true)
            guard let continuation = self.cameraContinuation else { return }
            self.cameraContinuation = nil

            guard let image = info[.originalImage] as? UIImage,
                  let jpeg = image.jpegData(compressionQuality: 0.8) else {
                continuation.resume(throwing: IOSBridgeError.imageConversionFailed)
                return
            }
            continuation.resume(returning: [
                "base64":   jpeg.base64EncodedString(),
                "mimeType": "image/jpeg"
            ])
        }
    }

    nonisolated func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        Task { @MainActor in
            picker.dismiss(animated: true)
            guard let continuation = self.cameraContinuation else { return }
            self.cameraContinuation = nil
            continuation.resume(throwing: IOSBridgeError.cancelled)
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension IOSMediaBridgeHandler: AVAudioRecorderDelegate {

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.finalizeRecording(success: flag) }
    }
}

// MARK: - IOSBridgeError

enum IOSBridgeError: LocalizedError {
    case noRootViewController
    case imageConversionFailed
    case cancelled
    case recordingFailed
    case alreadyInProgress

    var errorDescription: String? {
        switch self {
        case .noRootViewController:   return "No root view controller available"
        case .imageConversionFailed:  return "Failed to convert image to JPEG"
        case .cancelled:              return "User cancelled"
        case .recordingFailed:        return "Audio recording failed"
        case .alreadyInProgress:      return "Operation already in progress"
        }
    }
}
