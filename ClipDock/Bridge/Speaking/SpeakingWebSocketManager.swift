// SpeakingWebSocketManager.swift
// URLSessionWebSocket wrapper with auto-reconnect
// Ported from speaking-practice — replaced AppLogger with os.Logger

import Foundation
import os

protocol SpeakingWebSocketManagerDelegate: AnyObject {
    func webSocketDidConnect()
    func webSocketDidDisconnect(error: Error?)
    func webSocketDidReceive(message: [String: Any])
    func webSocketDidAttemptReconnect(attempt: Int)
    func webSocketDidFailReconnect()
}

final class SpeakingWebSocketManager: NSObject {
    weak var delegate: SpeakingWebSocketManagerDelegate?

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let log = Logger(subsystem: "com.epiral.clip-dock", category: "SpeakingWS")
    private var isConnected = false
    private var isIntentionalDisconnect = false
    private var pingTimer: Timer?

    private var currentAPIKey: String?
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 3
    private let reconnectDelays: [TimeInterval] = [1, 2, 4]
    private var reconnectWorkItem: DispatchWorkItem?

    func connect(apiKey: String) {
        currentAPIKey = apiKey
        reconnectAttempt = 0
        isIntentionalDisconnect = false
        performConnect(apiKey: apiKey)
    }

    func disconnect() {
        isIntentionalDisconnect = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        pingTimer?.invalidate()
        pingTimer = nil
        isConnected = false
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        log.info("WebSocket disconnected")
    }

    func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            log.error("Failed to serialize message")
            return
        }
        webSocket?.send(.string(text)) { [weak self] error in
            if let error = error {
                self?.log.error("WebSocket send error: \(error.localizedDescription)")
            }
        }
    }

    private func performConnect(apiKey: String) {
        guard let url = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-omni-flash-realtime") else {
            log.error("Invalid WebSocket URL")
            return
        }

        webSocket?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        webSocket = urlSession?.webSocketTask(with: request)
        webSocket?.resume()

        log.info("WebSocket connecting...")
        receiveMessage()
    }

    private func attemptReconnect() {
        guard !isIntentionalDisconnect,
              reconnectAttempt < maxReconnectAttempts,
              let apiKey = currentAPIKey else {
            if !isIntentionalDisconnect {
                log.error("WebSocket reconnection failed after \(self.reconnectAttempt) attempts")
                delegate?.webSocketDidFailReconnect()
            }
            return
        }

        let delay = reconnectDelays[reconnectAttempt]
        reconnectAttempt += 1
        log.info("WebSocket reconnecting (attempt \(self.reconnectAttempt)/\(self.maxReconnectAttempts)) in \(delay)s")
        delegate?.webSocketDidAttemptReconnect(attempt: reconnectAttempt)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isIntentionalDisconnect else { return }
            self.performConnect(apiKey: apiKey)
        }
        reconnectWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.delegate?.webSocketDidReceive(message: json)
                    }
                case .data(let data):
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.delegate?.webSocketDidReceive(message: json)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()
            case .failure(let error):
                if self.isIntentionalDisconnect {
                    self.log.debug("WebSocket receive ended (normal close)")
                    self.isConnected = false
                    self.delegate?.webSocketDidDisconnect(error: nil)
                } else {
                    self.log.error("WebSocket receive error: \(error.localizedDescription)")
                    self.isConnected = false
                    self.attemptReconnect()
                }
            }
        }
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.webSocket?.sendPing { error in
                if let error = error {
                    self?.log.error("Ping error: \(error.localizedDescription)")
                }
            }
        }
    }
}

extension SpeakingWebSocketManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        log.info("WebSocket connected")
        isConnected = true
        reconnectAttempt = 0
        DispatchQueue.main.async { [weak self] in
            self?.startPing()
        }
        delegate?.webSocketDidConnect()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        log.info("WebSocket closed: \(closeCode.rawValue)")
        isConnected = false
        if isIntentionalDisconnect {
            delegate?.webSocketDidDisconnect(error: nil)
        } else {
            attemptReconnect()
        }
    }
}
