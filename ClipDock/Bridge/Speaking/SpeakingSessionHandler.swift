// SpeakingSessionHandler.swift
// Bridge handler for Qwen Realtime voice conversation
//
// Actions:
//   ios.speakingStart  — start session (apiKey, topic?)
//   ios.speakingStop   — stop session
//   ios.speakingStatus — query session state
//
// Events (pushed to JS via CustomEvent):
//   pinix-bridge-event { type: "onTranscript", role, text, final }

import UIKit
import AVFoundation
import WebKit
import os

@MainActor
final class SpeakingSessionHandler {

    static let actions: Set<String> = [
        "ios.speakingStart",
        "ios.speakingStop",
        "ios.speakingStatus"
    ]

    weak var webView: WKWebView?

    private var qwen: SpeakingQwenClient?
    private var audio: SpeakingAudioManager?
    private var sessionId: String?
    private var startTime: Date?
    private var isActive = false
    private var assistantBuffer = ""
    private var pendingReplyHandler: (@MainActor @Sendable (Any?, String?) -> Void)?
    private var pendingTopic: String?
    private let log = Logger(subsystem: "com.epiral.clip-dock", category: "SpeakingSession")

    func handle(
        action: String,
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        switch action {
        case "ios.speakingStart":
            handleStart(body: body, replyHandler: replyHandler)
        case "ios.speakingStop":
            handleStop(replyHandler: replyHandler)
        case "ios.speakingStatus":
            handleStatus(replyHandler: replyHandler)
        default:
            replyHandler(nil, "SpeakingSessionHandler: unknown action '\(action)'")
        }
    }

    // MARK: - ios.speakingStart

    private func handleStart(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard !isActive else {
            replyHandler(nil, "ios.speakingStart: session already active")
            return
        }

        guard let apiKey = body["apiKey"] as? String, !apiKey.isEmpty else {
            replyHandler(nil, "ios.speakingStart: missing 'apiKey'")
            return
        }

        // Check microphone permission
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            replyHandler(nil, "ios.speakingStart: microphone access denied")
            return
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.doStart(apiKey: apiKey, body: body, replyHandler: replyHandler)
                    } else {
                        replyHandler(nil, "ios.speakingStart: microphone access denied")
                    }
                }
            }
            return
        case .granted:
            break
        @unknown default:
            break
        }

        doStart(apiKey: apiKey, body: body, replyHandler: replyHandler)
    }

    private func doStart(
        apiKey: String,
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        let topic = body["topic"] as? String
        let newSessionId = UUID().uuidString

        log.info("Starting speaking session \(newSessionId)")

        let audioMgr = SpeakingAudioManager()
        let qwenClient = SpeakingQwenClient()

        do {
            try audioMgr.setupSession()
        } catch {
            log.error("Audio session setup failed: \(error.localizedDescription)")
            replyHandler(nil, "ios.speakingStart: audio setup failed — \(error.localizedDescription)")
            return
        }

        audioMgr.delegate = self
        qwenClient.delegate = self

        self.audio = audioMgr
        self.qwen = qwenClient
        self.sessionId = newSessionId
        self.startTime = Date()
        self.isActive = true
        self.assistantBuffer = ""
        self.pendingReplyHandler = replyHandler
        self.pendingTopic = topic

        qwenClient.connect(apiKey: apiKey)
    }

    // MARK: - ios.speakingStop

    private func handleStop(
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard isActive else {
            replyHandler(nil, "ios.speakingStop: no active session")
            return
        }

        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        teardown()
        replyHandler(["duration": Int(duration)], nil)
    }

    // MARK: - ios.speakingStatus

    private func handleStatus(
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        var result: [String: Any] = ["active": isActive]
        if isActive {
            result["sessionId"] = sessionId
            if let start = startTime {
                result["duration"] = Int(Date().timeIntervalSince(start))
            }
        }
        replyHandler(result, nil)
    }

    // MARK: - Teardown

    private func teardown() {
        audio?.stopRecording()
        qwen?.disconnect()
        audio?.deactivateSession()

        audio = nil
        qwen = nil
        isActive = false
        sessionId = nil
        startTime = nil
        assistantBuffer = ""
        pendingReplyHandler = nil
        pendingTopic = nil

        log.info("Session teardown complete")
    }

    // MARK: - JS Event Dispatch

    private func dispatchTranscript(role: String, text: String, isFinal: Bool) {
        guard let webView else { return }
        let payload: [String: Any] = [
            "type": "onTranscript",
            "role": role,
            "text": text,
            "final": isFinal
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let js = "window.dispatchEvent(new CustomEvent('pinix-bridge-event', { detail: \(jsonStr) }));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

// MARK: - SpeakingQwenDelegate

extension SpeakingSessionHandler: SpeakingQwenDelegate {
    nonisolated func qwenDidConnect() {
        Task { @MainActor in
            log.info("Qwen connected — starting recording")

            // Send session update with topic if provided
            if let topic = pendingTopic {
                qwen?.sendSessionUpdate(topic: topic)
            }

            do {
                try audio?.startRecording()
            } catch {
                log.error("Recording start failed: \(error)")
                let handler = pendingReplyHandler
                pendingReplyHandler = nil
                teardown()
                handler?(nil, "ios.speakingStart: microphone error — \(error.localizedDescription)")
                return
            }

            // Reply to the pending start request
            let handler = pendingReplyHandler
            pendingReplyHandler = nil
            handler?(["sessionId": sessionId as Any], nil)
        }
    }

    nonisolated func qwenDidDisconnect(error: Error?) {
        Task { @MainActor in
            guard isActive else { return }
            log.error("Unexpected disconnect: \(error?.localizedDescription ?? "unknown")")
            // If we still have a pending start handler, reply with error
            if let handler = pendingReplyHandler {
                pendingReplyHandler = nil
                teardown()
                handler(nil, "ios.speakingStart: connection failed — \(error?.localizedDescription ?? "unknown")")
            } else {
                teardown()
            }
        }
    }

    nonisolated func qwenDidReceiveAudio(_ buffer: AVAudioPCMBuffer) {
        Task { @MainActor in
            audio?.playAudio(buffer)
        }
    }

    nonisolated func qwenDidReceiveTranscript(role: String, text: String, isFinal: Bool) {
        Task { @MainActor in
            if role == "user" {
                dispatchTranscript(role: "user", text: text, isFinal: true)
            } else if role == "assistant" {
                if isFinal {
                    let finalText = text.isEmpty ? assistantBuffer : text
                    if !finalText.isEmpty {
                        dispatchTranscript(role: "assistant", text: finalText, isFinal: true)
                    }
                    assistantBuffer = ""
                } else {
                    assistantBuffer += text
                    dispatchTranscript(role: "assistant", text: text, isFinal: false)
                }
            }
        }
    }

    nonisolated func qwenDidDetectSpeechStarted() {
        Task { @MainActor in
            audio?.stopPlayback()
            if !assistantBuffer.isEmpty {
                dispatchTranscript(role: "assistant", text: assistantBuffer, isFinal: true)
                assistantBuffer = ""
            }
        }
    }

    nonisolated func qwenDidDetectSpeechStopped() {
        // No-op — VAD handling is done server-side
    }

    nonisolated func qwenResponseDidStart() {
        Task { @MainActor in
            assistantBuffer = ""
        }
    }

    nonisolated func qwenResponseDidEnd() {
        // No-op
    }

    nonisolated func qwenDidError(_ message: String) {
        Task { @MainActor in
            if let handler = pendingReplyHandler {
                pendingReplyHandler = nil
                teardown()
                handler(nil, "ios.speakingStart: \(message)")
            } else {
                teardown()
            }
        }
    }
}

// MARK: - SpeakingAudioManagerDelegate

extension SpeakingSessionHandler: SpeakingAudioManagerDelegate {
    nonisolated func audioManagerDidCapture(base64: String) {
        // Send captured audio directly to Qwen — no MainActor hop needed
        // because sendAudio just serializes JSON and calls URLSessionWebSocketTask.send
        Task { @MainActor in
            qwen?.sendAudio(base64)
        }
    }

    nonisolated func audioManagerDidEncounterFatalError(_ reason: String) {
        Task { @MainActor in
            log.error("AudioManager fatal: \(reason)")
            teardown()
        }
    }
}
