// IOSSystemBridgeHandler.swift
// iOS 专属系统能力 Bridge Handler — thin wrappers over Capabilities
// 注意：所有 action 使用 "ios." 前缀，标识为 iOS 平台特有能力
//
// Actions:
//   ios.clipboardRead  — 读取剪贴板
//   ios.clipboardWrite — 写入剪贴板
//   ios.haptic         — 触觉反馈
//   ios.notify         — 本地通知
//   ios.playAudio      — 播放音频 (URL)
//   ios.pushDeviceKey  — 获取 Bark 推送 device_key
//   ios.contactsList   — 查询通讯录
//   ios.calendarList   — 查询日历事件
//   ios.calendarCreate — 创建日历事件

import UIKit
import AVFoundation

@MainActor
final class IOSSystemBridgeHandler {

    private var audioPlayer: AVPlayer?

    private let clipboard    = ClipboardCapability()
    private let notification = NotificationCapability()
    private let haptic       = HapticCapability()
    private let contacts     = ContactsCapability()
    private let calendar     = CalendarCapability()

    static let actions: Set<String> = [
        "ios.clipboardRead",
        "ios.clipboardWrite",
        "ios.haptic",
        "ios.notify",
        "ios.playAudio",
        "ios.pushDeviceKey",
        "ios.contactsList",
        "ios.calendarList",
        "ios.calendarCreate"
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
        case "ios.contactsList":
            handleContactsList(body: body, replyHandler: replyHandler)
        case "ios.calendarList":
            handleCalendarList(body: body, replyHandler: replyHandler)
        case "ios.calendarCreate":
            handleCalendarCreate(body: body, replyHandler: replyHandler)
        default:
            replyHandler(nil, "IOSSystemBridgeHandler: unknown action '\(action)'")
        }
    }

    // MARK: - ios.clipboardRead

    private func handleClipboardRead(
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        let text = clipboard.read()
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
        clipboard.write(text: text)
        replyHandler(true, nil)
    }

    // MARK: - ios.haptic

    private func handleHaptic(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        let style = body["style"] as? String ?? "medium"
        haptic.trigger(style: style)
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

        Task {
            do {
                try await notification.send(title: title, body: notifyBody)
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

    // MARK: - ios.contactsList

    private func handleContactsList(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        let query = body["query"] as? String
        let limit = body["limit"] as? Int ?? 50

        Task {
            do {
                let results = try await contacts.listContacts(query: query, limit: limit)
                replyHandler(["data": results], nil)
            } catch {
                replyHandler(nil, "ios.contactsList: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - ios.calendarList

    private func handleCalendarList(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let fromString = body["from"] as? String,
              let from = HealthCapability.parseISO8601(fromString) else {
            replyHandler(nil, "ios.calendarList: missing or invalid 'from' (ISO8601)")
            return
        }

        guard let toString = body["to"] as? String,
              let to = HealthCapability.parseISO8601(toString) else {
            replyHandler(nil, "ios.calendarList: missing or invalid 'to' (ISO8601)")
            return
        }

        let limit = body["limit"] as? Int ?? 50

        Task {
            do {
                let results = try await calendar.listEvents(from: from, to: to, limit: limit)
                replyHandler(["data": results], nil)
            } catch {
                replyHandler(nil, "ios.calendarList: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - ios.calendarCreate

    private func handleCalendarCreate(
        body: [String: Any],
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let title = body["title"] as? String else {
            replyHandler(nil, "ios.calendarCreate: missing 'title'")
            return
        }

        guard let startString = body["startDate"] as? String,
              let startDate = HealthCapability.parseISO8601(startString) else {
            replyHandler(nil, "ios.calendarCreate: missing or invalid 'startDate' (ISO8601)")
            return
        }

        guard let endString = body["endDate"] as? String,
              let endDate = HealthCapability.parseISO8601(endString) else {
            replyHandler(nil, "ios.calendarCreate: missing or invalid 'endDate' (ISO8601)")
            return
        }

        let isAllDay = body["isAllDay"] as? Bool ?? false
        let location = body["location"] as? String
        let notes = body["notes"] as? String

        Task {
            do {
                let result = try await calendar.createEvent(
                    title: title,
                    startDate: startDate,
                    endDate: endDate,
                    isAllDay: isAllDay,
                    location: location,
                    notes: notes
                )
                replyHandler(result, nil)
            } catch {
                replyHandler(nil, "ios.calendarCreate: \(error.localizedDescription)")
            }
        }
    }
}
