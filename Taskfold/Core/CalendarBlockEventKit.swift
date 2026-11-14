import Foundation
import EventKit

/// Full access is requested, not write-only: updating, deleting and de-duplicating events means reading them back,
/// and write-only access cannot read events. Only events in the chosen calendar that carry Taskfold's marker are read,
/// changed or removed. This file is identical in the iOS and Mac repositories.
actor SystemCalendarBlockStore: CalendarBlockStoring {
    private let store = EKEventStore()

    func access() -> CalendarBlockAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .full
        case .writeOnly: .writeOnly
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestFullAccess() async throws -> Bool {
        let granted = try await store.requestFullAccessToEvents()
        store.reset()
        return granted
    }

    private func writable() -> [EKCalendar] {
        guard access() == .full else { return [] }
        return store.calendars(for: .event).filter { $0.allowsContentModifications && !$0.isSubscribed && !$0.isImmutable }
    }

    func writableCalendars() -> [PlannerCalendar] {
        writable().map { PlannerCalendar(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title) }
            .sorted { ($0.source, $0.title, $0.id) < ($1.source, $1.title, $1.id) }
    }

    func resolveCalendar(preferredID: String?) throws -> PlannerCalendar {
        guard access() == .full else { throw CalendarBlockFailure.accessNeeded }
        func wrap(_ calendar: EKCalendar) -> PlannerCalendar { PlannerCalendar(id: calendar.calendarIdentifier, title: calendar.title, source: calendar.source.title) }
        if let preferredID {
            guard let calendar = writable().first(where: { $0.calendarIdentifier == preferredID }) else { throw CalendarBlockFailure.calendarUnavailable }
            return wrap(calendar)
        }
        let defaultSource = store.defaultCalendarForNewEvents?.source
        let named = writable().filter { $0.title == CalendarBlocks.calendarTitle }
            .sorted { ($0.source == defaultSource ? 0 : 1, $0.source.title, $0.calendarIdentifier) < ($1.source == defaultSource ? 0 : 1, $1.source.title, $1.calendarIdentifier) }
        if let existing = named.first { return wrap(existing) }
        // Prefer the default source; fall back to others that accept new calendars (iCloud, then On My Mac).
        var sources: [EKSource] = []
        if let defaultSource { sources.append(defaultSource) }
        sources += store.sources.filter { $0 != defaultSource && ($0.sourceType == .calDAV || $0.sourceType == .local) }
            .sorted { ($0.sourceType == .calDAV ? 0 : 1, $0.title) < ($1.sourceType == .calDAV ? 0 : 1, $1.title) }
        for source in sources {
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = CalendarBlocks.calendarTitle
            calendar.source = source
            do { try store.saveCalendar(calendar, commit: true); return wrap(calendar) } catch { store.reset() }
        }
        throw CalendarBlockFailure.cannotCreateCalendar
    }

    private func marked(_ calendar: EKCalendar, window: DateInterval) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: [calendar])
        return store.events(matching: predicate).filter { CalendarBlocks.isBlock(url: $0.url, notes: $0.notes) }
    }

    func markedEvents(calendarID: String, window: DateInterval) throws -> [CalendarBlocks.Event] {
        guard access() == .full else { throw CalendarBlockFailure.accessNeeded }
        guard let calendar = store.calendar(withIdentifier: calendarID) else { throw CalendarBlockFailure.calendarUnavailable }
        return marked(calendar, window: window).compactMap { event in
            guard let id = CalendarBlocks.taskID(url: event.url, notes: event.notes), let identifier = event.eventIdentifier else { return nil }
            return CalendarBlocks.Event(identifier: identifier, taskID: id, title: event.title ?? "", start: event.startDate, end: event.endDate, created: event.creationDate)
        }
    }

    private func fill(_ event: EKEvent, _ block: CalendarBlocks.Block) {
        event.title = block.title
        event.startDate = block.start
        event.endDate = block.end
        event.isAllDay = false
        // Notes hold only the marker; task notes are never copied. A planned block is information in the calendar,
        // not a commitment: free keeps it out of every busy-time reader, including other apps.
        event.notes = CalendarBlocks.marker(for: block.taskID)
        event.url = CalendarBlocks.markerURL(for: block.taskID)
        event.availability = .free
    }

    /// An event we may change: in the chosen calendar and carrying a marker.
    private func ours(_ identifier: String, in calendarID: String) -> EKEvent? {
        guard let event = store.event(withIdentifier: identifier), event.calendar.calendarIdentifier == calendarID,
              CalendarBlocks.isBlock(url: event.url, notes: event.notes) else { return nil }
        return event
    }

    func apply(_ plan: CalendarBlocks.Plan, calendarID: String) throws -> [String: String] {
        guard access() == .full else { throw CalendarBlockFailure.accessNeeded }
        guard let calendar = store.calendar(withIdentifier: calendarID), calendar.allowsContentModifications else { throw CalendarBlockFailure.calendarUnavailable }
        var created: [String: EKEvent] = [:]
        do {
            for block in plan.creates {
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                fill(event, block)
                try store.save(event, span: .thisEvent, commit: false)
                created[block.taskID] = event
            }
            for update in plan.updates {
                guard let event = ours(update.identifier, in: calendarID) else { continue }
                fill(event, update.block)
                try store.save(event, span: .thisEvent, commit: false)
            }
            for identifier in plan.deletes {
                guard let event = ours(identifier, in: calendarID) else { continue }
                try store.remove(event, span: .thisEvent, commit: false)
            }
            try store.commit()
        } catch {
            store.reset()
            throw CalendarBlockFailure.failed(error.localizedDescription)
        }
        return created.compactMapValues { $0.eventIdentifier }
    }

    func removeAll(calendarID: String) throws -> Int {
        guard access() == .full else { throw CalendarBlockFailure.accessNeeded }
        guard let calendar = store.calendar(withIdentifier: calendarID) else { throw CalendarBlockFailure.calendarUnavailable }
        // EventKit reads at most four years per query; blocks only ever live in a two-week window around now.
        let now = Date(), span = 86400.0 * 366
        var removed = 0
        do {
            for event in marked(calendar, window: DateInterval(start: now - span, end: now + span)) {
                try store.remove(event, span: .thisEvent, commit: false)
                removed += 1
            }
            try store.commit()
        } catch {
            store.reset()
            throw CalendarBlockFailure.failed(error.localizedDescription)
        }
        return removed
    }
}

/// Debug workspaces never touch the user's calendar or request OS permission.
struct EmptyCalendarBlockStore: CalendarBlockStoring {
    func access() async -> CalendarBlockAccess { .denied }
    func requestFullAccess() async throws -> Bool { false }
    func writableCalendars() async -> [PlannerCalendar] { [] }
    func resolveCalendar(preferredID: String?) async throws -> PlannerCalendar { throw CalendarBlockFailure.accessNeeded }
    func markedEvents(calendarID: String, window: DateInterval) async throws -> [CalendarBlocks.Event] { [] }
    func apply(_ plan: CalendarBlocks.Plan, calendarID: String) async throws -> [String: String] { [:] }
    func removeAll(calendarID: String) async throws -> Int { 0 }
}
