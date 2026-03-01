// IOSSystemBridgeHandler.swift
// iOS 专属系统能力 Bridge Handler
// 注意：所有 action 使用 "ios." 前缀，标识为 iOS 平台特有能力
//
// Actions:
//   ios.clipboardRead  — 读取剪贴板
//   ios.clipboardWrite — 写入剪贴板
//   ios.haptic         — 触觉反馈
//   ios.notify         — 本地通知
//   ios.playAudio      — 播放音频 (URL)
//   ios.pushDeviceKey  — 获取 Bark 推送 device_key

import UIKit
import AVFoundation
import UserNotifications

@MainActor
final class IOSSystemBridgeHandler {

    private var audioPlayer: AVPlayer?

    static let actions: Set<String> = [
        "ios.clipboardRead",
        "ios.clipboardWrite",
        "ios.haptic",
        "ios.notify",
        "ios.playAudio",
        "ios.pushDeviceKey"
    ]

    func handle(
        action: String,
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        switch action {
        case "ios.clipboardRead":
            handleClipboardRead(replyHandler: replyHandler)
        case "ios.clipboardWrite":
            handleClipboardWrite(body: body, replyHandler: replyHandler)
        case "ios.haptic":
            handleHaptic(body: body, replyHandler: replyHandler)
        case "ios.notify":
            handleNotify(body: body, replyHandler: replyHandler)
        case "ios.playAudio":
            handlePlayAudio(body: body, replyHandler: replyHandler)
        case "ios.pushDeviceKey":
            handlePushDeviceKey(replyHandler: replyHandler)
        default:
            replyHandler(nil, "IOSSystemBridgeHandler: unknown action '\(action)'")
        }
    }

    // MARK: - ios.clipboardRead

    private func handleClipboardRead(
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        let text = UIPasteboard.general.string
        replyHandler(text as Any, nil)
    }

    // MARK: - ios.clipboardWrite

    private func handleClipboardWrite(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let text = body["text"] as? String else {
            replyHandler(nil, "ios.clipboardWrite: missing 'text'")
            return
        }
        UIPasteboard.general.string = text
        replyHandler(true, nil)
    }

    // MARK: - ios.haptic

    private func handleHaptic(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        let style = body["style"] as? String ?? "medium"
        let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch style {
        case "light":   feedbackStyle = .light
        case "heavy":   feedbackStyle = .heavy
        case "soft":    feedbackStyle = .soft
        case "rigid":   feedbackStyle = .rigid
        default:        feedbackStyle = .medium
        }
        UIImpactFeedbackGenerator(style: feedbackStyle).impactOccurred()
        replyHandler(true, nil)
    }

    // MARK: - ios.notify

    private func handleNotify(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let title = body["title"] as? String,
              let notifyBody = body["body"] as? String else {
            replyHandler(nil, "ios.notify: missing 'title' or 'body'")
            return
        }

        let center = UNUserNotificationCenter.current()
        Task {
            do {
                try await center.requestAuthorization(options: [.alert, .sound])

                let content = UNMutableNotificationContent()
                content.title = title
                content.body = notifyBody
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: trigger
                )
                try await center.add(request)
                replyHandler(true, nil)
            } catch {
                replyHandler(false, "ios.notify: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - ios.playAudio

    private func handlePlayAudio(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let urlString = body["url"] as? String,
              let url = URL(string: urlString) else {
            replyHandler(nil, "ios.playAudio: missing or invalid 'url'")
            return
        }
        let item = AVPlayerItem(url: url)
        if audioPlayer == nil {
            audioPlayer = AVPlayer(playerItem: item)
        } else {
            audioPlayer?.replaceCurrentItem(with: item)
        }
        audioPlayer?.play()
        replyHandler(true, nil)
    }

    // MARK: - ios.pushDeviceKey

    private func handlePushDeviceKey(
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        let key = PushRegistrationService.deviceKey()
        replyHandler(key as Any, nil)
    }
}
