//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import EventKit
import Foundation
import UserNotifications

// Calendar and Reminders

/// The one event store of the app: EventKit asks for access once per kind, and a store keeps what it was given.
@MainActor
enum CalendarAccess {
    static let store = EKEventStore()

    /// Asks for both when the user turns the switch on, so macOS prompts then and never in the middle of an answer.
    static func request() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            _ = try? await store.requestFullAccessToReminders()
        }
    }

    /// Asked on every call without full access: macOS shows its question while it has none (a new build is a new app
    /// to it, write-only access asks to widen), and after a refusal its privacy pane opens instead.
    static func allowed(_ type: EKEntityType) async -> Bool {
        if EKEventStore.authorizationStatus(for: type) != .fullAccess {
            _ = try? await (type == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())
        }
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else {
            PrivacySettings.ask(type == .event ? .calendars : .reminders)
            return false
        }
        return true
    }
}

/// `calendar_events`, `calendar_add_event`, `reminders_list` and `reminders_add`: the user's Calendar and Reminders.
/// Reading is free; adding asks the user first.
public struct CalendarToolProvider: ToolProvider {
    public var confirmation: (any ToolConfirmation)?
    public init(confirmation: (any ToolConfirmation)?) { self.confirmation = confirmation }

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "calendar_events",
                description:
                    "Events in the user's calendars for a span of days: title, start, end, place, calendar. Dates are local, written 2026-09-22 or 2026-09-22 15:00.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"from":{"type":"string","description":"First day, default today"},"days":{"type":"integer","description":"How many days, 1 to 60 (default 1)"}}}"#
            ),
            ToolSpec(
                name: "calendar_add_event",
                description: "Add an event to the user's default calendar. The user approves it first.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"title":{"type":"string"},"start":{"type":"string","description":"Local date and time, e.g. 2026-09-26 15:00; a date alone makes an all-day event"},"minutes":{"type":"integer","description":"Length, default 60"},"location":{"type":"string"},"notes":{"type":"string"}},"required":["title","start"]}"#
            ),
            ToolSpec(
                name: "reminders_list",
                description: "The user's reminders that are not done yet, with their lists and due dates.",
                parametersJSONSchema: #"{"type":"object","properties":{"list":{"type":"string","description":"Only this list"}}}"#),
            ToolSpec(
                name: "reminders_add",
                description:
                    "Add a reminder to the user's default Reminders list, optionally due at a time (Reminders then alerts). The user approves it first.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"title":{"type":"string"},"due":{"type":"string","description":"Local date and time, e.g. 2026-09-22 18:00"},"notes":{"type":"string"}},"required":["title"]}"#
            ),
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        switch call.name {
        case "calendar_events":
            let from = args.string("from").flatMap(ToolDate.parse) ?? .now
            let days = min(max(args.int("days") ?? args.string("days").flatMap { Int($0) } ?? 1, 1), 60)
            return await Self.events(from: from, days: days)
        case "calendar_add_event":
            guard let title = args.string("title"), !title.isEmpty else { return toolFailure(missing: "title") }
            guard let text = args.string("start"), let start = ToolDate.parse(text) else {
                return "error: start must be a local date and time such as 2026-09-26 15:00"
            }
            let allDay = !text.contains(":")
            let minutes = max(args.int("minutes") ?? args.string("minutes").flatMap { Int($0) } ?? 60, 5)
            let place = args.string("location").flatMap { $0.isEmpty ? nil : $0 }
            if let confirmation {
                let detail = [ToolDate.forUser(start, allDay: allDay), place].compactMap { $0 }.joined(separator: "\n")
                guard await confirmation.confirm(title: String(localized: "Add “\(title)” to Calendar?"), detail: detail) else {
                    return "error: the user declined to add the event"
                }
            } else {
                return "error: adding events needs the user's approval, which is not available here"
            }
            return await Self.addEvent(
                title: title, start: start, minutes: minutes, allDay: allDay, place: place, notes: args.string("notes"))
        case "reminders_list":
            return await Self.reminders(list: args.string("list"))
        case "reminders_add":
            guard let title = args.string("title"), !title.isEmpty else { return toolFailure(missing: "title") }
            let due = args.string("due").flatMap(ToolDate.parse)
            if args.string("due").map({ !$0.isEmpty }) == true, due == nil {
                return "error: due must be a local date and time such as 2026-09-22 18:00"
            }
            guard let confirmation else { return "error: adding reminders needs the user's approval, which is not available here" }
            let detail = due.map { ToolDate.forUser($0) } ?? String(localized: "No due date")
            guard await confirmation.confirm(title: String(localized: "Add reminder “\(title)”?"), detail: detail) else {
                return "error: the user declined to add the reminder"
            }
            return await Self.addReminder(title: title, due: due, notes: args.string("notes"))
        default:
            throw ConversationError.unknownTool(call.name)
        }
    }

    // EventKit, on the main actor with the one store

    private static let noCalendar =
        "error: Mac-Olama may not read the calendar. A notification now asks the user to allow Mac-Olama in System Settings → Privacy & Security → Calendars; ask again once they have."
    private static let noReminders =
        "error: Mac-Olama may not read reminders. A notification now asks the user to allow Mac-Olama in System Settings → Privacy & Security → Reminders; ask again once they have."

    @MainActor
    private static func events(from: Date, days: Int) async -> String {
        guard await CalendarAccess.allowed(.event) else { return noCalendar }
        let start = Calendar.current.startOfDay(for: from)
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return "error: bad date" }
        let store = CalendarAccess.store
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }.prefix(100)
        var lines = [ToolDate.now, "Events from \(ToolDate.string(start, time: false)) for \(days) day(s):"]
        if found.isEmpty { lines.append("No events.") }
        for event in found {
            var line =
                event.isAllDay
                ? "\(ToolDate.string(event.startDate, time: false)), all day: \(event.title ?? "")"
                : "\(ToolDate.string(event.startDate))–\(ToolDate.string(event.endDate).prefix(16).suffix(5)): \(event.title ?? "")"
            if let place = event.location, !place.isEmpty { line += " @ \(place)" }
            line += " [\(event.calendar.title)]"
            lines.append("- " + line)
        }
        return ToolOutput.wrap(lines.joined(separator: "\n"), source: "calendar_events")
    }

    @MainActor
    private static func addEvent(title: String, start: Date, minutes: Int, allDay: Bool, place: String?, notes: String?) async -> String {
        guard await CalendarAccess.allowed(.event) else { return noCalendar }
        let store = CalendarAccess.store
        guard let calendar = store.defaultCalendarForNewEvents else { return "error: the user has no calendar to add to" }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.isAllDay = allDay
        event.startDate = allDay ? Calendar.current.startOfDay(for: start) : start
        event.endDate = allDay ? event.startDate.addingTimeInterval(86_400) : start.addingTimeInterval(Double(minutes) * 60)
        event.location = place
        event.notes = notes
        do {
            try store.save(event, span: .thisEvent)
            return "Added “\(title)” on \(ToolDate.string(event.startDate, time: !allDay)) to the calendar \(calendar.title)."
        } catch {
            return "error: the calendar did not save it (\(error.localizedDescription))"
        }
    }

    private struct ReminderLine: Sendable {
        var title: String
        var list: String
        var due: Date?
    }

    @MainActor
    private static func reminders(list: String?) async -> String {
        guard await CalendarAccess.allowed(.reminder) else { return noReminders }
        let store = CalendarAccess.store
        var calendars = store.calendars(for: .reminder)
        if let list, !list.isEmpty {
            calendars = calendars.filter { $0.title.localizedCaseInsensitiveContains(list) }
            guard !calendars.isEmpty else { return "error: no Reminders list called \"\(list)\"" }
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        // Handed over as plain values: EventKit calls back on its own queue, and its objects stay there.
        let found: [ReminderLine] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let lines = (reminders ?? []).map { reminder in
                    ReminderLine(
                        title: reminder.title ?? "", list: reminder.calendar.title,
                        due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
                }
                continuation.resume(returning: lines)
            }
        }
        var lines = [ToolDate.now, "Reminders not done yet:"]
        if found.isEmpty { lines.append("None.") }
        let sorted = found.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(100)
        lines += sorted.map { "- \($0.title) [\($0.list)]" + ($0.due.map { ", due " + ToolDate.string($0) } ?? "") }
        return ToolOutput.wrap(lines.joined(separator: "\n"), source: "reminders_list")
    }

    @MainActor
    private static func addReminder(title: String, due: Date?, notes: String?) async -> String {
        guard await CalendarAccess.allowed(.reminder) else { return noReminders }
        let store = CalendarAccess.store
        guard let list = store.defaultCalendarForNewReminders() else { return "error: the user has no Reminders list to add to" }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = title
        reminder.notes = notes
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
            return "Added the reminder “\(title)” to \(list.title)" + (due.map { ", due \(ToolDate.string($0))." } ?? ".")
        } catch {
            return "error: Reminders did not save it (\(error.localizedDescription))"
        }
    }
}

// Timers

/// `set_timer`, `list_timers` and `cancel_timer`: "remind me in 20 minutes" as a notification macOS delivers at the
/// time, even with the chat closed. Only the app's own timers are listed or cancelled, never other notifications.
public struct TimerToolProvider: ToolProvider {
    private static let prefix = "timer-"

    public init() {}

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "set_timer",
                description:
                    "Remind the user with a notification after some minutes or at a local time. For \"remind me in 20 minutes\" or \"at 18:30\".",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"message":{"type":"string","description":"What the notification says"},"minutes":{"type":"number","description":"In how many minutes"},"at":{"type":"string","description":"Or a local date and time, e.g. 2026-09-22 18:30"}},"required":["message"]}"#
            ),
            ToolSpec(
                name: "list_timers", description: "Timers set earlier that have not gone off yet, with their times and numbers.",
                parametersJSONSchema: #"{"type":"object","properties":{}}"#),
            ToolSpec(
                name: "cancel_timer", description: "Cancel a timer by its number from list_timers.",
                parametersJSONSchema: #"{"type":"object","properties":{"number":{"type":"integer"}},"required":["number"]}"#),
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        let center = UNUserNotificationCenter.current()
        switch call.name {
        case "set_timer":
            guard let message = args.string("message"), !message.isEmpty else { return toolFailure(missing: "message") }
            let fire: Date
            if let at = args.string("at"), !at.isEmpty {
                guard let date = ToolDate.parse(at) else { return "error: at must be a local date and time such as 2026-09-22 18:30" }
                fire = date
            } else if let minutes = args.double("minutes") {
                fire = Date.now.addingTimeInterval(minutes * 60)
            } else {
                return "error: give minutes or a time"
            }
            guard fire.timeIntervalSinceNow >= 1 else { return "error: that time has already passed; \(ToolDate.now)" }
            guard await NotificationService.shared.ensureAllowed() else {
                return
                    "error: Mac-Olama may not show notifications. System Settings → Notifications is now open: tell the user to allow Mac-Olama there and ask again."
            }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Reminder")
            content.body = message
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: Self.prefix + UUID().uuidString, content: content, trigger: trigger))
                return "The timer is set for \(ToolDate.string(fire)): “\(message)”. \(ToolDate.now)."
            } catch {
                return "error: the notification could not be scheduled (\(error.localizedDescription))"
            }
        case "list_timers":
            let timers = await Self.pending(center)
            guard !timers.isEmpty else { return "No timers are set." }
            let lines = timers.enumerated().map { "\($0.offset + 1). \(ToolDate.string($0.element.fire)): \($0.element.message)" }
            return ([ToolDate.now, "Timers not gone off yet:"] + lines).joined(separator: "\n")
        case "cancel_timer":
            guard let number = args.int("number") ?? args.string("number").flatMap({ Int($0) }) else {
                return toolFailure(missing: "number")
            }
            let timers = await Self.pending(center)
            guard timers.indices.contains(number - 1) else { return "error: there is no timer \(number); call list_timers" }
            let timer = timers[number - 1]
            center.removePendingNotificationRequests(withIdentifiers: [timer.id])
            return "Cancelled the timer for \(ToolDate.string(timer.fire)): “\(timer.message)”."
        default:
            throw ConversationError.unknownTool(call.name)
        }
    }

    private struct Timer {
        var id: String
        var fire: Date
        var message: String
    }

    /// The app's own timers, soonest first, so a number from list_timers still means the same one when cancelling.
    private static func pending(_ center: UNUserNotificationCenter) async -> [Timer] {
        await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(prefix) }
            .compactMap { request in
                guard let fire = (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() else { return nil }
                return Timer(id: request.identifier, fire: fire, message: request.content.body)
            }
            .sorted { $0.fire < $1.fire }
    }
}
