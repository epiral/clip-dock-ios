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

    // MARK: - Command Definitions

    struct CommandDef {
        let name: String
        let description: String
        let usage: String
    }

    static let commandDefs: [CommandDef] = [
        CommandDef(
            name: "get-location",
            description: "Get current GPS coordinates",
            usage: """
            get-location — Get current GPS coordinates

            Stdin: (none required)
            Output: {"lat": 39.94, "lng": 116.42, "accuracy": 5.0, "altitude": 54.3}
            """
        ),
        CommandDef(
            name: "health-query",
            description: "Query HealthKit data",
            usage: """
            health-query — Query HealthKit data

            Stdin (JSON):
              type   (required) — one of: steps, heartRate, restingHeartRate, hrv,
                                  bloodOxygen, sleep, activeEnergy, bodyMass, bodyFat, bloodPressure
              from   (required) — ISO8601 date, e.g. "2026-03-01T00:00:00Z"
              to     (required) — ISO8601 date
              limit  (optional) — max results, default 100

            Example:
              {"type": "steps", "from": "2026-03-01T00:00:00Z", "to": "2026-03-11T23:59:59Z"}
            """
        ),
        CommandDef(
            name: "get-device-info",
            description: "Get device model, OS, battery, screen info",
            usage: """
            get-device-info — Get device information

            Stdin: (none required)
            Output: {"name": "iPhone", "model": "iPhone", "systemVersion": "26.3.1",
                     "batteryLevel": 0.85, "batteryState": "charging",
                     "screenWidth": 440, "screenHeight": 956, "screenScale": 3}
            """
        ),
        CommandDef(
            name: "send-notification",
            description: "Send a local notification",
            usage: """
            send-notification — Send a local notification to the device

            Stdin (JSON):
              title  (required) — notification title
              body   (required) — notification body

            Example:
              {"title": "Hello", "body": "Message from Pinix"}
            """
        ),
        CommandDef(
            name: "get-clipboard",
            description: "Read clipboard text",
            usage: """
            get-clipboard — Read text from device clipboard

            Stdin: (none required)
            Output: {"text": "clipboard content"}
            """
        ),
        CommandDef(
            name: "set-clipboard",
            description: "Write text to clipboard",
            usage: """
            set-clipboard — Write text to device clipboard

            Stdin (JSON):
              text  (required) — text to write

            Example:
              {"text": "hello from pinix"}
            """
        ),
        CommandDef(
            name: "haptic",
            description: "Trigger haptic feedback",
            usage: """
            haptic — Trigger haptic feedback on device

            Stdin (JSON):
              style  (optional) — one of: light, medium, heavy, soft, rigid. Default: medium

            Example:
              {"style": "heavy"}
            """
        ),
        CommandDef(
            name: "list-contacts",
            description: "List contacts with optional name query",
            usage: """
            list-contacts — List contacts from device address book

            Stdin (JSON):
              query  (optional) — name filter
              limit  (optional) — max results, default 50

            Example:
              {"query": "张", "limit": 10}
            """
        ),
        CommandDef(
            name: "list-events",
            description: "List calendar events by date range",
            usage: """
            list-events — List calendar events

            Stdin (JSON):
              from   (required) — ISO8601 start date
              to     (required) — ISO8601 end date
              limit  (optional) — max results, default 50

            Example:
              {"from": "2026-03-10T00:00:00Z", "to": "2026-03-17T00:00:00Z"}
            """
        ),
        CommandDef(
            name: "create-event",
            description: "Create a calendar event",
            usage: """
            create-event — Create a new calendar event

            Stdin (JSON):
              title     (required) — event title
              startDate (required) — ISO8601 start date
              endDate   (required) — ISO8601 end date
              notes     (optional) — event notes
              location  (optional) — event location
              isAllDay  (optional) — boolean, default false

            Example:
              {"title": "Meeting", "startDate": "2026-03-12T14:00:00Z", "endDate": "2026-03-12T15:00:00Z"}
            """
        ),
    ]

    // MARK: - Execute

    func execute(name: String, args: [String], stdin: String) async -> (stdout: Data, exitCode: Int32) {
        // --help / -h support
        if args.contains("--help") || args.contains("-h") || stdin.trimmingCharacters(in: .whitespacesAndNewlines) == "--help" {
            return (Data(helpText(for: name).utf8), 0)
        }

        do {
            return try await executeInner(name: name, stdin: stdin)
        } catch {
            let msg = error.localizedDescription
            return (Data(msg.utf8), 1)
        }
    }

    // MARK: - Help

    private func helpText(for name: String) -> String {
        if let def = Self.commandDefs.first(where: { $0.name == name }) {
            return def.usage
        }
        return allCommandsHelp()
    }

    private func allCommandsHelp() -> String {
        var lines = ["clip-dock-ios — iPhone Edge Clip commands\n"]
        for def in Self.commandDefs {
            lines.append("  \(def.name.padding(toLength: 20, withPad: " ", startingAt: 0))\(def.description)")
        }
        lines.append("\nUse: pinix invoke <command> -h  for detailed usage")
        return lines.joined(separator: "\n")
    }

    // MARK: - Inner Execute

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
