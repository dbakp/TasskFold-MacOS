import SwiftUI
import AppKit

/// What the global panel remembers between openings: the unsent draft (text, declined tokens, reference choices, chosen
/// properties) for up to ten minutes, and the brief "Added to Inbox" confirmation.
@MainActor @Observable
final class GlobalQuickAddDraft {
    var text = ""
    var declined = Set<String>()
    var choices = [String: String]()
    var manual = [String: JSON]()
    /// Bumped every time the composer is shown or reset so a fresh field takes focus at once.
    var generation = 0
    var confirmation: String?
    var closedAt: Date?

    static let retention: TimeInterval = 10 * 60

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func reset() {
        text = ""; declined = []; choices = [:]; manual = [:]; confirmation = nil; closedAt = nil
        generation += 1
    }
    /// Called as the panel opens: a draft older than ten minutes is dropped.
    func prepareForOpening(now: Date = Date()) {
        if hasText, let closedAt, now.timeIntervalSince(closedAt) <= Self.retention { confirmation = nil; generation += 1 }
        else { reset() }
    }
    /// Called as the panel closes: an empty composer is cleared, a draft is kept and timestamped.
    func noteClosing(now: Date = Date()) {
        if hasText && confirmation == nil { closedAt = now } else { reset() }
    }
}

/// The composer in the floating panel: the same `TaskCapturePanel` the app uses, with Inbox and no date as the
/// destination, key hints, and a short inline confirmation.
struct GlobalQuickAddView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accent") private var accent = "rose"
    @Bindable var draft: GlobalQuickAddDraft
    let close: () -> Void
    let added: (_ keepOpen: Bool) -> Void
    var body: some View {
        ZStack {
            TaskCapturePanel(text: $draft.text, declined: $draft.declined, choices: $draft.choices, prompt: "Add to Inbox — try “Call Sam tomorrow at 4pm p1”",
                             context: workspace.quickEntryContext(), task: workspace.captureTask(date: nil, scope: .inbox), submit: submit,
                             onClose: close, manualChoices: $draft.manual, hint: "↩ Add   ·   ⌘↩ Add and keep open   ·   Esc Close")
                .id(draft.generation)
                .opacity(draft.confirmation == nil ? 1 : 0)
                .allowsHitTesting(draft.confirmation == nil)
            if let message = draft.confirmation {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                        .foregroundStyle(Color.contrastingForeground(on: Color.taskfold), Color.taskfold).accessibilityHidden(true)
                    Text(message).foregroundStyle(DS.Palette.textPrimary)
                }
                .font(DS.Font.screenTitle).transition(.opacity).accessibilityElement(children: .combine)
                .accessibilityIdentifier("globalQuickAddConfirmation")
            }
        }
        .animation(Motion.respecting(reduceMotion, Motion.quick), value: draft.confirmation)
        .frame(width: 540)
        .background(DS.Palette.surface)
        .tint(Color.adaptiveAccent(accent))
        .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
    }

    private func submit() {
        guard draft.confirmation == nil else { return }
        let keepOpen = NSEvent.modifierFlags.contains(.command)
        let input = draft.text.components(separatedBy: .newlines).joined(separator: " ")
        guard let id = workspace.add(input, project: "", date: nil, declined: draft.declined, referenceChoices: draft.choices, manual: draft.manual, scope: .inbox) else {
            // A shared-project task opens its full editor in the main window instead of saving here.
            if workspace.teamTaskCreation != nil { close(); GlobalQuickAddController.openMainWindow() }
            return
        }
        let project = store.record("tasks", id: id).flatMap { store.record("projects", id: $0.string("project_id")) }
        draft.confirmation = "Added to " + (project?.name ?? "Inbox")
        added(keepOpen)
    }
}

/// A floating panel that can take keyboard focus without activating Taskfold or raising its other windows.
final class QuickAddFloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Owns the global hot key, the floating panel and the saved shortcut. Settings and the menu bar observe it.
@MainActor @Observable
final class GlobalQuickAddController {
    static let shared = GlobalQuickAddController()

    /// The chord currently registered, nil when cleared or when registration failed.
    private(set) var shortcut: QuickAddShortcut?
    /// Why the last change was refused, shown under the recorder.
    var message: String?
    let draft = GlobalQuickAddDraft()
    private(set) var isShown = false

    @ObservationIgnored private var store: Store?
    @ObservationIgnored private var workspace: Workspace?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var panel: QuickAddFloatingPanel?
    @ObservationIgnored private var topLeft = NSPoint.zero
    @ObservationIgnored private var lastSize = NSSize.zero
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var closing: Task<Void, Never>?

    var hint: String? { shortcut.map { "\($0.displayString) to add from anywhere" } }

    // MARK: Lifecycle

    /// Called once at launch. Registers the saved shortcut; the panel itself is built lazily.
    func start(store: Store, workspace: Workspace, registersHotKey: Bool = true) {
        guard self.store == nil else { return }
        self.store = store; self.workspace = workspace
        let saved = QuickAddShortcutStore.load()
        guard registersHotKey else { shortcut = saved; return }
        hotKey = GlobalHotKey { [weak self] in self?.toggle() }
        if let saved { apply(saved, persist: false) }
    }

    /// Unregisters on quit.
    func stop() {
        hide(animated: false)
        hotKey?.tearDown()
    }

    // MARK: Shortcut

    /// Registers `candidate` and stores it. A refused chord leaves the previous one in place and sets `message`.
    @discardableResult
    func apply(_ candidate: QuickAddShortcut, persist: Bool = true) -> Bool {
        if let problem = candidate.problem { message = problem.message; return false }
        guard let hotKey else { shortcut = candidate; message = nil; if persist { QuickAddShortcutStore.save(candidate) }; return true }
        if let failure = hotKey.register(candidate) { message = failure.message; return false }
        shortcut = candidate; message = nil
        if persist { QuickAddShortcutStore.save(candidate) }
        return true
    }
    func clearShortcut() {
        hotKey?.unregister(); shortcut = nil; message = nil
        QuickAddShortcutStore.save(nil)
    }
    func resetShortcut() {
        QuickAddShortcutStore.reset()
        _ = apply(.default, persist: false)
    }

    // MARK: Panel

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard let store, workspace != nil else { return }
        guard store.signedIn || store.localMode else { Self.openMainWindow(); return }
        closing?.cancel()
        draft.prepareForOpening()
        let panel = self.panel ?? makePanel()
        place(panel)
        isShown = true
        // Key without activating: the previous app stays frontmost and Taskfold's other windows stay where they are.
        panel.orderFrontRegardless()
        panel.makeKey()
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
        }
    }

    func hide(animated: Bool = true) {
        guard isShown, let panel else { return }
        draft.noteClosing()
        isShown = false
        closing?.cancel()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel.orderOut(nil)
    }

    /// Called after a task was added. Shows the confirmation for about 600 ms, then closes or resets for the next task.
    func added(keepOpen: Bool) {
        closing?.cancel()
        closing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            if keepOpen { self.draft.reset(); self.panel?.makeKey() } else { self.draft.reset(); self.hide() }
        }
    }

    private func makePanel() -> QuickAddFloatingPanel {
        let panel = QuickAddFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 240),
                                          styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.setAccessibilityIdentifier("globalQuickAddPanel")
        panel.onCancel = { [weak self] in self?.hide() }
        let root = GlobalQuickAddView(draft: draft, close: { [weak self] in self?.hide() }, added: { [weak self] in self?.added(keepOpen: $0) })
            .environment(store!).environment(workspace!)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        host.safeAreaRegions = []
        panel.contentViewController = host
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panelResignedKey() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.keepTopFixed() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.userMoved() }
        })
        // A property popover closing hands key status back to the composer.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.object as? NSWindow)?.className.contains("Popover") == true else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, self.isShown, let panel = self.panel, !panel.isKeyWindow, NSApp.keyWindow == nil || NSApp.keyWindow?.className.contains("Popover") == true else { return }
                panel.makeKey()
            }
        })
        self.panel = panel
        return panel
    }

    private func panelResignedKey() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, self.isShown, let panel = self.panel, !panel.isKeyWindow else { return }
            // A property popover (a child of the panel) is not "outside".
            if let key = NSApp.keyWindow, key !== panel, key.parent === panel || key.className.contains("Popover") { return }
            self.hide()
        }
    }

    /// Centred horizontally, with its top edge a third of the way down the screen that holds the pointer.
    private func place(_ panel: QuickAddFloatingPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        panel.contentViewController?.view.layoutSubtreeIfNeeded()
        let fitted = panel.contentViewController?.view.fittingSize ?? NSSize(width: 540, height: 240)
        panel.setContentSize(NSSize(width: 540, height: max(fitted.height, 120)))
        topLeft = NSPoint(x: (area.midX - panel.frame.width / 2).rounded(), y: (area.maxY - area.height / 3).rounded())
        panel.setFrameTopLeftPoint(topLeft)
        lastSize = panel.frame.size
    }
    private var anchored: Bool {
        guard let panel else { return true }
        return abs(panel.frame.minX - topLeft.x) < 0.5 && abs(panel.frame.maxY - topLeft.y) < 0.5
    }
    /// Content changes (a parsed chip row, a longer title) grow the panel downward, never upward.
    private func keepTopFixed() {
        guard isShown, let panel else { return }
        lastSize = panel.frame.size
        if !anchored { panel.setFrameTopLeftPoint(topLeft) }
    }
    /// A drag by the user moves the anchor; programmatic placement always lands exactly on it.
    private func userMoved() {
        guard isShown, let panel, panel.frame.size == lastSize, !anchored else { return }
        topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    // MARK: Main window

    /// Brings the main window forward (or reopens it). Used by the menu bar extra and shared-project captures.
    static func openMainWindow() {
        NSApp.activate()
        if let window = mainWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            // With no window open, reopening the app makes SwiftUI create one.
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }
    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && $0.identifier?.rawValue.contains("AppWindow") == true }
    }
}

#if DEBUG
/// Hosts the global composer pre-filled with `text` for the offscreen `--capture-global-quick-add` debug option.
struct GlobalQuickAddCaptureHost: View {
    @State private var draft = GlobalQuickAddDraft()
    let text: String
    let confirm: Bool
    var body: some View {
        GlobalQuickAddView(draft: draft, close: {}, added: { _ in })
            .onAppear { draft.text = text; if confirm { draft.confirmation = "Added to Inbox" } }
    }
}
#endif
