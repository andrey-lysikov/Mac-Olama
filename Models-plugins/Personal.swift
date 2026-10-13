//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import Contacts
import Foundation

// The user's own records: contacts, notes and mail. Mail is read, never changed; an outgoing email is only ever a
// draft the user sends themselves.

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

/// What the Notes and Mail scripts search with. A query is words, not a phrase: each is cut to a stem, so «Левшину»
/// finds «Левшина», and a text counts by how many of them it has. Both sides are compared in Latin letters, so the
/// same «Левшина» finds the sender "Levshina, Anna".
private let searchPrelude = #"""
    const LATIN = { а: 'a', б: 'b', в: 'v', г: 'g', д: 'd', е: 'e', ж: 'zh', з: 'z', и: 'i', й: 'y', к: 'k', л: 'l', м: 'm', н: 'n',
      о: 'o', п: 'p', р: 'r', с: 's', т: 't', у: 'u', ф: 'f', х: 'kh', ц: 'ts', ч: 'ch', ш: 'sh', щ: 'shch', ъ: '', ы: 'y', ь: '',
      э: 'e', ю: 'yu', я: 'ya' };
    function plain(s) { return (s || '').toLowerCase().replace(/ё/g, 'е'); }
    function latin(s) { return s.replace(/[а-я]/g, c => LATIN[c]); }
    function fold(s) { return latin(plain(s)); }
    function cut(q) {
      const words = plain(q).split(/[^\p{L}\p{N}]+/u).filter(w => w.length > 1);
      const long = words.filter(w => w.length > 2);
      return (long.length ? long : words).map(w => w.length >= 7 ? w.slice(0, -2) : w.length >= 5 ? w.slice(0, -1) : w);
    }
    function stems(q) { return cut(q).map(latin); }
    function stamp(d) {
      if (!d) return '';
      const p = n => String(n).padStart(2, '0');
      return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
    }
    """#

/// `notes_search`, `notes_read` and `notes_create`: the Notes app through Apple Events.
public struct NotesToolProvider: ToolProvider {
    public var maxCharacters = 8000

    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "notes_search",
                description:
                    "Find the user's notes in Notes by words in the title or text, in any form of the word and in Russian or Latin letters: title, folder, date changed and the passage with the words. A few key words find more than a sentence.",
                parametersJSONSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#),
            ToolSpec(
                name: "notes_read", description: "Read one note from Notes in full, by its title.",
                parametersJSONSchema: #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#),
            ToolSpec(
                name: "notes_create", description: "Create a note in Notes.",
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
            // Every title and text in two Apple Events, matched here: Notes' own `whose` knows only the exact phrase.
            out = try await JXA.run(
                prelude: searchPrelude,
                """
                const N = Application('Notes');
                const words = cut(\(JXA.literal(query))), want = words.map(latin);
                if (!want.length) return 'NONE';
                const names = N.notes.name(), texts = N.notes.plaintext();
                const hits = [];
                for (let i = 0; i < names.length; i++) {
                  const name = fold(names[i]), text = fold(texts[i]);
                  const inName = want.filter(s => name.includes(s)).length;
                  const score = want.filter(s => name.includes(s) || text.includes(s)).length;
                  if (!score) continue;
                  const found = words.map(s => plain(texts[i]).indexOf(s)).filter(p => p >= 0);
                  hits.push({ i, score: score * 2 + inName, at: found.length ? Math.min(...found) : 0 });
                }
                hits.sort((a, b) => b.score - a.score);
                return hits.slice(0, 10).map(h => {
                  const n = N.notes[h.i], from = Math.max(0, h.at - 80);
                  return '- ' + names[h.i] + ' [' + n.container().name() + '], changed ' + n.modificationDate().toISOString().slice(0, 10)
                    + '\\n  ' + (from ? '…' : '') + (texts[h.i] || '').slice(from, from + 300).replace(/\\s+/g, ' ');
                }).join('\\n') || 'NONE';
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

/// `mail_search`, `mail_read`, `mail_attachment` and `mail_draft`: the Mail app through Apple Events. Messages are read and never changed;
/// an email is opened as a draft for the user to read and send, and nothing is sent from here.
public struct MailToolProvider: ToolProvider {
    public var maxCharacters = 8000
    public var maxAttachmentCharacters = 20_000
    public var maxAttachmentBytes = 30_000_000
    public var limit = 15

    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "mail_search",
                description:
                    "List the user's emails in Mail, newest first: id, date, who it is from (or to), subject. `query` is words from the subject or the sender's name or address, in any form of the word; a name written in Russian also finds its Latin spelling. The text of an email is not searched. Without a query it lists the latest emails.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"query":{"type":"string"},"mailbox":{"type":"string","enum":["inbox","sent"],"description":"inbox by default"},"days":{"type":"integer","description":"Only emails of the last N days"},"unread":{"type":"boolean","description":"Only unread emails"}}}"#
            ),
            ToolSpec(
                name: "mail_read",
                description:
                    "Read one email from Mail in full, by the id mail_search gave. It names the files attached; mail_attachment reads one.",
                parametersJSONSchema: #"{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}"#),
            ToolSpec(
                name: "mail_attachment",
                description:
                    "Read the text of a file attached to an email: PDF, Word, Excel, PowerPoint, text, or a picture or scan, whose text is recognized. `id` is the email's id, `name` the file's name from mail_read.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"id":{"type":"integer"},"name":{"type":"string","description":"File name from mail_read; may be left out when the email has one file"}},"required":["id"]}"#
            ),
            ToolSpec(
                name: "mail_draft",
                description:
                    "Open a new email in the user's Mail as a draft: recipients, subject and text. The user reads and sends it themselves; it is never sent from here.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"to":{"type":"string","description":"Addresses, separated by commas"},"cc":{"type":"string"},"subject":{"type":"string"},"text":{"type":"string"}},"required":["subject","text"]}"#
            ),
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        switch call.name {
        case "mail_search": return try await search(args)
        case "mail_read": return try await read(args)
        case "mail_attachment": return try await attachment(args)
        case "mail_draft": return try await draft(args)
        default: throw ConversationError.unknownTool(call.name)
        }
    }

    private func search(_ args: ToolArguments) async throws -> String {
        let query = args.string("query")?.trimmingCharacters(in: .whitespaces) ?? ""
        let sent = args.string("mailbox") == "sent"
        let days = args.double("days").map { max(1, Int($0)) }
        // A whole mailbox, tens of thousands of emails, comes in one Apple Event per property and is matched here;
        // Mail's own `whose` takes half a minute on the same mailbox.
        let out = try await JXA.run(
            prelude: searchPrelude,
            """
            const M = Application('Mail');
            const sent = \(sent), limit = \(limit);
            const box = (sent ? M.sentMailbox : M.inbox).messages;
            let ids;
            try { ids = box.id(); } catch (e) { if (e.errorNumber !== -1728) throw e; ids = []; }
            if (!ids.length) return 'NONE';
            const subjects = box.subject(), senders = box.sender(), read = box.readStatus();
            const dates = sent ? box.dateSent() : box.dateReceived();
            const want = stems(\(JXA.literal(query)));
            const since = \(days.map { "Date.now() - \($0) * 864e5" } ?? "0"), unreadOnly = \(args.bool("unread") ?? false);
            const hits = [];
            for (let i = 0; i < ids.length; i++) {
              if ((since && !(dates[i] >= since)) || (unreadOnly && read[i])) continue;
              const text = fold(subjects[i]) + ' ' + fold(senders[i]);
              const score = want.filter(s => text.includes(s)).length;
              if (score || !want.length) hits.push({ i, score });
            }
            if (!hits.length) return 'NONE';
            hits.sort((a, b) => b.score - a.score || dates[b.i] - dates[a.i]);
            const lines = hits.slice(0, limit).map(h => {
              const who = sent ? 'to: ' + box.byId(ids[h.i]).toRecipients.address().join(', ') : 'from: ' + senders[h.i];
              return '- id ' + ids[h.i] + ', ' + stamp(dates[h.i]) + (sent || read[h.i] ? '' : ', unread')
                + '\\n  ' + who + '\\n  subject: ' + subjects[h.i];
            });
            if (hits.length > limit) lines.push('…and ' + (hits.length - limit) + ' more: narrow the query or the days');
            return lines.join('\\n');
            """, timeout: 60)
        if out.hasPrefix("ERROR:") { return JXA.failure(out, app: "Mail") }
        if out == "NONE" {
            return query.isEmpty
                ? "No such email in Mail." : "No email in Mail has \"\(query)\" in its subject or sender; the text of emails is not searched."
        }
        return ToolOutput.wrap(out, source: "mail: mail_search")
    }

    private func read(_ args: ToolArguments) async throws -> String {
        guard let id = Self.id(args) else { return toolFailure(missing: "id") }
        // The text of a long email with attachments takes Mail several seconds.
        let out = try await JXA.run(
            prelude: searchPrelude,
            """
            \(Self.find(id))
            let files = [];
            try { files = m.mailAttachments.name(); } catch (e) {}
            return 'Subject: ' + m.subject() + '\\nFrom: ' + m.sender() + '\\nTo: ' + m.toRecipients.address().join(', ')
              + '\\nDate: ' + stamp(m.dateReceived() || m.dateSent()) + (files.length ? '\\nAttachments: ' + files.join(', ') : '')
              + '\\n\\n' + (m.content() || '');
            """, timeout: 90)
        if out.hasPrefix("ERROR:") { return JXA.failure(out, app: "Mail") }
        if out == "NONE" { return "error: no email has the id \(id); take one from mail_search" }
        return ToolOutput.wrap(out.clipped(to: maxCharacters), source: "mail: mail_read")
    }

    /// The id comes back as the model copied it: a number, or the same in quotes.
    private static func id(_ args: ToolArguments) -> Int? {
        args.int("id") ?? args.string("id").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The opening of a script about one email: `m` is the message with this id, looked for in the inbox and in Sent.
    private static func find(_ id: Int) -> String {
        """
        const M = Application('Mail');
        let m = null;
        for (const box of [M.inbox, M.sentMailbox]) {
          try { const found = box.messages.byId(\(id)); found.subject(); m = found; break; }
          catch (e) { if (e.errorNumber !== -1728) throw e; }
        }
        if (!m) return 'NONE';
        """
    }

    /// Mail hands a file over only by saving it, so it is saved to a folder of our own, read and removed.
    private func attachment(_ args: ToolArguments) async throws -> String {
        guard let id = Self.id(args) else { return toolFailure(missing: "id") }
        let wanted = args.string("name")?.trimmingCharacters(in: .whitespaces) ?? ""
        // Mail is sandboxed and may refuse a folder it was not given; Downloads it may always write to.
        let folders = [
            FileManager.default.temporaryDirectory,
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
        ].compactMap { $0?.appendingPathComponent(".mac-olama-mail-" + UUID().uuidString) }
        defer { folders.forEach { try? FileManager.default.removeItem(at: $0) } }
        var refusal = ""
        for folder in folders {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let out = try await JXA.run(
                """
                \(Self.find(id))
                const files = m.mailAttachments(), names = files.map(f => f.name());
                if (!files.length) return 'NOFILES';
                const want = \(JXA.literal(wanted)).toLowerCase();
                let i = want ? names.findIndex(n => n.toLowerCase() === want) : (files.length === 1 ? 0 : -1);
                if (i < 0 && want) i = names.findIndex(n => n.toLowerCase().includes(want));
                if (i < 0) return 'WHICH:' + names.join(', ');
                if (files[i].fileSize() > \(maxAttachmentBytes)) return 'LARGE:' + names[i];
                const safe = names[i].replace(/[\\/:]/g, '_');
                M.save(files[i], { in: Path(\(JXA.literal(folder.path)) + '/' + safe) });
                return 'SAVED:' + safe;
                """, timeout: 90)
            if out == "NONE" { return "error: no email has the id \(id); take one from mail_search" }
            if out == "NOFILES" { return "The email \(id) has no files attached." }
            if out.hasPrefix("WHICH:") {
                return "error: name the file to read; the email has: \(out.dropFirst("WHICH:".count))"
            }
            if out.hasPrefix("LARGE:") { return "error: \(out.dropFirst("LARGE:".count)) is too large to read here" }
            if out.contains("-1743") { return JXA.failure(out, app: "Mail") }
            let file = folder.appendingPathComponent(String(out.dropFirst("SAVED:".count)))
            guard out.hasPrefix("SAVED:"), FileManager.default.fileExists(atPath: file.path) else {
                refusal = out
                continue
            }
            guard let text = try await AttachmentText.read(file, maxCharacters: maxAttachmentCharacters) else {
                return "error: \(file.lastPathComponent) is not a kind of file whose text can be read here"
            }
            if text.isEmpty { return "No text was found in \(file.lastPathComponent)." }
            return ToolOutput.wrap(text.clipped(to: maxAttachmentCharacters), source: "mail: \(file.lastPathComponent)")
        }
        return refusal.hasPrefix("ERROR:") ? JXA.failure(refusal, app: "Mail") : "error: Mail did not hand the file over"
    }

    private func draft(_ args: ToolArguments) async throws -> String {
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

/// The text of a file that came by mail, whatever it is: a document's own text, a spreadsheet's cells, a
/// presentation's slides, or what is recognized in a picture or a scan. nil for a kind that has no text to read.
enum AttachmentText {
    static func read(_ url: URL, maxCharacters: Int) async throws -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "xlsx", "xlsm": return try await spreadsheet(url)
        case "pptx": return try await slides(url)
        case "doc", "docx", "odt", "rtfd", "webarchive", "html", "htm":
            // The HTML reader is WebKit's and wants the main thread; the rest go the same way for one path.
            return await MainActor.run { (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string }
        default: break
        }
        switch DocumentExtractor.extract(url: url) {
        case .document(let document): return document.text
        // A picture, or a PDF with no text layer (a scan): the text is recognized.
        case .image: return try await recognized(url)
        case nil: return ext == "pdf" ? try await recognized(url) : nil
        }
    }

    private static func recognized(_ url: URL) async throws -> String {
        var configuration = FileToolProvider.Configuration(allowedFolders: [])
        configuration.maxFileCharacters = .max
        let out = try await FileToolProvider(configuration: configuration).recognizeText(url)
        // It answers as a tool does: the text between the untrusted-content lines, or a plain line when there is none.
        let lines = out.components(separatedBy: "\n")
        guard lines.first?.hasPrefix("<untrusted_content") == true, let end = lines.lastIndex(of: "</untrusted_content>") else { return "" }
        return lines[1..<end].joined(separator: "\n")
    }

    /// One file, or the files matching a pattern, out of an Office document, which is a zip of XML.
    private static func unzip(_ url: URL, _ member: String) async throws -> String {
        try await ToolProcess.run("/usr/bin/unzip", ["-p", url.path, member], timeout: 30)
    }

    /// Rows of every sheet, cells separated by tabs. Text cells point into the shared strings; numbers stand in place.
    private static func spreadsheet(_ url: URL) async throws -> String {
        let shared = try await unzip(url, "xl/sharedStrings.xml").matches(of: /<si>(.*?)<\/si>/.dotMatchesNewlines()).map {
            String($0.1).matches(of: /<t[^>]*>(.*?)<\/t>/.dotMatchesNewlines()).map { String($0.1) }.joined().xmlUnescaped
        }
        let sheets = try await unzip(url, "xl/worksheets/sheet*.xml")
        var rows: [String] = []
        for row in sheets.matches(of: /<row[^>]*>(.*?)<\/row>/.dotMatchesNewlines()) {
            let cells = String(row.1).matches(of: /<c([^>]*?)(?:\/>|>(.*?)<\/c>)/.dotMatchesNewlines()).map { cell -> String in
                let body = String(cell.2 ?? "")
                if cell.1.contains("t=\"inlineStr\"") {
                    return body.matches(of: /<t[^>]*>(.*?)<\/t>/.dotMatchesNewlines()).map { String($0.1) }.joined().xmlUnescaped
                }
                guard let value = body.firstMatch(of: /<v>(.*?)<\/v>/.dotMatchesNewlines()).map({ String($0.1) }) else { return "" }
                if cell.1.contains("t=\"s\""), let index = Int(value), shared.indices.contains(index) { return shared[index] }
                return value.xmlUnescaped
            }
            if cells.contains(where: { !$0.isEmpty }) { rows.append(cells.joined(separator: "\t")) }
        }
        return rows.joined(separator: "\n")
    }

    /// The text of every slide, a paragraph to a line.
    private static func slides(_ url: URL) async throws -> String {
        try await unzip(url, "ppt/slides/slide*.xml").matches(of: /<a:p>(.*?)<\/a:p>/.dotMatchesNewlines()).map {
            String($0.1).matches(of: /<a:t>(.*?)<\/a:t>/.dotMatchesNewlines()).map { String($0.1) }.joined().xmlUnescaped
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension String {
    /// The five entities XML itself has; Office writes no others into its text.
    fileprivate var xmlUnescaped: String {
        replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}
