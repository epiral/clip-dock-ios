// CalendarCapability.swift
// Calendar capability — list events by date range, create events via EKEventStore
//
// Used by: IOSSystemBridgeHandler (JS Bridge), EdgeCommandRouter (Edge)

import Foundation
import EventKit

final class CalendarCapability {

    private let store = EKEventStore()

    /// List calendar events within a date range.
    /// - Parameters:
    ///   - from: start date
    ///   - to: end date
    ///   - limit: max results (default 50)
    /// - Returns: array of event dictionaries
    func listEvents(from: Date, to: Date, limit: Int = 50) async throws -> [[String: Any]] {
        try await requestAccess()

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = store.events(matching: predicate)
        let formatter = ISO8601DateFormatter()

        let capped = events.prefix(limit)
        return capped.map { event in
            var dict: [String: Any] = [
                "title":     event.title ?? "",
                "startDate": formatter.string(from: event.startDate),
                "endDate":   formatter.string(from: event.endDate),
                "isAllDay":  event.isAllDay,
                "calendar":  event.calendar.title
            ]
            if let location = event.location, !location.isEmpty {
                dict["location"] = location
            }
            if let notes = event.notes, !notes.isEmpty {
                dict["notes"] = notes
            }
            return dict
        }
    }

    /// Create a calendar event.
    /// - Parameters:
    ///   - title: event title
    ///   - startDate: event start
    ///   - endDate: event end
    ///   - isAllDay: whether event is all-day
    ///   - location: optional location string
    ///   - notes: optional notes
    /// - Returns: { eventIdentifier }
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil
    ) async throws -> [String: Any] {
        try await requestAccess()

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.isAllDay = isAllDay
        event.calendar = store.defaultCalendarForNewEvents

        if let location {
            event.location = location
        }
        if let notes {
            event.notes = notes
        }

        try store.save(event, span: .thisEvent)

        return ["eventIdentifier": event.eventIdentifier ?? ""]
    }

    // MARK: - Authorization

    private func requestAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized:
            return
        case .notDetermined:
            let granted = try await store.requestFullAccessToEvents()
            guard granted else {
                throw CalendarCapabilityError.denied
            }
        default:
            throw CalendarCapabilityError.denied
        }
    }
}

// MARK: - Errors

enum CalendarCapabilityError: LocalizedError {
    case denied
    case invalidDate

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Calendar access denied. Please allow access in Settings."
        case .invalidDate:
            return "Invalid date format. Use ISO8601 (e.g. 2024-01-01T00:00:00Z)."
        }
    }
}
