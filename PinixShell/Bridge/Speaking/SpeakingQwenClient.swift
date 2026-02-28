// SpeakingQwenClient.swift
// Qwen Omni Realtime WebSocket client for audio frame send/receive
// Ported from speaking-practice — removed AppSecrets/TopicStore/AppLogger dependencies

import Foundation
import AVFoundation
import os

protocol SpeakingQwenDelegate: AnyObject {
    func qwenDidConnect()
    func qwenDidDisconnect(error: Error?)
    func qwenDidReceiveAudio(_ buffer: AVAudioPCMBuffer)
    func qwenDidReceiveTranscript(role: String, text: String, isFinal: Bool)
    func qwenDidDetectSpeechStarted()
    func qwenDidDetectSpeechStopped()
    func qwenResponseDidStart()
    func qwenResponseDidEnd()
    func qwenDidError(_ message: String)
}

final class SpeakingQwenClient {
    weak var delegate: SpeakingQwenDelegate?

    private let ws = SpeakingWebSocketManager()
    private let log = Logger(subsystem: "com.epiral.pinix-shell", category: "SpeakingQwen")
    private var isResponding = false

    init() {
        ws.delegate = self
    }

    func connect(apiKey: String) {
        ws.connect(apiKey: apiKey)
    }

    func disconnect() {
        ws.disconnect()
    }

    func sendAudio(_ base64: String) {
        ws.send([
            "type": QwenEventType.inputAudioAppend,
            "event_id": makeEventId(),
            "audio": base64
        ])
    }

    func commitAudio() {
        ws.send([
            "type": QwenEventType.inputAudioCommit,
            "event_id": makeEventId()
        ])
    }

    func cancelResponse() {
        log.info("[Barge-in] cancelResponse called, isResponding=\(self.isResponding)")
        ws.send([
            "type": QwenEventType.responseCancel,
            "event_id": makeEventId()
        ])
        isResponding = false
    }

    func sendSessionUpdate(voice: String = "Ethan", topic: String? = nil) {
        var config = QwenSessionConfig()
        config.instructions = QwenRealtimeConfig.buildSystemPrompt(topic: topic)
        config.voice = voice
        ws.send([
            "type": QwenEventType.sessionUpdate,
            "event_id": makeEventId(),
            "session": config.toDict()
        ])
        log.info("Session update sent (voice=\(voice))")
    }

    private func makeEventId() -> String {
        "event_\(Int(Date().timeIntervalSince1970 * 1000))"
    }

    private func handleMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }

        switch type {
        case QwenEventType.error:
            if let err = msg["error"] as? [String: Any], let message = err["message"] as? String {
                log.error("Qwen error: \(message)")
                delegate?.qwenDidError(message)
            }

        case QwenEventType.speechStarted:
            log.info("[Barge-in] speech_started received, isResponding=\(self.isResponding)")
            cancelResponse()
            delegate?.qwenDidDetectSpeechStarted()

        case QwenEventType.speechStopped:
            log.debug("Speech stopped")
            delegate?.qwenDidDetectSpeechStopped()
            if !isResponding {
                log.info("speechStopped — sending commit + response.create")
                commitAudio()
                ws.send([
                    "type": QwenEventType.responseCreate,
                    "event_id": makeEventId()
                ])
            }

        case QwenEventType.responseCreated:
            isResponding = true
            log.info("[Barge-in] response.created — isResponding=true")
            delegate?.qwenResponseDidStart()

        case QwenEventType.audioDelta:
            guard isResponding else { break }
            if let delta = msg["delta"] as? String, let buffer = PCMCodec.decode(delta) {
                delegate?.qwenDidReceiveAudio(buffer)
            }

        case QwenEventType.inputTranscriptionCompleted:
            if let transcript = msg["transcript"] as? String, !transcript.isEmpty {
                log.info("User said: \(transcript)")
                delegate?.qwenDidReceiveTranscript(role: "user", text: transcript, isFinal: true)
            }

        case QwenEventType.audioTranscriptDelta:
            if let delta = msg["delta"] as? String {
                delegate?.qwenDidReceiveTranscript(role: "assistant", text: delta, isFinal: false)
            }

        case QwenEventType.audioTranscriptDone:
            if let transcript = msg["transcript"] as? String {
                log.info("AI said: \(transcript)")
                delegate?.qwenDidReceiveTranscript(role: "assistant", text: transcript, isFinal: true)
            }

        case QwenEventType.responseDone:
            isResponding = false
            log.info("[Barge-in] response.done — isResponding=false")
            delegate?.qwenResponseDidEnd()

        default:
            break
        }
    }
}

extension SpeakingQwenClient: SpeakingWebSocketManagerDelegate {
    func webSocketDidConnect() {
        log.info("Qwen connected, sending session update")
        sendSessionUpdate()
        delegate?.qwenDidConnect()
    }

    func webSocketDidDisconnect(error: Error?) {
        isResponding = false
        delegate?.qwenDidDisconnect(error: error)
    }

    func webSocketDidReceive(message: [String: Any]) {
        handleMessage(message)
    }

    func webSocketDidAttemptReconnect(attempt: Int) {
        log.info("WebSocket reconnect attempt \(attempt)")
    }

    func webSocketDidFailReconnect() {
        log.error("WebSocket reconnection failed permanently")
        isResponding = false
        delegate?.qwenDidError("Connection lost. Please try again.")
    }
}
