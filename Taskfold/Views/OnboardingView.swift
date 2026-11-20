import SwiftUI

/// First run (design review mac-r2, PR 3): "Set up your day", then one welcome card that opens the starter project.
/// The starter project itself, its progress card and the sidebar pill live below; the rules that tick its tasks off are
/// in `Core/Onboarding.swift`.

// MARK: - Shared pieces

enum StarterStyle {
    /// The starter project's own hue (the app's Blue). Progress, the auto-complete toast and the pill all use it.
    static var hue: ProjectHue { ProjectPalette.hue(stored: Onboarding.projectColor, projectID: "starter") }
    static var tint: Color { hue.color }
    static func title(_ size: CGFloat = 24) -> Font { .custom(DS.Font.screenTitleFace, size: size, relativeTo: .title) }
}

/// Six segments, one per starter task; filled segments take the project's hue.
struct StarterProgressBar: View {
    var count: Int
    var total = Onboarding.Key.allCases.count
    var tint: Color = StarterStyle.tint
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Capsule().fill(index < count ? tint : Color.primary.opacity(0.12)).frame(height: 5)
            }
        }
        .animation(Transitions.Ease.smoothOut, value: count)
        .accessibilityElement(children: .ignore).accessibilityLabel("\(count) of \(total) done")
    }
}

/// "2 of 6" beside the project in the sidebar.
struct StarterProgressPill: View {
    var count: Int
    var total = Onboarding.Key.allCases.count
    var body: some View {
        Text("\(count) of \(total)").font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(StarterStyle.tint)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(StarterStyle.tint.opacity(0.14), in: .capsule)
            .accessibilityLabel("\(count) of \(total) starter tasks done").accessibilityIdentifier("starterProgressPill")
    }
}

// MARK: - Set up your day

struct SetUpYourDaySheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultView") private var defaultView = "today"
    @State private var start = 9 * 60
    @State private var end = 17 * 60
    /// Called once the sheet is closed by Skip or Continue.
    var finished: () -> Void = {}

    private func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    private func field(_ value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 4) {
            Text(time(value.wrappedValue)).font(.body.monospacedDigit()).frame(width: 58).padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: DS.Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
            Stepper("", value: value, in: range, step: 30).labelsHidden()
        }
    }
    private func row<Control: View>(_ title: String, _ note: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) { Text(title); Text(note).font(.subheadline).foregroundStyle(.secondary) }
            Spacer(minLength: 12)
            control()
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set up your day").font(StarterStyle.title(24)).accessibilityAddTraits(.isHeader)
                Text("Two quick choices so Taskfold fits your week. You can change them any time in Settings.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
            VStack(spacing: 0) {
                row("Working hours", "Your day is planned inside these.") {
                    HStack(spacing: 8) {
                        field($start, range: 0...(end - 30)).accessibilityLabel("Start of working hours")
                        Text("to").foregroundStyle(.secondary)
                        field($end, range: (start + 30)...1440).accessibilityLabel("End of working hours")
                    }
                }
                Divider()
                row("Start in", "Where Taskfold opens each day.") {
                    Picker("Start in", selection: $defaultView) {
                        Text("Today").tag(TaskScope.today.preferenceKey); Text("Inbox").tag(TaskScope.inbox.preferenceKey); Text("Upcoming").tag(TaskScope.upcoming.preferenceKey)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 200).accessibilityIdentifier("setupStartIn")
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .padding(.horizontal, 24)
            Divider().padding(.top, 20)
            HStack {
                Button("Skip") { close() }.keyboardShortcut(.cancelAction).controlSize(.large).foregroundStyle(.primary).accessibilityIdentifier("setupSkip")
                Spacer()
                Button("Continue") { save(); close() }.buttonStyle(.borderedProminent).tint(.brandCrimson).controlSize(.large)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("setupContinue")
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // Start from what the account already has, so Continue never overwrites a choice.
            if let hours = store.workingHours { start = hours.start; end = hours.end }
        }
    }
    private func save() {
        let binding = WorkspaceBinding(account: store.userID, generation: store.workspaceGeneration)
        // Saving the hours also ticks the starter task through the store's commit hook; the sheet's own close is the
        // moment the person sees, so that toast is held back. An unchanged value writes nothing, so tick it directly.
        _ = store.setWorkingHours(WorkingHours(start: start, end: end), workspace: binding)
        store.observeOnboarding(.setupSaved)
        store.onboardingAnnouncement = nil
    }
    private func close() { dismiss(); finished() }
}

// MARK: - Welcome card

/// One 480 pt card that replaces the old five-page tour. "Show me" opens the starter project.
struct OnboardingView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingSeen") private var onboardingSeen = false

    private var progress: Onboarding.Progress { store.starterProject == nil ? Onboarding.Progress() : store.starterProgress }
    private var peek: [Record] {
        let rows = store.starterTasks
        return Onboarding.Key.allCases.compactMap { key in rows.first { Onboarding.key(forTask: $0.id, account: store.userID) == key } }
    }

    var body: some View {
        VStack(spacing: 0) {
            TaskfoldMark(size: 56).padding(.top, 32)
            Text("Welcome to Taskfold").font(StarterStyle.title(28)).padding(.top, 18).accessibilityAddTraits(.isHeader)
            Text("Your starter project will show you around. It takes about two minutes.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    StarterProgressBar(count: progress.count)
                    (Text("\(progress.count)").fontWeight(.semibold).foregroundStyle(.primary) + Text(" of \(progress.total) done").foregroundStyle(.secondary)).font(.subheadline).monospacedDigit().fixedSize()
                }
                ForEach(peek.prefix(3)) { task in
                    HStack(spacing: 10) {
                        Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(task.completed ? StarterStyle.tint : Color.secondary.opacity(0.7))
                        Text(task.title).foregroundStyle(task.completed ? .secondary : .primary)
                        Spacer(minLength: 0)
                    }.font(.body)
                }
            }
            .padding(16)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.75), .init(color: .black.opacity(0.35), location: 1)], startPoint: .top, endPoint: .bottom))
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .padding(.horizontal, 32).padding(.top, 22)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Starter project, \(progress.count) of \(progress.total) done")
            Button { show() } label: { Text("Show me").fontWeight(.semibold).frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(.brandCrimson).controlSize(.large)
                .keyboardShortcut(.defaultAction).accessibilityIdentifier("onboardingShowMe")
                .padding(.horizontal, 32).padding(.top, 22)
            Button("I know my way around") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction).accessibilityIdentifier("skipOnboarding").padding(.top, 14)
            Text("You can bring it back from Help ▸ Show Starter Project.").font(.footnote).foregroundStyle(.tertiary).padding(.top, 10).padding(.bottom, 24)
        }
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Taskfold")
    }
    private func show() { finish(); workspace.openStarterProject() }
    private func finish() {
        #if DEBUG
        // A forced card in a fixture run must not mark the real app's welcome as seen.
        if FixtureDefaults.isFixtureRun { FixtureDefaults.set(true, forKey: "onboardingSeen"); dismiss(); return }
        #endif
        onboardingSeen = true; dismiss()
    }
}

// MARK: - The starter project's header card

/// Sits under the project title: the one-line promise, six progress segments and the "⋯" menu.
struct StarterHeaderCard: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @State private var confirmDelete = false
    var body: some View {
        let progress = store.starterProgress
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if progress.finished {
                    Text("You're all set.").fontWeight(.semibold) + Text(" Delete this project whenever you like.").foregroundStyle(.secondary)
                } else {
                    Text("Learn Taskfold by doing.").fontWeight(.semibold) + Text(" Each task checks itself off when you do it.").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if progress.finished {
                    Button("Delete project…") { confirmDelete = true }.controlSize(.small).accessibilityIdentifier("starterDeleteProject")
                }
                Menu {
                    Button("Hide Project") { if store.hideStarterProject() { workspace.section = .today } }
                    Button("Delete Project…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Starter project options").accessibilityIdentifier("starterMenu")
            }
            .font(.body)
            HStack(spacing: 14) {
                StarterProgressBar(count: progress.count)
                (Text("\(progress.count)").fontWeight(.semibold).foregroundStyle(.primary) + Text(" of \(progress.total) done").foregroundStyle(.secondary)).font(.subheadline).monospacedDigit().fixedSize()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: DS.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain).accessibilityIdentifier("starterHeaderCard")
        .confirmationDialog("Delete the starter project?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Project", role: .destructive) { workspace.section = .today; store.deleteStarterProject() }
        } message: { Text("This removes its six tasks. Tasks you added to it move to Inbox. You can bring it back from Help ▸ Show Starter Project.") }
    }
}
