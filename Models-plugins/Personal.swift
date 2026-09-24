//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Contacts
import Foundation

// The user's own records: contacts, notes and email drafts. Reading is free; a new note waits for the user's
// approval, and an email is only ever a draft the user sends themselves.

// Contacts

enum ContactsAccess {
    /// Asks when the user turns the switch on, so macOS prompts then and never in the middle of an answer.
    static func request() { CNContactStore().requestAccess(for: .contacts) { _, _ in } }
}

/// `contacts_search`: phone numbers, emails and addresses from the user's Contacts, by name, email or phone. Read only.
public struct ContactsToolProvider: ToolProvider {
    public var limit = 10

    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "contacts_search",
                description:
                    "Find people in the user's Contacts by name, email or phone number: their phones, emails, addresses, company and birthday.",
                parametersJSONSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#)
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        guard let query = ToolArguments(call.argumentsJSON).string("query")?.trimmingCharacters(in: .whitespaces), !query.isEmpty
        else { return toolFailure(missing: "query") }
        // Asked on every call without access: macOS shows its question while it has none, its privacy pane after a refusal.
        if CNContactStore.authorizationStatus(for: .contacts) != .authorized {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: break
        default:
            PrivacySettings.ask(.contacts)
            return
                "error: Mac-Olama may not read Contacts. A notification now asks the user to allow Mac-Olama in System Settings → Privacy & Security → Contacts; ask again once they have."
        }
        let digits = query.filter(\.isNumber)
        let predicate =
            query.contains("@")
            ? CNContact.predicateForContacts(matchingEmailAddress: query)
            : digits.count >= 5
                ? CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
                : CNContact.predicateForContacts(matchingName: query)
        let keys =
            [
                CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey,
                CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactBirthdayKey,
            ] as [CNKeyDescriptor]
        let found: [CNContact]
        do {
            found = try CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys)
        } catch {
            return "error: Contacts did not answer (\(error.localizedDescription))"
        }
        guard !found.isEmpty else { return "No contact matches \"\(query)\"." }
        let people = found.prefix(limit).map { contact -> String in
            var lines = ["- " + [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")]
            if !contact.organizationName.isEmpty { lines[0] += " (\(contact.organizationName))" }
            lines += contact.phoneNumbers.map { "  phone" + Self.label($0.label) + ": " + $0.value.stringValue }
            lines += contact.emailAddresses.map { "  email" + Self.label($0.label) + ": " + String($0.value) }
            lines += contact.postalAddresses.map {
                "  address" + Self.label($0.label) + ": "
                    + CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ")
            }
            if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
                lines.append(
                    "  birthday: " + (birthday.year.map { String(format: "%04d-", $0) } ?? "") + String(format: "%02d-%02d", month, day))
            }
            return lines.joined(separator: "\n")
        }
        return (["Contacts matching \"\(query)\":"] + people).joined(separator: "\n")
    }

    /// "home", "work", "mobile": the label Contacts stores, in words.
    private static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return " (" + CNLabeledValue<NSString>.localizedString(forLabel: raw) + ")"
    }
}

// Notes

/// `notes_search`, `notes_read` and `notes_create`: the Notes app through Apple Events. A new note is approved first.
public struct NotesToolProvider: ToolProvider {
    public var confirmation: (any ToolConfirmation)?
    public var maxCharacters = 8000

    public init(confirmation: (any ToolConfirmation)?) { self.confirmation = confirmation }

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "notes_search",
                description: "Find the user's notes in Notes by words in the title or text: title, folder, date changed and the beginning.",
                parametersJSONSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#),
            ToolSpec(
                name: "notes_read", description: "Read one note from Notes in full, by its title.",
                parametersJSONSchema: #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#),
            ToolSpec(
                name: "notes_create", description: "Create a note in Notes. The user approves it first.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"title":{"type":"string"},"text":{"type":"string"}},"required":["title","text"]}"#
            ),
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        let out: String
        switch call.name {
        case "notes_search":
            guard let query = args.string("query"), !query.isEmpty else { return toolFailure(missing: "query") }
            out = try await JXA.run(
                """
                const N = Application('Notes');
                const q = \(JXA.literal(query));
                const found = N.notes.whose({ _or: [{ name: { _contains: q } }, { plaintext: { _contains: q } }] })();
                return found.slice(0, 10).map(n =>
                  '- ' + n.name() + ' [' + n.container().name() + '], changed ' + n.modificationDate().toISOString().slice(0, 10)
                    + '\\n  ' + n.plaintext().replace(/\\s+/g, ' ').slice(0, 300)).join('\\n') || 'NONE';
                """)
            if out == "NONE" { return "No note has \"\(query)\" in it." }
        case "notes_read":
            guard let title = args.string("title"), !title.isEmpty else { return toolFailure(missing: "title") }
            out = try await JXA.run(
                """
                const N = Application('Notes');
                const t = \(JXA.literal(title));
                const exact = N.notes.whose({ name: t })();
                const found = exact.length ? exact : N.notes.whose({ name: { _contains: t } })();
                if (!found.length) return 'NONE';
                return found[0].name() + '\\n\\n' + found[0].plaintext().slice(0, \(maxCharacters));
                """)
            if out == "NONE" { return "error: no note is called \"\(title)\"; try notes_search" }
        case "notes_create":
            guard let title = args.string("title"), !title.isEmpty, let text = args.string("text") else {
                return toolFailure(missing: "title or text")
            }
            guard let confirmation else { return "error: creating a note needs the user's approval" }
            guard await confirmation.confirm(title: String(localized: "Create the note “\(title)”?"), detail: String(text.prefix(300)))
            else { return "error: the user declined the note" }
            out = try await JXA.run(
                """
                const N = Application('Notes');
                N.defaultAccount.defaultFolder.notes.push(N.Note({ body: \(JXA.literal(Self.html(title: title, text: text))) }));
                return 'ok';
                """)
            if out == "ok" { return "Created the note “\(title)” in Notes." }
        default:
            throw ConversationError.unknownTool(call.name)
        }
        if out.hasPrefix("ERROR:") { return JXA.failure(out, app: "Notes") }
        return ToolOutput.wrap(out, source: "notes: \(call.name)")
    }

    /// Notes stores HTML and names a note after its first line: the title as a heading, then one line per paragraph.
    static func html(title: String, text: String) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(
                of: ">", with: "&gt;")
        }
        let lines = text.components(separatedBy: .newlines).map { $0.isEmpty ? "<div><br></div>" : "<div>\(escape($0))</div>" }
        return "<div><h1>\(escape(title))</h1></div>" + lines.joined()
    }
}

// Mail

/// `mail_draft`: an email opened in Mail as a draft for the user to read and send. Nothing is sent from here.
public struct MailDraftToolProvider: ToolProvider {
    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "mail_draft",
                description:
                    "Open a new email in the user's Mail as a draft: recipients, subject and text. The user reads and sends it themselves; it is never sent from here.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"to":{"type":"string","description":"Addresses, separated by commas"},"cc":{"type":"string"},"subject":{"type":"string"},"text":{"type":"string"}},"required":["subject","text"]}"#
            )
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        guard let subject = args.string("subject"), let text = args.string("text") else { return toolFailure(missing: "subject or text") }
        let split = { (key: String) in
            (args.string(key) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let recipients = (try? JSONEncoder().encode(split("to"))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let copies = (try? JSONEncoder().encode(split("cc"))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let out = try await JXA.run(
            """
            const M = Application('Mail');
            const m = M.OutgoingMessage({ subject: \(JXA.literal(subject)), content: \(JXA.literal(text)), visible: true });
            M.outgoingMessages.push(m);
            \(recipients).forEach(a => m.toRecipients.push(M.Recipient({ address: a })));
            \(copies).forEach(a => m.ccRecipients.push(M.CcRecipient({ address: a })));
            M.activate();
            return 'ok';
            """)
        if out.hasPrefix("ERROR:") { return JXA.failure(out, app: "Mail") }
        return "The draft “\(subject)” is open in Mail for the user to check and send; it has not been sent."
    }
}
