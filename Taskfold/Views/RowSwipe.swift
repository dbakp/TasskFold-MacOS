import SwiftUI
import AppKit

struct MacSwipeSample {
    enum Phase { case begin, change, end, cancel, momentum }
    var phase: Phase
    var dx: Double = 0
    var dy: Double = 0
    var momentumEnded = false
}

/// One local event owner per list. It never replaces an AppKit/SwiftUI delegate.
@MainActor @Observable final class MacRowSwipeController {
    private(set) var motion = RowGestureMotion()
    private(set) var surface: UUID?
    var reduceMotion = false
    @ObservationIgnored var isAvailable: () -> Bool = { true }
    @ObservationIgnored private var anchors: [UUID: WeakAnchor] = [:]
    @ObservationIgnored private weak var candidate: MacSwipeAnchor.View?
    @ObservationIgnored private var dispatch: ((RowGestureCommand) -> Void)?
    @ObservationIgnored private var suppressMomentum = false
    @ObservationIgnored private var abandonedSequence = false
    @ObservationIgnored private var lease = UUID()
    private final class WeakAnchor {
        weak var view: MacSwipeAnchor.View?
        init(_ view: MacSwipeAnchor.View) { self.view = view }
    }
    func configure(leading: RowGestureAction, trailing: RowGestureAction, fullSwipe: Bool, rightToLeft: Bool) {
        cancel()
        motion.leading = leading; motion.trailing = trailing
        motion.fullSwipe = fullSwipe; motion.rightToLeft = rightToLeft
    }
    func register(_ view: MacSwipeAnchor.View) { anchors[view.id] = WeakAnchor(view) }
    func unregister(_ view: MacSwipeAnchor.View) {
        anchors.removeValue(forKey: view.id)
        // Dismantling an NSView occurs during SwiftUI updates. Revoke the callback now;
        // defer observable presentation changes to avoid reentrant List updates.
        if surface == view.id {
            revokeAfterUpdate()
        }
    }
    func offset(for id: UUID) -> CGFloat { surface == id ? motion.offset * (motion.rightToLeft ? -1 : 1) : 0 }
    func revokeAfterUpdate() {
        dispatch = nil; candidate = nil
        let token = lease
        Task { @MainActor [weak self] in if self?.lease == token { self?.cancel() } }
    }
    func cancel() {
        lease = UUID()
        guard surface != nil || motion.stage != .idle || dispatch != nil else { return }
        if motion.stage == .tracking { abandonedSequence = true; suppressMomentum = true }
        dispatch = nil; candidate = nil
        withAnimation(Motion.respecting(reduceMotion, Motion.settle)) { motion.cancel(); surface = nil }
    }
    private func target(at point: NSPoint, window: NSWindow) -> MacSwipeAnchor.View? {
        anchors.values.compactMap(\.view).first { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor && !view.visibleBounds.isEmpty && view.visibleBounds.contains(view.convert(point, from: nil))
        }
    }
    func actionsContain(_ point: NSPoint, window: NSWindow) -> Bool {
        guard motion.stage == .open, let candidate, candidate.window === window else { return false }
        let rect = candidate.convert(candidate.visibleBounds, to: nil), offset = offset(for: candidate.id)
        guard rect.contains(point) else { return false }
        return offset > 0 ? point.x < rect.minX + offset : point.x > rect.maxX + offset
    }
    /// Finger displacement has already been normalized by the AppKit adapter.
    /// Returning true suppresses only an owned horizontal scroll sequence.
    func route(_ sample: MacSwipeSample, at point: NSPoint, window: NSWindow) -> Bool {
        if sample.phase == .momentum {
            let consume = suppressMomentum
            if sample.momentumEnded { suppressMomentum = false }
            return consume
        }
        if sample.phase == .begin {
            abandonedSequence = false; suppressMomentum = false
            guard isAvailable(), let anchor = target(at: point, window: window), let prepared = anchor.prepare() else { cancel(); abandonedSequence = false; suppressMomentum = false; return false }
            let previous = surface == anchor.id && motion.stage == .open ? motion.offset : 0
            cancel(); abandonedSequence = false; suppressMomentum = false
            candidate = anchor; surface = anchor.id; dispatch = prepared
            motion.canReschedule = !anchor.completed
            motion.canComplete = anchor.canComplete
            motion.begin(width: anchor.bounds.width, initialOffset: previous)
        }
        if abandonedSequence {
            if sample.phase == .end || sample.phase == .cancel { abandonedSequence = false }
            return true
        }
        guard isAvailable(), let candidate, candidate.window === window, anchors[candidate.id]?.view === candidate, !candidate.visibleBounds.isEmpty else {
            let owned = motion.stage == .tracking
            cancel(); return owned
        }
        if sample.phase == .cancel {
            let owned = motion.stage == .tracking; cancel(); abandonedSequence = false; return owned
        }
        if sample.phase == .begin || sample.phase == .change {
            guard sample.dx.isFinite, sample.dy.isFinite else { let owned = motion.stage == .tracking; cancel(); return owned }
            let consumed = motion.move(dx: sample.dx, dy: sample.dy)
            if motion.stage == .rejected {
                // Preserve the native vertical sequence and close any previously revealed row.
                dispatch = nil; self.candidate = nil; surface = nil
            }
            return consumed
        }
        if sample.phase == .end {
            _ = motion.move(dx: sample.dx, dy: sample.dy)
            let owned = motion.stage == .tracking
            let action = motion.finish()
            suppressMomentum = owned
            if let action, let command = RowGestureCommand(action) {
                let callback = dispatch
                dispatch = nil; self.candidate = nil; surface = nil
                callback?(command)
            } else if motion.stage != .open { dispatch = nil; self.candidate = nil; surface = nil }
            return owned
        }
        return false
    }
    func perform(_ command: RowGestureCommand, on id: UUID) {
        guard surface == id, motion.stage == .open, anchors[id]?.view != nil, isAvailable() else { return }
        let callback = dispatch
        cancel() // Revoke before delivery, including a queued second button activation.
        callback?(command)
    }
}

struct MacSwipeAnchor: NSViewRepresentable {
    let id: UUID
    let controller: MacRowSwipeController
    let prepare: () -> ((RowGestureCommand) -> Void)?
    let completed: Bool
    var canComplete = true
    func makeNSView(context: Context) -> View { View(id: id, controller: controller, completed: completed, canComplete: canComplete, prepare: prepare) }
    func updateNSView(_ view: View, context: Context) { view.prepare = prepare; view.completed = completed; view.canComplete = canComplete }
    static func dismantleNSView(_ view: View, coordinator: ()) { view.controller?.unregister(view) }
    final class View: NSView {
        let id: UUID
        weak var controller: MacRowSwipeController?
        var prepare: () -> ((RowGestureCommand) -> Void)?
        var completed: Bool
        var canComplete: Bool
        var visibleBounds: NSRect { bounds.intersection(visibleRect) }
        init(id: UUID, controller: MacRowSwipeController, completed: Bool = false, canComplete: Bool = true, prepare: @escaping () -> ((RowGestureCommand) -> Void)?) {
            self.id = id; self.controller = controller; self.completed = completed; self.canComplete = canComplete; self.prepare = prepare
            super.init(frame: .zero); setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { controller?.register(self) } else { controller?.unregister(self) }
        }
    }
}

struct MacSwipeEventHost: NSViewRepresentable {
    let controller: MacRowSwipeController
    func makeNSView(context: Context) -> Host { Host(controller: controller) }
    func updateNSView(_ view: Host, context: Context) { }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.disconnect() }
    final class Host: NSView {
        let controller: MacRowSwipeController
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        init(controller: MacRowSwipeController) { self.controller = controller; super.init(frame: .zero); setAccessibilityElement(false) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); disconnect()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .leftMouseDragged]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
                return consumed ? nil : event
            }
            for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject), (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak controller] _ in MainActor.assumeIsolated { controller?.cancel() } })
            }
        }
        func disconnect() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            // May be called during a SwiftUI update; revoke through the anchor's teardown.
            if controller.surface != nil { controller.revokeAfterUpdate() }
        }
        private func consume(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            if event.type != .scrollWheel {
                if event.type == .leftMouseDown && controller.motion.stage == .open {
                    if controller.actionsContain(event.locationInWindow, window: window) { return false }
                    controller.cancel()
                    // Consume a click on shifted row content before restoring its hit targets.
                    return bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil))
                }
                let wasOpen = controller.surface != nil
                controller.cancel()
                return event.type == .keyDown && event.keyCode == 53 && wasOpen
            }
            guard window.isKeyWindow, NSApp.isActive, NSEvent.pressedMouseButtons == 0,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  event.hasPreciseScrollingDeltas else { controller.cancel(); return false }
            let phase: MacSwipeSample.Phase
            if event.momentumPhase != [] { phase = .momentum }
            else if event.phase.contains(.cancelled) { phase = .cancel }
            else if event.phase.contains(.began) || event.phase.contains(.mayBegin) { phase = .begin }
            else if event.phase.contains(.ended) { phase = .end }
            else if event.phase.contains(.changed) { phase = .change }
            else { controller.cancel(); return false }
            if phase == .begin && !bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil)) { controller.cancel(); return false }
            // NSEvent already applies the scrolling preference. These controls follow the
            // finger rather than a scroll-bar direction, regardless of Natural Scrolling.
            let direction = event.isDirectionInvertedFromDevice ? 1.0 : -1.0
            let sample = MacSwipeSample(phase: phase, dx: event.scrollingDeltaX * direction, dy: event.scrollingDeltaY, momentumEnded: event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled))
            return controller.route(sample, at: event.locationInWindow, window: window)
        }
    }
}

struct MacSwipeRow<Content: View>: View {
    let controller: MacRowSwipeController
    let completed: Bool
    var canComplete = true
    let selected: Bool
    let prepare: () -> ((RowGestureCommand) -> Void)?
    @ViewBuilder var content: Content
    @State private var id = UUID() // Distinct surfaces even for repeated saved-query results.
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.taskListFocused) private var listFocused
    private var background: Color {
        selected ? Color(nsColor: appearsActive && listFocused ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor) : Color(nsColor: .textBackgroundColor)
    }
    var body: some View {
        let offset = controller.offset(for: id)
        let logical = controller.surface == id ? controller.motion.offset : 0
        ZStack {
            if logical != 0 {
                HStack(spacing: 0) {
                    if logical > 0 { primary(controller.motion.leading, width: max(abs(offset), RowGestureMotion.leadingWidth)); Spacer(minLength: 0) }
                    else {
                        Spacer(minLength: 0)
                        if controller.motion.armed { primary(controller.motion.trailing, width: abs(offset)) }
                        else {
                            actionButton("Delete", symbol: "trash", color: Color(red: 0.68, green: 0.14, blue: 0.2), width: RowGestureMotion.trailingWidth / 2, command: .delete)
                            primary(controller.motion.trailing, width: RowGestureMotion.trailingWidth / 2)
                        }
                    }
                }
            }
            content
                .background { if logical != 0 { background } }
                .offset(x: logical)
        }
        .clipShape(.rect(cornerRadius: 6))
        .background(MacSwipeAnchor(id: id, controller: controller, prepare: prepare, completed: completed, canComplete: canComplete))
    }
    @ViewBuilder private func primary(_ action: RowGestureAction, width: CGFloat) -> some View {
        switch action {
        case .complete: actionButton(completed ? "Reopen" : "Complete", symbol: completed ? "arrow.uturn.backward" : "checkmark", color: Color(red: 0.12, green: 0.45, blue: 0.28), width: width, command: .complete)
        case .tomorrow: actionButton("Tomorrow", symbol: "sunrise", color: Color(red: 0.6, green: 0.32, blue: 0.04), width: width, command: .tomorrow)
        case .edit: actionButton("Edit", symbol: "pencil", color: Color(red: 0.12, green: 0.35, blue: 0.68), width: width, command: .edit)
        case .none: EmptyView()
        }
    }
    private func actionButton(_ title: String, symbol: String, color: Color, width: CGFloat, command: RowGestureCommand) -> some View {
        Button { controller.perform(command, on: id) } label: {
            Label(title, systemImage: symbol).font(.callout.weight(.medium)).lineLimit(2)
                .frame(width: width).frame(maxHeight: .infinity).background(color).foregroundStyle(.white).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}


struct MacSwipeSettings: View {
    @AppStorage("mac.rowGesture.leading") private var leading = "complete"
    @AppStorage("mac.rowGesture.trailing") private var trailing = "tomorrow"
    @AppStorage("mac.rowGesture.fullSwipe") private var fullSwipe = false
    @Environment(\.layoutDirection) private var direction
    var body: some View {
        Form {
            Section("Task list swipes") {
                picker(direction == .rightToLeft ? "Swipe left" : "Swipe right", edge: "leading", selection: $leading)
                picker(direction == .rightToLeft ? "Swipe right" : "Swipe left", edge: "trailing", selection: $trailing)
                Toggle("Full swipe to act", isOn: $fullSwipe).accessibilityIdentifier("rowGestureFullSwipe")
                Text("Use two fingers on your trackpad to reveal actions. Full swipes can complete, reopen or move an open task to tomorrow. Edit and Delete always need a click.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore default swipe actions") { leading = "complete"; trailing = "tomorrow"; fullSwipe = false }
                Text("Choosing None hides that direction’s actions. Task menus and keyboard controls remain available. These preferences apply only to this Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func picker(_ title: String, edge: String, selection: Binding<String>) -> some View {
        Picker(title, selection: Binding(get: { RowGestureAction(rawValue: selection.wrappedValue)?.rawValue ?? "none" }, set: { selection.wrappedValue = $0 })) {
            ForEach(RowGestureAction.allCases) { Text($0.title).tag($0.rawValue) }
        }.accessibilityIdentifier("rowGesture-" + edge)
    }
}
