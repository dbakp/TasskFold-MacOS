import SwiftUI

/// The welcome tour: five pages built from the app's own components (real chips, real check controls,
/// the real accent), so what the tour shows is exactly what the app does. Dismissable at any point with
/// Skip or Escape; ← → and Return move between pages; Settings ▸ General can show it again.
struct OnboardingView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("onboardingSeen") private var onboardingSeen = false
    @AppStorage("accent") private var accent = "rose"
    @State private var page = 0
    @State private var direction: CGFloat = 1
    @FocusState private var focused: Bool
    private let pages = 5
    private var layout: Animation? { Motion.respecting(reduceMotion, Motion.layout) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                illustration.id(page)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: direction > 0 ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [Color.taskfold.opacity(0.16), Color.taskfold.opacity(0.03)], startPoint: .top, endPoint: .bottom)
            )
            .clipped()
            .overlay(alignment: .topTrailing) {
                Button("Skip") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary).padding(16)
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("skipOnboarding")
            }
            VStack(spacing: 10) {
                Text(title).font(.title.weight(.semibold)).id("t\(page)").transition(.textSwap)
                Text(body_).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440).fixedSize(horizontal: false, vertical: true)
                    .id("b\(page)").transition(.textSwap)
            }
            .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 18)
            .frame(minHeight: 130, alignment: .top)
            .animation(Transitions.Ease.smoothOut, value: page)
            HStack(spacing: 14) {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0).accessibilityLabel("Previous page")
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<pages, id: \.self) { index in
                        Button { direction = index > page ? 1 : -1; withAnimation(layout) { page = index } } label: {
                            Capsule().fill(index == page ? Color.taskfold : Color.primary.opacity(0.15))
                                .frame(width: index == page ? 22 : 7, height: 7)
                        }.buttonStyle(.plain).accessibilityLabel("Page \(index + 1) of \(pages)").accessibilityAddTraits(index == page ? .isSelected : [])
                    }
                }
                .animation(Transitions.Ease.smoothOut, value: page)
                Spacer()
                if page < pages - 1 {
                    Button("Continue") { move(1) }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).accessibilityIdentifier("onboardingContinue")
                } else {
                    if store.signedIn && store.localMode {
                        Button("Sign In…") { finish(); workspace.settingsTab = .account; workspace.signInRequested = true; NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                            .controlSize(.large)
                    }
                    Button("Get Started") { finish() }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).accessibilityIdentifier("finishOnboarding")
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(width: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable().focusEffectDisabled().focused($focused)
        .onAppear { focused = true }
        .onMoveCommand { direction in
            if direction == .right { move(1) } else if direction == .left { move(-1) }
        }
        .onExitCommand { finish() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome tour, page \(page + 1) of \(pages)")
    }

    private func move(_ delta: Int) {
        let next = min(max(page + delta, 0), pages - 1)
        guard next != page else { return }
        direction = CGFloat(delta)
        withAnimation(layout) { page = next }
    }
    private func finish() { onboardingSeen = true; dismiss() }

    private var title: String {
        ["Welcome to Taskfold", "Capture in one line", "Order that stays put", "Plan the day, then move fast", "Make it yours"][page]
    }
    private var body_: String {
        ["A calm place for today's tasks. This short tour shows how the Mac app works; skip it anytime.",
         "Type naturally. Dates, times, priorities, and #labels become chips as you write. Press ✕ on a chip to keep those words in the title instead.",
         "Lists sort by priority band, and your own order holds inside each band. Drag anywhere; the task lands in its band and a hint tells you why.",
         "Plan Your Day walks overdue and today's tasks one card at a time. In lists, Space completes, Return edits, ⌘N adds, ⌘Z undoes anything.",
         "Pick an accent. Sign in to sync with Taskfold on iPhone and the web, add a Today widget, and use Shortcuts."][page]
    }

    @ViewBuilder private var illustration: some View {
        switch page {
        case 0: WelcomeIllustration()
        case 1: CaptureIllustration()
        case 2: BandsIllustration()
        case 3: PlanIllustration()
        default: AccentIllustration(accent: $accent)
        }
    }
}

// MARK: - Illustrations

private struct WelcomeIllustration: View {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 18) {
            TaskfoldMark(size: 112)
                .scaleEffect(shown || reduceMotion ? 1 : 0.6).opacity(shown || reduceMotion ? 1 : 0)
                .rotationEffect(.degrees(shown || reduceMotion ? 0 : -6))
            HStack(spacing: 10) {
                ForEach(Array(["Today", "Inbox", "Upcoming", "Calendar"].enumerated()), id: \.offset) { index, name in
                    Label(name, systemImage: ["sun.max", "tray", "calendar.day.timeline.left", "calendar"][index])
                        .font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color(nsColor: .controlBackgroundColor), in: .capsule)
                        .opacity(shown || reduceMotion ? 1 : 0).offset(y: shown || reduceMotion ? 0 : Transitions.Distance.medium)
                        .animation(Transitions.Ease.smoothOut(Transitions.Duration.slow).delay(0.25 + Double(index) * Transitions.Duration.micro), value: shown)
                }
            }
        }
        .animation(Transitions.Ease.bounce(Transitions.Duration.verySlow), value: shown)
        .onAppear { shown = true }
        .accessibilityHidden(true)
    }
}

/// Types a sentence the parser understands and lets the real chips appear as the words land.
private struct CaptureIllustration: View {
    private let sentence = "Call the studio tomorrow at 14.30 p2 #calls"
    @State private var typed = ""
    @State private var task: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let parsed = QuickEntry(typed)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.taskfold).font(.title3)
                Text(typed.isEmpty ? "Add a task…" : typed).foregroundStyle(typed.isEmpty ? .tertiary : .primary)
                    .font(.body)
                Rectangle().fill(Color.taskfold).frame(width: 1.5, height: 18).opacity(typed.count < sentence.count ? 1 : 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.taskfold.opacity(0.5), lineWidth: 1.5))
            HStack {
                QuickEntryChips(tokens: parsed.tokens, decline: { _ in })
                Spacer()
            }.frame(height: 28)
            Text(parsed.tokens.isEmpty ? " " : "Title becomes “\(parsed.title)”").font(.caption).foregroundStyle(.secondary).contentTransition(.opacity)
        }
        .padding(.horizontal, 60)
        .onAppear {
            guard !reduceMotion else { typed = sentence; return }
            task = Task {
                for index in sentence.indices {
                    try? await Task.sleep(for: .milliseconds(55))
                    if Task.isCancelled { return }
                    typed = String(sentence[...index])
                }
            }
        }
        .onDisappear { task?.cancel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Typing \(sentence) turns tomorrow, 14:30, P2, and #calls into chips.")
    }
}

/// Three rows in two bands; a P3 row drifts toward the P1 band and snaps back with the hint.
private struct BandsIllustration: View {
    @State private var lifted = false
    @State private var hint = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let rows: [(String, Int)] = [("Send the revised proposal", 1), ("Make time for the big idea", 1), ("A walk, without the phone", 3)]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index == 2 { InsertionIndicator(hint: hint ? "Stays with P3" : nil).opacity(hint || lifted ? 1 : 0) }
                HStack(spacing: 10) {
                    CheckMark(checked: false, color: Color.priority(row.1), emphasized: row.1 < 4)
                    Text(row.0)
                    Spacer()
                    Image(systemName: "flag.fill").font(.caption2).foregroundStyle(Color.priority(row.1))
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .modifier(CardSurface(radius: 9, elevated: index == 2 && lifted))
                .offset(y: index == 2 && lifted ? -74 : 0)
                .scaleEffect(index == 2 && lifted ? 1.02 : 1)
                .zIndex(index == 2 ? 1 : 0)
            }
        }
        .padding(.horizontal, 90)
        .task {
            guard !reduceMotion else { hint = true; return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.9)); if Task.isCancelled { return }
                withAnimation(Motion.lift) { lifted = true }
                try? await Task.sleep(for: .seconds(0.9)); if Task.isCancelled { return }
                withAnimation(Transitions.Ease.smoothOut(Transitions.Duration.quick)) { hint = true }
                try? await Task.sleep(for: .seconds(1.4)); if Task.isCancelled { return }
                withAnimation(Motion.settle) { lifted = false }
                try? await Task.sleep(for: .seconds(0.6)); if Task.isCancelled { return }
                withAnimation(Transitions.Ease.smoothOut(Transitions.Duration.quick)) { hint = false }
                try? await Task.sleep(for: .seconds(1.6))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A priority 3 task dragged above priority 1 tasks lands at the top of its own band; a hint reads Stays with P3.")
    }
}

private struct PlanIllustration: View {
    private let keys: [(String, String)] = [("Space", "Complete"), ("↩", "Edit"), ("⌘N", "New task"), ("⌘Z", "Undo"), ("T · M · D", "Today · Tomorrow · Date")]
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Plan Your Day").font(.headline); Spacer(); Text("2 of 5").font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                Capsule().fill(Color.primary.opacity(0.08)).frame(height: 5).overlay(alignment: .leading) { Capsule().fill(Color.taskfold).frame(width: 96, height: 5) }
                HStack(spacing: 8) {
                    Label("P1", systemImage: "flag.fill").font(.caption.weight(.semibold)).foregroundStyle(.red)
                    Text("Send the revised proposal").font(.body.weight(.semibold))
                    Spacer()
                    Text("1 day overdue").font(.caption.weight(.medium)).foregroundStyle(.red)
                }
            }
            .padding(14).modifier(CardSurface(radius: 12, elevated: true)).frame(width: 400)
            HStack(spacing: 10) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    VStack(spacing: 4) {
                        Text(key.0).font(.callout.weight(.semibold)).monospaced()
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        Text(key.1).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .opacity(shown || reduceMotion ? 1 : 0).offset(y: shown || reduceMotion ? 0 : Transitions.Distance.base)
                    .animation(Transitions.Ease.smoothOut(Transitions.Duration.slow).delay(Double(index) * Transitions.Duration.micro), value: shown)
                }
            }
        }
        .onAppear { shown = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Plan Your Day card with keyboard shortcuts: Space completes, Return edits, Command N adds, Command Z undoes, T M D reschedule.")
    }
}

private struct AccentIllustration: View {
    @Binding var accent: String
    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 14) {
                ForEach(Color.accents, id: \.key) { option in
                    Button { withAnimation(Transitions.Ease.smoothOut(Transitions.Duration.quick)) { accent = option.key } } label: {
                        Circle().fill(option.color).frame(width: 34, height: 34)
                            .overlay { if accent == option.key { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white) } }
                            .scaleEffect(accent == option.key ? 1.12 : 1)
                            .shadow(color: option.color.opacity(accent == option.key ? 0.45 : 0), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain).pointerStyle(.link)
                    .help(option.name).accessibilityLabel(option.name).accessibilityAddTraits(accent == option.key ? .isSelected : [])
                }
            }
            HStack(spacing: 28) {
                ForEach(Array([("iphone", "iPhone & iPad"), ("macbook", "Mac"), ("rectangle.grid.2x2", "Widgets"), ("sparkles.rectangle.stack", "Shortcuts")].enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 6) {
                        Image(systemName: item.0).font(.system(size: 26, weight: .medium)).symbolRenderingMode(.hierarchical).foregroundStyle(Color.taskfold)
                        Text(item.1).font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 90)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
