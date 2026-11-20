import Foundation

/// A toast request for the screen: a starter task just ticked itself off.
struct OnboardingAnnouncement: Equatable, Identifiable {
    var id = UUID()
    var message: String
    /// "2 of 6 done", or the all-done line.
    var detail: String
}

/// Which first-run step the screen should present next.
enum OnboardingStage: Equatable {
    /// "Set up your day": working hours and where the app opens.
    case setup
    /// The single welcome card with "Show me".
    case welcome
    /// Open the starter project (Settings ▸ Show Starter Project on iPhone).
    case openProject
}

/// Applies `Onboarding` (pure rules, `Core/Onboarding.swift`) to the live store: seeds the starter project once per
/// account, keeps the synced flag, and ticks starter tasks off as the person does the thing. See `Onboarding` for
/// where the flag lives. Shared by both apps; platform wording comes from `onboardingPlatform`.
extension Store {
    static var onboardingPlatform: Onboarding.Platform {
        #if os(macOS)
        .mac
        #else
        .ios
        #endif
    }

    // MARK: Reading

    var onboardingFlag: Onboarding.Flag? { Onboarding.flag(in: profile["preferences"]) }
    var starterProject: Record? { record("projects", id: Onboarding.projectID(account: userID)) }
    var starterTasks: [Record] {
        let ids = Set(Onboarding.starterTaskIDs(account: userID))
        return tasks.filter { ids.contains($0.id.lowercased()) }
    }
    /// Progress, in the project's own order, for the header card, the sidebar pill and the welcome card.
    var starterProgress: Onboarding.Progress { Onboarding.progress(tasks: starterTasks, account: userID) }
    /// The starter project is on screen: it exists and has not been hidden.
    var starterProjectVisible: Bool { starterProject != nil && onboardingFlag?.dismissed == false && starterProject?["is_archived"].flag != true }
    func isStarterProject(_ id: String) -> Bool { id.lowercased() == Onboarding.projectID(account: userID) }

    // MARK: Seeding

    /// Fixture and preview accounts opt in with `--starter-onboarding`, so every other test keeps its exact rows.
    private var onboardingAllowedHere: Bool {
        #if DEBUG
        if ["preview", "ui-testing"].contains(userID) { return ProcessInfo.processInfo.arguments.contains("--starter-onboarding") }
        #endif
        return true
    }
    /// Work the person made, which an account must not be given a starter project on top of.
    private var holdsEstablishedWork: Bool {
        let starter = Set(Onboarding.starterTaskIDs(account: userID))
        return !allProjects.allSatisfy { isStarterProject($0.id) } || tasks.contains { !starter.contains($0.id.lowercased()) }
    }

    /// Runs from the screen on launch and after each full read. Seeds once per account, then keeps the platform list
    /// current. Safe to call repeatedly.
    func starterOnboardingCheck() {
        guard onboardingAllowedHere, signedIn || localMode, !signingOut, !accountRemovalBlocked, !userID.isEmpty,
              !onboardingBusy else { return }
        // A signed-in account is judged only once its first full read has landed and its profile row is here.
        if !localMode, lastSync == nil || profile.id.isEmpty { return }
        onboardingBusy = true; defer { onboardingBusy = false }
        let platform = Self.onboardingPlatform
        if var flag = onboardingFlag {
            guard !flag.skipped else { return }
            if !localMode, !flag.platforms.contains(platform.rawValue) {
                flag = Onboarding.adding(platform, to: flag); writeOnboardingFlag(flag)
            }
            if !localMode, !flag.dismissed, starterProject != nil { observeOnboarding(.platforms(flag.platforms)) }
            return
        }
        guard !holdsEstablishedWork else {
            // An account with work of its own keeps it exactly as it is; the flag just stops asking.
            writeOnboardingFlag(Onboarding.Flag(dismissed: true, skipped: true)); return
        }
        seedStarterProject()
    }

    /// Creates the project, its six tasks and the flag in one commit. Same IDs every time, create-only.
    @discardableResult
    private func seedStarterProject(reopening: Bool = false) -> Bool {
        let hoursSet = !workingHoursDocument.isNullDocument
        let plan = Onboarding.seedMutations(account: userID, platform: Self.onboardingPlatform, localMode: localMode, completed: hoursSet ? [.workingHours] : [])
        var flag = onboardingFlag ?? Onboarding.Flag(seededAt: Dates.timestamp())
        flag.dismissed = false
        if !localMode { flag = Onboarding.adding(Self.onboardingPlatform, to: flag) }
        let existing = tasks.map { $0.id.lowercased() }
        let fresh = plan.filter { change in !(change.table == "tasks" && existing.contains(change.recordID)) && !(change.table == "projects" && starterProject != nil) }
        guard writeOnboardingFlag(flag, alongside: fresh) else { return false }
        if !reopening { onboardingStage = hoursSet ? .welcome : .setup }
        return true
    }

    /// Writes the flag into the profile row's `preferences` (other keys kept). Seeding rides in the same commit. Never
    /// undoable: Undo must not unseed an account or forget that it was onboarded.
    @discardableResult
    private func writeOnboardingFlag(_ flag: Onboarding.Flag, alongside extra: [Mutation] = []) -> Bool {
        let row = profile, old = row["preferences"]
        let preferences = Onboarding.writing(flag, into: old.isNullDocument ? .object([:]) : old)
        let change: Mutation
        if row.id.isEmpty {
            change = Mutation(table: "profiles", recordID: userID, method: "POST", fields: ["id": .string(userID), "user_id": .string(userID), "preferences": preferences], insertOnly: true)
        } else {
            change = Mutation(table: "profiles", recordID: row.id, method: "PATCH", fields: ["preferences": preferences], baseline: ["preferences": old])
        }
        let previous = onboardingApplying; onboardingApplying = true; defer { onboardingApplying = previous }
        return commit(extra + [change], remember: false)
    }

    // MARK: Auto-complete

    /// Feeds one thing the person did to the starter rules. The only cost on the hot path is a cheap pure pre-check.
    func observeOnboarding(_ event: Onboarding.Event) {
        guard !onboardingApplying, signedIn || localMode, !userID.isEmpty else { return }
        let everything = Set(Onboarding.Key.allCases)
        guard !Onboarding.completions(for: event, account: userID, open: everything).isEmpty else { return }
        guard let flag = onboardingFlag, !flag.dismissed, !flag.skipped, starterProject != nil else { return }
        let done = starterProgress.done
        let keys = Onboarding.completions(for: event, account: userID, open: everything.subtracting(done))
        guard !keys.isEmpty else { return }
        var changes: [Mutation] = []
        for key in keys {
            guard let task = record("tasks", id: Onboarding.taskID(account: userID, key: key)), !task.completed else { continue }
            changes += toggleChanges(task)
        }
        guard !changes.isEmpty else { return }
        onboardingApplying = true; defer { onboardingApplying = false }
        guard commit(changes) else { return }
        let progress = starterProgress
        onboardingAnnouncement = OnboardingAnnouncement(
            message: progress.finished ? "You're all set." : Onboarding.celebration(keys[0]),
            detail: progress.finished ? "\(progress.total) of \(progress.total) done" : "\(progress.count) of \(progress.total) done")
    }
    /// The Quick Add hook: `groups` are the parsed token groups of the text just added.
    func observeOnboardingQuickAdd(taskID: String, groups: [String]) { observeOnboarding(.quickAdd(taskID: taskID, groups: groups)) }

    // MARK: Hide, delete, bring back

    /// Hides the project from the sidebar and every list (it is archived), and remembers that in the flag.
    @discardableResult
    func hideStarterProject() -> Bool {
        guard let project = starterProject else { return false }
        var flag = onboardingFlag ?? Onboarding.Flag(seededAt: Dates.timestamp()); flag.dismissed = true
        writeOnboardingFlag(flag)
        return archiveProject(project, archived: true)
    }
    /// Removes the starter tasks and the project. Anything the person added to the project is kept, in Inbox.
    func deleteStarterProject() {
        var flag = onboardingFlag ?? Onboarding.Flag(seededAt: Dates.timestamp()); flag.dismissed = true
        writeOnboardingFlag(flag)
        removeAll(starterTasks.map(\.id))
        if starterProject != nil { remove("projects", Onboarding.projectID(account: userID)) }
    }
    /// Help ▸ Show Starter Project: brings a hidden project back, or creates it again if it was deleted.
    @discardableResult
    func showStarterProject() -> Bool {
        if let project = starterProject {
            if project["is_archived"].flag { guard archiveProject(project, archived: false) else { return false } }
            var flag = onboardingFlag ?? Onboarding.Flag(seededAt: Dates.timestamp())
            guard flag.dismissed || onboardingFlag == nil else { return true }
            flag.dismissed = false
            return writeOnboardingFlag(flag)
        }
        return seedStarterProject(reopening: true)
    }
}

private extension JSON {
    var isNullDocument: Bool { if case .null = self { return true }; return false }
}

extension CalendarBusyStore {
    /// "Calendar access is granted and a calendar is selected": a device calendar is connected with at least one
    /// calendar chosen, or a direct calendar link is active.
    var onboardingConnected: Bool { (connected && !selected.isEmpty) || links?.active == true }
}
