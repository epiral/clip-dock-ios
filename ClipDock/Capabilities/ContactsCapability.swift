// ContactsCapability.swift
// Contacts capability — list contacts from CNContactStore with optional name query
//
// Used by: IOSSystemBridgeHandler (JS Bridge), EdgeCommandRouter (Edge)

import Foundation
import Contacts

final class ContactsCapability {

    private let store = CNContactStore()

    /// List contacts, optionally filtered by name query.
    /// - Parameters:
    ///   - query: optional name substring to filter (searches given/family name)
    ///   - limit: max results (default 50)
    /// - Returns: array of contact dictionaries
    func listContacts(query: String? = nil, limit: Int = 50) async throws -> [[String: Any]] {
        try await requestAccess()

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor
        ]

        var results: [[String: Any]] = []
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)

        if let query, !query.isEmpty {
            request.predicate = CNContact.predicateForContacts(matchingName: query)
        }

        request.sortOrder = .givenName

        try store.enumerateContacts(with: request) { contact, stop in
            let phones = contact.phoneNumbers.map { $0.value.stringValue }
            let emails = contact.emailAddresses.map { $0.value as String }

            results.append([
                "givenName":    contact.givenName,
                "familyName":   contact.familyName,
                "phones":       phones,
                "emails":       emails,
                "organization": contact.organizationName
            ])

            if results.count >= limit {
                stop.pointee = true
            }
        }

        return results
    }

    // MARK: - Authorization

    private func requestAccess() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = try await store.requestAccess(for: .contacts)
            guard granted else {
                throw ContactsCapabilityError.denied
            }
        default:
            throw ContactsCapabilityError.denied
        }
    }
}

// MARK: - Errors

enum ContactsCapabilityError: LocalizedError {
    case denied

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Contacts access denied. Please allow access in Settings."
        }
    }
}
