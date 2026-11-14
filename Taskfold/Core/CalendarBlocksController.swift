import Foundation
import Observation

/// Settings and sync state for "Show time blocks in Calendar". Off by default; the choice, the chosen calendar and the
/// task-to-event mapping live on this device only (calendar identifiers are device-specific).
/// This file is identical in the iOS and Mac repositories.
@MainActor @Observable final class CalendarBlocksController {
    static let shared: CalendarBlocksController = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") || ProcessInfo.processInfo.arguments.contains("--preview") { return CalendarBlocksController(store: EmptyCalendarBlockStore()) }
        #endif
        return CalendarBlocksController(store: SystemCalendarBlockStore())
    }()

    private let store: any CalendarBlockStoring
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var running = false
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var lastTasks: [Record] = []

    private(set) var account = ""
    private(set) var enabled = false
    private(set) var calendars: [PlannerCalendar] = []
    /// The calendar chosen by the user; nil means the calendar named "Taskfold".
    private(set) var chosenCalendarID: String?
    private(set) var calendarName = CalendarBlocks.calendarTitle
    private(set) var status = ""
    private(set) var busy = false
    private(set) var lastSynced: Date?
    private(set) var revision = 0

    init(store: any CalendarBlockStoring, defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults
    }

    private static let enabledKey = "calendarBlocks.enabled", ownerKey = "calendarBlocks.owner",
                               calendarKey = "calendarBlocks.calendar", mappingKey = "calendarBlocks.mapping"
    private var mapping: [String: String] {
        get { (defaults.dictionary(forKey: Self.mappingKey) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.mappingKey) }
    }
    /// Syncing runs only for the account that switched it on, so a second account never deletes the first one's blocks.
    var active: Bool { enabled && !account.isEmpty }

    func bind(account: String) {
        guard self.account != account else { return }
        self.account = account
        let owner = defaults.string(forKey: Self.ownerKey) ?? ""
        enabled = defaults.bool(forKey: Self.enabledKey) && !account.isEmpty && owner == account
        chosenCalendarID = defaults.string(forKey: Self.calendarKey)
        status = enabled ? "" : (defaults.bool(forKey: Self.enabledKey) && !owner.isEmpty && owner != account ? "Time blocks are on for another account on this device. Switching on here takes them over." : "")
        revision += 1
    }

    // MARK: Switching on and off

    /// Asks for calendar access only now, when the user switches the feature on.
    func enable() async {
        guard !account.isEmpty else { return }
        let token = account
        do {
            guard try await store.requestFullAccess() else {
                status = "Calendar access was not granted. Time blocks need full calendar access, because Taskfold reads back its own events to update and remove them. Allow it in system settings, then try again."
                revision += 1; return
            }
            guard token == account else { return }
            if defaults.string(forKey: Self.ownerKey) != account { mapping = [:] }
            defaults.set(account, forKey: Self.ownerKey); defaults.set(true, forKey: Self.enabledKey)
            enabled = true; status = ""; revision += 1
            await refreshCalendars()
            await sync(tasks: lastTasks)
        } catch {
            status = "Could not turn on time blocks: " + error.localizedDescription; revision += 1
        }
    }

    /// Stops syncing. When `removeEvents`, also deletes every Taskfold event from the calendar.
    func disable(removeEvents: Bool) async {
        let id = await currentCalendarID(create: false)
        enabled = false
        defaults.set(false, forKey: Self.enabledKey); defaults.removeObject(forKey: Self.ownerKey); mapping = [:]
        status = ""; revision += 1
        guard removeEvents else { status = "Time blocks stay in your calendar until you delete them there."; return }
        guard let id else { return }
        do {
            let removed = try await store.removeAll(calendarID: id)
            status = removed == 0 ? "" : "Removed \(removed) time block\(removed == 1 ? "" : "s") from Calendar."
        } catch let failure as CalendarBlockFailure { status = failure.message } catch { status = "Could not remove time blocks: " + error.localizedDescription }
        revision += 1
    }

    /// Removing the account takes its blocks with it, best effort.
    func eraseAccount(_ erased: String) async {
        guard defaults.string(forKey: Self.ownerKey) == erased else { return }
        await disable(removeEvents: true)
    }

    // MARK: Calendar choice

    func refreshCalendars() async {
        calendars = await store.writableCalendars()
        if let chosenCalendarID, let match = calendars.first(where: { $0.id == chosenCalendarID }) { calendarName = match.title }
        else if chosenCalendarID == nil { calendarName = CalendarBlocks.calendarTitle }
        revision += 1
    }

    /// `nil` goes back to the calendar named "Taskfold". Blocks already written to the old calendar are removed first.
    func chooseCalendar(_ id: String?) async {
        guard id != chosenCalendarID else { return }
        let previous = await currentCalendarID(create: false)
        if let previous { _ = try? await store.removeAll(calendarID: previous) }
        chosenCalendarID = id; mapping = [:]
        if let id { defaults.set(id, forKey: Self.calendarKey) } else { defaults.removeObject(forKey: Self.calendarKey) }
        await refreshCalendars()
        await sync(tasks: lastTasks)
    }

    private func currentCalendarID(create: Bool) async -> String? {
        guard await store.access() == .full else { return nil }
        if let chosenCalendarID { return (try? await store.resolveCalendar(preferredID: chosenCalendarID))?.id }
        if !create {
            return await store.writableCalendars().first { $0.title == CalendarBlocks.calendarTitle }?.id
        }
        return (try? await store.resolveCalendar(preferredID: nil))?.id
    }

    // MARK: Sync

    /// Mirror `tasks` into the calendar. Calls made while a sync runs collapse into one follow-up pass.
    func sync(tasks: [Record], now: Date = Date(), calendar: Calendar = .current) async {
        lastTasks = tasks
        guard active else { return }
        guard !running else { rerun = true; return }
        running = true; busy = true; revision += 1
        defer { running = false; busy = false; revision += 1 }
        repeat {
            rerun = false
            let owner = account
            do {
                switch await store.access() {
                case .full: break
                case .writeOnly, .denied, .notDetermined:
                    status = CalendarBlockFailure.accessNeeded.message; return
                }
                let resolved = try await store.resolveCalendar(preferredID: chosenCalendarID)
                guard active, owner == account else { return }
                calendarName = resolved.title
                let outcome = try await CalendarBlockSync.run(tasks: lastTasks, store: store, calendarID: resolved.id, mapping: mapping, now: now, calendar: calendar)
                guard active, owner == account else { return }
                mapping = outcome.mapping
                lastSynced = now; status = ""
            } catch let failure as CalendarBlockFailure { status = failure.message; return } catch { status = "Calendar update failed: " + error.localizedDescription; return }
        } while rerun
    }
}
