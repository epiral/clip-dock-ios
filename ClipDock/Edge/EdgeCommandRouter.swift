// EdgeCommandRouter.swift
// Routes Edge command names to native Capability calls
//
// Each command: parse stdin JSON -> call capability -> return JSON stdout + exit code 0
// On error: stderr + exit code 1
//
// Commands:
//   get-location, health-query, get-device-info, send-notification,
//   get-clipboard, set-clipboard, haptic,
//   list-contacts, list-events, create-event

import Foundation

@MainActor
final class EdgeCommandRouter {

    private let location     = LocationCapability()
    private let health       = HealthCapability()
    private let deviceInfo   = DeviceInfoCapability()
    private let notification = NotificationCapability()
    private let clipboard    = ClipboardCapability()
    private let haptic       = HapticCapability()
    private let contacts     = ContactsCapability()
    private let calendar     = CalendarCapability()

    /// All command definitions for the EdgeManifest.
    static let commandDefs: [(name: String, description: String)] = [
        ("get-location",    "Get current GPS coordinates"),
        ("health-query",    "Query HealthKit data (type, from, to, limit)"),
        ("get-device-info", "Get device model, OS, battery, screen info"),
        ("send-notification", "Send a local notification (title, body)"),
        ("get-clipboard",   "Read clipboard text"),
        ("set-clipboard",   "Write text to clipboard"),
        ("haptic",          "Trigger haptic feedback (style)"),
        ("list-contacts",   "List contacts with optional name query"),
        ("list-events",     "List calendar events by date range"),
        ("create-event",    "Create a calendar event")
    ]

    /// Execute a command by name with JSON stdin.
    /// Returns (stdout JSON Data, exit code). On error throws.
    func execute(name: String, stdin: String) async -> (stdout: Data, exitCode: Int32) {
        do {
            return try await executeInner(name: name, stdin: stdin)
        } catch {
            let errMsg = error.localizedDescription
            let errData = try! JSONSerialization.data(withJSONObject: ["error": errMsg])
            return (errData, 1)
        }
    }

    private func executeInner(name: String, stdin: String) async throws -> (stdout: Data, exitCode: Int32) {
        let params = Self.parseStdin(stdin)

        let result: Any
        switch name {
        case "get-location":
            result = try await location.getLocation()

        case "health-query":
            result = try await handleHealthQuery(params: params)

        case "get-device-info":
            result = deviceInfo.getInfo()

        case "send-notification":
            try await handleSendNotification(params: params)
            result = ["ok": true]

        case "get-clipboard":
            result = ["text": clipboard.read() ?? ""]

        case "set-clipboard":
            guard let text = params["text"] as? String else {
                throw EdgeCommandError.missingParam("text")
            }
            clipboard.write(text: text)
            result = ["ok": true]

        case "haptic":
            let style = params["style"] as? String ?? "medium"
            haptic.trigger(style: style)
            result = ["ok": true]

        case "list-contacts":
            result = try await handleListContacts(params: params)

        case "list-events":
            result = try await handleListEvents(params: params)

        case "create-event":
            result = try await handleCreateEvent(params: params)

        default:
            throw EdgeCommandError.unknownCommand(name)
        }

        let jsonData = try JSONSerialization.data(withJSONObject: result)
        return (jsonData, 0)
    }

    // MARK: - Command Handlers

    private func handleHealthQuery(params: [String: Any]) async throws -> Any {
        guard let typeString = params["type"] as? String else {
            throw EdgeCommandError.missingParam("type")
        }
        guard let fromString = params["from"] as? String,
              let from = HealthCapability.parseISO8601(fromString) else {
            throw EdgeCommandError.missingParam("from (ISO8601)")
        }
        guard let toString = params["to"] as? String,
              let to = HealthCapability.parseISO8601(toString) else {
            throw EdgeCommandError.missingParam("to (ISO8601)")
        }
        let limit = params["limit"] as? Int ?? 100
        return try await health.query(typeString: typeString, from: from, to: to, limit: limit)
    }

    private func handleSendNotification(params: [String: Any]) async throws {
        guard let title = params["title"] as? String else {
            throw EdgeCommandError.missingParam("title")
        }
        guard let body = params["body"] as? String else {
            throw EdgeCommandError.missingParam("body")
        }
        try await notification.send(title: title, body: body)
    }

    private func handleListContacts(params: [String: Any]) async throws -> Any {
        let query = params["query"] as? String
        let limit = params["limit"] as? Int ?? 50
        let data = try await contacts.listContacts(query: query, limit: limit)
        return ["data": data]
    }

    private func handleListEvents(params: [String: Any]) async throws -> Any {
        guard let fromString = params["from"] as? String,
              let from = HealthCapability.parseISO8601(fromString) else {
            throw EdgeCommandError.missingParam("from (ISO8601)")
        }
        guard let toString = params["to"] as? String,
              let to = HealthCapability.parseISO8601(toString) else {
            throw EdgeCommandError.missingParam("to (ISO8601)")
        }
        let limit = params["limit"] as? Int ?? 50
        let data = try await calendar.listEvents(from: from, to: to, limit: limit)
        return ["data": data]
    }

    private func handleCreateEvent(params: [String: Any]) async throws -> Any {
        guard let title = params["title"] as? String else {
            throw EdgeCommandError.missingParam("title")
        }
        guard let startString = params["startDate"] as? String,
              let startDate = HealthCapability.parseISO8601(startString) else {
            throw EdgeCommandError.missingParam("startDate (ISO8601)")
        }
        guard let endString = params["endDate"] as? String,
              let endDate = HealthCapability.parseISO8601(endString) else {
            throw EdgeCommandError.missingParam("endDate (ISO8601)")
        }
        let isAllDay = params["isAllDay"] as? Bool ?? false
        let location = params["location"] as? String
        let notes = params["notes"] as? String
        return try await calendar.createEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: location,
            notes: notes
        )
    }

    // MARK: - Helpers

    private static func parseStdin(_ stdin: String) -> [String: Any] {
        guard !stdin.isEmpty,
              let data = stdin.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }
}

// MARK: - Errors

enum EdgeCommandError: LocalizedError {
    case unknownCommand(String)
    case missingParam(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let name):
            return "Unknown edge command: \(name)"
        case .missingParam(let param):
            return "Missing required parameter: \(param)"
        }
    }
}
