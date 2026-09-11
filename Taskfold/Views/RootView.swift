import SwiftUI
import AppKit

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var phase
    @State private var seeded = false
    var body: some View {
        @Bindable var store = store
        Group {
            if store.signedIn { WorkspaceView().transition(.opacity) }
            else { AuthView().transition(.opacity) }
        }
        .animation(Motion.respecting(reduceMotion, Motion.layout), value: store.signedIn)
        .onAppear { workspace.reduceMotion = reduceMotion; workspace.undoManager = undoManager; seed() }
        .onChange(of: store.userID) { _, _ in workspace.clearNavigationMemory(); workspace.section = .today }
        .onChange(of: store.signedIn) { _, signedIn in if !signedIn { workspace.clearNavigationMemory() } }
        .onChange(of: reduceMotion) { _, value in workspace.reduceMotion = value }
        .onChange(of: undoManager) { _, value in workspace.undoManager = value }
        .alert("Something needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .task(id: "refresh-\(store.signedIn)") {
            guard store.signedIn else { return }
            await store.reschedule()
            await store.sync()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await store.sync()
            }
        }
        .task(id: "realtime-\(store.signedIn)-\(store.localMode)") {
            guard store.signedIn, !store.localMode else { return }
            while !Task.isCancelled {
                do { try await store.backend.watchChanges { await store.sync() } }
                catch { if Task.isCancelled { return } }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: "reminder-\(NotificationRoute.shared.taskID ?? "")-\(store.taskRevision)") {
            guard let id = NotificationRoute.shared.taskID else { return }
            await Task.yield()
            guard !Task.isCancelled, store.record("tasks", id: id) != nil else { return }
            workspace.open(id)
            NotificationRoute.shared.taskID = nil
        }
        .onOpenURL { url in
            if url.scheme == "taskfold" && url.host == "task", store.record("tasks", id: url.lastPathComponent) != nil { workspace.open(url.lastPathComponent) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in Task { await store.reschedule() } }
    }

    /// Debug-only fixtures shared with the UI tests. Release builds ignore these arguments.
    private func seed() {
        guard !seeded else { return }; seeded = true
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        // Debug options use --key=value so AppKit never mistakes a bare value for a document to open.
        func option(_ key: String) -> String? { arguments.first { $0.hasPrefix("--\(key)=") }.map { String($0.dropFirst(key.count + 3)) } }
        if let value = option("section") { workspace.section = SidebarItem(key: value) }
        if arguments.contains("--preview") { Task { try? await Task.sleep(for: .milliseconds(400)); NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: 1380, height: 840)) } }
        if let value = option("calendar-mode"), let mode = CalendarMode(rawValue: value) { workspace.calendarMode = mode }
        if let value = option("appearance") { NSApp.appearance = NSAppearance(named: value == "dark" ? .darkAqua : .aqua) }
        if let title = option("select-title") {
            Task { try? await Task.sleep(for: .seconds(1)); if let task = store.tasks.first(where: { $0.title == title }) { workspace.selection = [task.id] } }
        }
        if let path = option("capture") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                    window.setContentSize(NSSize(width: 1280, height: 800))
                    window.center(); window.orderBack(nil)
                    window.layoutIfNeeded(); window.displayIfNeeded()
                    try? await Task.sleep(for: .seconds(1.5))
                    // Report capture without screen-recording permission: cache-display the window, then repaint every
                    // visual-effect region (whose backdrop cannot be rendered offscreen) with a solid background and its
                    // own subviews. Sandboxed, so the PNG lands in the container's temporary directory.
                    if let frame = window.contentView?.superview, let png = DebugCapture.image(of: frame).tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:]) {
                        try? png.write(to: FileManager.default.temporaryDirectory.appending(path: path))
                    }
                }
                NSApp.terminate(nil)
            }
        }
        if arguments.contains("--uitesting") {
            store.startLocal()
            workspace.section = .today
            workspace.inspectorShown = true
            if arguments.contains("--day-drag-fixture") {
                store.snapshot = Snapshot()
                store.snapshot.tables["tasks"] = [(-1, "Overdue sample"), (0, "Today first"), (0, "Today last"), (1, "Tomorrow sample")].enumerated().map { index, sample in
                    var task = Record.task(user: store.userID, date: Calendar.current.date(byAdding: .day, value: sample.0, to: Date())!)
                    task["id"] = .string("drag-fixture-\(index)")
                    task["title"] = .string(sample.1)
                    return task
                }
                try? store.persist()
            }
        }
        if arguments.contains("--priority-fixture") {
            store.startLocal(); store.snapshot = Snapshot()
            UserDefaults.standard.set("manual", forKey: "mac.view.today.sortBy")
            store.snapshot.tables["tasks"] = [("P1 alpha", 1), ("P1 beta", 1), ("P3 gamma", 3), ("P3 delta", 3)].enumerated().map { index, sample in
                var task = Record.task(user: store.userID, date: Date())
                task["id"] = .string("band-\(index)"); task["title"] = .string(sample.0); task["priority"] = .number(Double(sample.1))
                return task
            }
            try? store.persist()
        }
        if arguments.contains("--navigation-fixture") {
            store.startLocal(); store.snapshot = Snapshot()
            for scope in ["today", "inbox", "all", "completed"] {
                UserDefaults.standard.set(false, forKey: "mac.view.\(scope).showCompleted")
                UserDefaults.standard.set(0, forKey: "mac.view.\(scope).priorityFilter")
                UserDefaults.standard.set("title", forKey: "mac.view.\(scope).sortBy")
            }
            store.snapshot.tables["projects"] = [Record(["id": .string("nav-project"), "name": .string("Navigation Studio"), "user_id": .string(store.userID)])]
            store.snapshot.tables["tasks"] = (0..<160).map { index in
                var task = Record.task(user: store.userID, date: Date())
                task["id"] = .string("nav-\(index)")
                task["title"] = .string(String(format: "Navigation task %03d", index))
                task["priority"] = .number(index % 2 == 0 ? 1 : 4)
                return task
            }
            var archived = Record.task(user: store.userID, project: "nav-project", date: Date())
            archived["id"] = .string("nav-archived")
            archived["title"] = .string("Archived navigation target")
            archived["completed"] = .bool(true)
            store.snapshot.tables["tasks", default: []].append(archived)
            try? store.persist()
        }
        if arguments.contains("--preview") {
            store.startLocal(); store.snapshot = Snapshot()
            let focus = Record(["id": .string("preview-project"), "name": .string("A little more focus"), "user_id": .string("preview"), "color": .string("#e31e4b"), "order_index": .number(0)])
            let home = Record(["id": .string("preview-home"), "name": .string("Home"), "user_id": .string("preview"), "color": .string("#3b82f6"), "order_index": .number(1)])
            store.snapshot.tables["projects"] = [focus, home]
            store.snapshot.tables["labels"] = [Record(["id": .string("preview-label"), "user_id": .string("preview"), "name": .string("deep work"), "color": .string("#8b5cf6")])]
            var samples: [Record] = []
            let calendar = Calendar.current
            let plan: [(Int, String, Int, String, String)] = [
                (-1, "Send the revised proposal", 1, focus.id, ""),
                (0, "Make time for the big idea", 1, focus.id, "10:00"),
                (0, "Sketch the next chapter", 2, focus.id, ""),
                (0, "A walk, without the phone", 3, "", ""),
                (0, "Plan something worth looking forward to", 4, home.id, ""),
                (1, "Review the onboarding flow", 2, focus.id, "14:00"),
                (1, "Book the dentist", 4, home.id, ""),
                (2, "Write the release notes", 2, focus.id, ""),
                (3, "Water the plants", 4, home.id, ""),
                (4, "Quarterly reflection", 3, focus.id, "09:00"),
                (6, "Call Grandma", 2, home.id, ""),
                (9, "Draft the talk outline", 2, focus.id, ""),
            ]
            for (i, entry) in plan.enumerated() {
                var task = Record.task(user: "preview", project: entry.3, date: calendar.date(byAdding: .day, value: entry.0, to: Date()))
                task["title"] = .string(entry.1); task["priority"] = .number(Double(entry.2))
                if !entry.4.isEmpty { task["due_time"] = .string(entry.4) }
                if i == 1 { task["description"] = .string("An hour of focus. A little room to think."); task["labels"] = .array([.string("deep work")]); task["subtasks"] = .array([.object(["id": .string("s1"), "title": .string("Clear the desk"), "completed": .bool(true)]), .object(["id": .string("s2"), "title": .string("Open the notebook"), "completed": .bool(false)])]) }
                if i == 8 { task["is_recurring"] = .bool(true); task["recurrence_pattern"] = .object(["type": .string("weekly"), "interval": .number(1), "daysOfWeek": .array([.number(6)])]) }
                samples.append(task)
            }
            var inbox = Record.task(user: "preview"); inbox["title"] = .string("Read that article about slow productivity"); samples.append(inbox)
            store.snapshot.tables["tasks"] = samples
        }
        #endif
    }
}

/// Sidebar ▸ content list ▸ inspector. The inspector is a real trailing column, not a sheet.
struct WorkspaceView: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @State private var columns = NavigationSplitViewVisibility.all
    var body: some View {
        @Bindable var workspace = workspace
        GeometryReader { window in
            NavigationSplitView(columnVisibility: $columns) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
            } detail: {
                Group {
                    if workspace.section == .calendar {
                        // Use the window budget, including space for the expanded sidebar, so
                        // toggling it cannot trigger a second calendar layout mid-transition.
                        CalendarView(showsDayPanel: window.size.width >= (workspace.inspectorVisible ? 1550 : 1240))
                    }
                    else { TaskListView(scope: workspace.scope) }
                }
                .id(workspace.section)
                .inspector(isPresented: Binding(get: { workspace.inspectorVisible }, set: { shown in
                    // Automatic hiding for an empty selection is not a user preference change.
                    if !workspace.actionSelection.isEmpty { workspace.inspectorShown = shown }
                })) {
                    TaskInspector()
                        .inspectorColumnWidth(min: 270, ideal: 310, max: 460)
                }
            }
            .navigationSplitViewStyle(.prominentDetail)
            .navigationTitle(workspace.navigationTitle)
            .navigationSubtitle(workspace.navigationSubtitle)
        }
        .sheet(isPresented: $workspace.finderPresented, onDismiss: { workspace.finishFinderDismissal() }) { FinderView() }
        .modifier(KeyRouter())
        .accessibilityIdentifier("nativeWorkspace")
    }
}

#if DEBUG
enum DebugCapture {
    /// Cache-displays the window frame, then repaints each visual-effect region with a solid background and
    /// its own subviews, because material backdrops cannot be rendered offscreen.
    @MainActor static func image(of root: NSView) -> NSImage {
        let image = NSImage(size: root.bounds.size)
        guard let layer = root.layer else { return image }
        // Material backdrop layers sample what is behind the window, which does not exist offscreen and renders as
        // noise; hide them and render the Core Animation tree, which includes vibrant content that view caching skips.
        for effect in allEffects(under: root) { effect.material = .windowBackground; effect.state = .inactive; effect.blendingMode = .withinWindow }
        hideBackdrops(layer)
        root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
        let scale = root.window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width * scale), pixelsHigh: Int(root.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        rep.size = root.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor.windowBackgroundColor.setFill(); root.bounds.fill()
        layer.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }
    private static func allEffects(under view: NSView) -> [NSVisualEffectView] {
        view.subviews.flatMap { (($0 as? NSVisualEffectView).map { [$0] } ?? []) + allEffects(under: $0) }
    }
    private static func hideBackdrops(_ layer: CALayer) {
        if String(describing: type(of: layer)).contains("Backdrop") { layer.isHidden = true }
        layer.sublayers?.forEach(hideBackdrops)
    }
    /// Rect of `view` in the (unflipped) bitmap coordinate space of `root`.
    private static func rect(of view: NSView, in root: NSView) -> NSRect {
        var r = root.convert(view.bounds, from: view)
        if root.isFlipped { r.origin.y = root.bounds.height - r.origin.y - r.height }
        return r
    }
    @MainActor private static func paint(_ view: NSView, root: NSView) {
        guard !view.isHidden, view.alphaValue > 0 else { return }
        let target = rect(of: view, in: root)
        if view is NSVisualEffectView {
            NSColor.windowBackgroundColor.setFill(); target.fill()
            for sub in view.subviews { paint(sub, root: root) }
            return
        }
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size); image.addRepresentation(rep)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        for effect in topEffects(under: view) { paint(effect, root: root) }
    }
    private static func topEffects(under view: NSView) -> [NSView] {
        view.subviews.flatMap { $0 is NSVisualEffectView ? [$0] : topEffects(under: $0) }
    }
}
#endif
