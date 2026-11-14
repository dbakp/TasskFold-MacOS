import Foundation

/// The facts shown on the Privacy screen, written once so both apps say exactly the same thing.
/// Each statement is tied to how the code behaves today; keep it plain, and do not claim more than the code does.
/// This file is identical in the iOS and Mac repositories.
enum PrivacyFacts {
    /// Where the data in an item lives.
    enum Location: String, CaseIterable, Sendable {
        case onDevice, syncs, otherServices, none

        var label: String {
            switch self {
            case .onDevice: "On device"
            case .syncs: "Syncs to TaskFold"
            case .otherServices: "Other services"
            case .none: "Not collected"
            }
        }
        var symbol: String {
            switch self {
            case .onDevice: "lock.fill"
            case .syncs: "icloud"
            case .otherServices: "network"
            case .none: "eye.slash"
            }
        }
    }

    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let location: Location
        let summary: String
        let points: [String]
        /// Read aloud as one element, so VoiceOver users hear the placement first.
        var accessibilityLabel: String { ([title + ". " + location.label + ".", summary] + points).joined(separator: " ") }
    }

    struct Control: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
    }

    static let screenIdentifier = "privacyScreen"
    static let badgeIdentifier = "onDeviceBadge"
    static let title = "Privacy"
    static var intro: String { "Suggestions run on \(deviceNoun). Your tasks leave it only if you sign in to sync." }
    /// "this iPhone", "this iPad" or "this Mac", so the page names the device the person is holding.
    static var deviceNoun: String {
        #if os(macOS)
        return "this Mac"
        #else
        var size = 0; sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: max(size, 1)); sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? String(cString: machine)
        return id.hasPrefix("iPhone") ? "this iPhone" : id.hasPrefix("iPad") ? "this iPad" : "this device"
        #endif
    }
    static let badgeLabel = "On-device"
    static let badgeAccessibilityLabel = "On-device. Nothing leaves this device."
    static let footer = "This summary describes how the app is built. It is not legal advice or a contract; the TaskFold privacy policy governs."

    static let items: [Item] = [
        Item(id: "ai", title: "AI suggestions", location: .onDevice,
             summary: "Brain dump, Suggest steps, Smart reschedule, day notes and Suggest a filter use the language model built into your device’s operating system (Apple Intelligence).",
             points: [
                "Your text never leaves \(deviceNoun) for AI.",
                "When Apple Intelligence isn’t available, Brain dump, Smart reschedule and filter suggestions fall back to simple rules on this device, and Suggest steps tells you it is unavailable.",
                "Suggestions are drafts. Tasks you accept are saved like any task you type, so in a cloud workspace they sync as described below.",
             ]),
        Item(id: "sync", title: "Your cloud workspace", location: .syncs,
             summary: "When you sign in, your workspace is stored on TaskFold’s server (hosted on Supabase) so it can sync across your devices.",
             points: [
                "Synced: tasks, projects, sections, labels, saved views and favorites, view order and preferences, This Evening and Someday planning, habits, reminder preferences, project templates, focus sessions, and your profile name and photo.",
                "In shared projects, comments and mentions are stored there too and are visible to the people in that project.",
                "Only if you choose them: files attached to tasks, voice comments you publish, and remote reminders, which register this device with TaskFold.",
                "Sync runs only while you are signed in to an account.",
             ]),
        Item(id: "local", title: "Local mode", location: .onDevice,
             summary: "Local mode keeps your workspace in a file on this device, without an account.",
             points: [
                "In local mode no sync runs, so your tasks are not uploaded.",
                "Signing in later does not upload your local tasks automatically.",
                "Features that need an account, such as project collaboration, are unavailable.",
                "Local mode doesn’t switch off optional features that contact other services directly, such as link titles, holiday calendars or a calendar you connect. They are listed below.",
             ]),
        Item(id: "calendar", title: "Calendar", location: .onDevice,
             summary: "TaskFold reads your calendars to show busy time when you plan your day or reschedule tasks. If you turn on Show time blocks in Calendar, it also writes your planned tasks to one calendar.",
             points: [
                "Apple Calendar events are read on this device through Apple’s EventKit, and only after you allow access.",
                "Calendar events are not part of the workspace data that syncs to TaskFold or of its backups, so they are not uploaded.",
                "If you connect Google Calendar or Outlook, TaskFold reads busy time directly from Google or Microsoft with read-only access. The sign-in token stays in this device’s Keychain and the data does not pass through TaskFold’s server.",
                "Show time blocks in Calendar is off until you switch it on. It then asks for full calendar access, because TaskFold reads back its own events to update and remove them.",
                "When it is on, each planned task that has a start time and a duration becomes an event in a calendar named Taskfold, or in a writable calendar you choose, for today and the next 13 days. The event title is the task title. Task notes are never copied.",
                "Those events then sync like any other event in that calendar, through the account it belongs to, such as iCloud, Google or Exchange. TaskFold does not send them to its own servers.",
                "TaskFold changes only events it created in that calendar, which it recognises by a marker in the event, and never your other events. TaskFold’s own events are left out of busy time.",
                "Turning it off asks whether to remove TaskFold’s events from the calendar.",
             ]),
        Item(id: "location", title: "Location", location: .onDevice,
             summary: "Places for location reminders are saved privately on the device that delivers the reminder.",
             points: [
                "A saved place (name, coordinates and radius) lives in a private file on the iPhone or iPad. It is kept out of tasks, widgets, templates, exported backups and shared captures.",
                "Reminders use the system’s arrive and leave triggers. The app asks for your current position once, when you use it while choosing a place.",
                "Searching for a place sends your search words to Apple’s maps search.",
                "Exception: if you choose to send a place draft from a Mac to your iPhone or iPad, its name, coordinates and radius are uploaded to your TaskFold account so your iPhone or iPad can collect it. Each draft has an expiry time.",
             ]),
        Item(id: "voice", title: "Voice and audio", location: .onDevice,
             summary: "Dictation is processed on this device.",
             points: [
                "Dictation, for example in Brain dump, requires on-device speech recognition. If a language can’t be recognised on the device, dictation is refused instead of using a server.",
                "Dictation audio is not saved or uploaded. Only the text appears in your draft.",
                "Voice comments on tasks start as private drafts on this device. If you publish one, the audio file is uploaded to TaskFold’s storage so people in that project can play it.",
             ]),
        Item(id: "analytics", title: "Analytics and tracking", location: .none,
             summary: "No third-party analytics.",
             points: [
                "TaskFold includes no third-party analytics, advertising or crash-reporting SDK.",
                "The only third-party package in the project is AppAuth, used to connect Google Calendar and Outlook.",
             ]),
        Item(id: "links", title: "Link previews", location: .otherServices,
             summary: "Link titles are fetched only for links in your own tasks that aren’t shared.",
             points: [
                "For a link in a task you created, in a project that isn’t shared, TaskFold fetches the page title straight from that website using Apple’s LinkPresentation. The request does not go through TaskFold’s server, and the website can see it.",
                "Links in shared projects, or in tasks shared with you, are not fetched automatically. They show only the website name.",
                "Fetched titles are cached on this device.",
             ]),
        Item(id: "holidays", title: "Holiday calendars", location: .otherServices,
             summary: "Choosing a holiday calendar for a reminder asks a public holiday service for dates.",
             points: [
                "TaskFold requests the list of countries, or one country’s holidays for a year, from nagerholidays.com. The request names the country and year and contains no account details or task content.",
             ]),
    ]

    static let controls: [Control] = [
        Control(id: "export", title: "Export your workspace",
                detail: "Save a portable JSON copy of your workspace. Exported files contain your data, so keep them somewhere private."),
        Control(id: "local", title: "Use TaskFold without an account",
                detail: "On the sign-in screen, choose the option to use TaskFold on this device. Your workspace then stays here and does not sync."),
        Control(id: "delete", title: "Delete your account",
                detail: "Removes your tasks, projects and profile from TaskFold’s servers. This cannot be undone. Exports and copies on other devices are not erased."),
    ]

    static func item(_ id: String) -> Item? { items.first { $0.id == id } }
    static func control(_ id: String) -> Control { controls.first { $0.id == id }! }
}
