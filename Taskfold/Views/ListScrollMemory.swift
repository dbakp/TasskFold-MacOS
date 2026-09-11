import SwiftUI
import AppKit

struct ListScrollBookmark {
    var taskID: String?
    var nextID: String?
    var relativeY: CGFloat
    var fallbackY: CGFloat
}

@MainActor final class ListNativeHandle {
    weak var table: NSTableView?
    var ready: (() -> Void)?
}

/// Identifies realized rows without changing native selection or drag gestures.
struct ListScrollRowMarker: NSViewRepresentable {
    let id: String
    let handle: ListNativeHandle
    func makeNSView(context: Context) -> Marker { Marker(id: id, handle: handle) }
    func updateNSView(_ view: Marker, context: Context) { view.taskID = id }
    final class Marker: NSView {
        var taskID: String
        let handle: ListNativeHandle
        init(id: String, handle: ListNativeHandle) { taskID = id; self.handle = handle; super.init(frame: .zero) }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        private func connect() {
            var parent = superview
            while let view = parent {
                if let table = view as? NSTableView {
                    if handle.table !== table { handle.table = table; handle.ready?() }
                    return
                }
                parent = view.superview
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Preserve a visible task while AppKit replaces estimated row heights with measurements.
/// The anchor remains active through layout changes until the user scrolls or selects a row.
struct ListScrollMemory: NSViewRepresentable {
    let key: String
    let workspace: Workspace
    let taskIDs: [String]
    let handle: ListNativeHandle
    func makeNSView(context: Context) -> Probe { Probe(key: key, workspace: workspace, ids: taskIDs, handle: handle) }
    func updateNSView(_ view: Probe, context: Context) { view.updateIDs(taskIDs); view.connectWhenReady() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.disconnect() }

    final class Probe: NSView {
        let key: String
        let handle: ListNativeHandle
        weak var workspace: Workspace?
        var taskIDs: [String]
        private weak var scrollView: NSScrollView?
        private weak var table: NSTableView?
        private var observers: [NSObjectProtocol] = []
        private var eventMonitor: Any?
        private var scheduled = false
        private var restoreScheduled = false
        private var restoring = false
        private var detached = false
        private var bookmark: ListScrollBookmark?
        private var holdingAnchor: Bool
        private var restoreGeneration = 0
        init(key: String, workspace: Workspace, ids: [String], handle: ListNativeHandle) {
            self.key = key; self.workspace = workspace; self.handle = handle; taskIDs = ids
            bookmark = workspace.scrollBookmarks[key]; holdingAnchor = bookmark != nil
            super.init(frame: .zero)
            handle.ready = { [weak self] in self?.connectWhenReady() }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connectWhenReady() }
        override func layout() { super.layout(); connectWhenReady() }
        func updateIDs(_ ids: [String]) {
            guard ids != taskIDs else { return }
            taskIDs = ids
            guard scrollView != nil, !detached else { return }
            bookmark = workspace?.scrollBookmarks[key]
            if restoreID == nil { bookmark = nil }
            holdingAnchor = bookmark != nil
            restoreGeneration += 1
            scheduleRestore()
        }
        func connectWhenReady() {
            guard !detached, scrollView == nil, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false; self.connect()
            }
        }
        private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            if let match = view as? T { return [match] }
            return view.subviews.flatMap { descendants(type, in: $0) }
        }
        private func connect() {
            guard !detached, scrollView == nil, window != nil, bounds.width > 0, bounds.height > 0 else { return }
            guard let table = handle.table, let scroll = table.enclosingScrollView else { return }
            self.table = table; scrollView = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            table.postsFrameChangedNotifications = true
            for (name, object) in [(NSView.boundsDidChangeNotification, scroll.contentView as NSView), (NSView.frameDidChangeNotification, table as NSView)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.restoring else { return }
                        if self.holdingAnchor { self.scheduleRestore() } else if name == NSView.boundsDidChangeNotification { self.remember() }
                    }
                })
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.userWillInteract(event) }
                return event
            }
            restoring = true
            if let bookmark { setOffset(bookmark.fallbackY) }
            restoring = false
            scheduleRestore()
        }
        private func userWillInteract(_ event: NSEvent) {
            guard let scroll = scrollView, event.window == window else { return }
            let inside = scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
            let navigationKey = event.type == .keyDown && [123, 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode)
            if (event.type != .keyDown && inside) || navigationKey {
                restoreGeneration += 1; holdingAnchor = false
                remember()
            }
        }
        private var restoreID: String? {
            [bookmark?.taskID, bookmark?.nextID].compactMap { $0 }.first { taskIDs.contains($0) }
        }
        private func scheduleRestore(attempt: Int = 0) {
            guard !detached, !restoreScheduled else { return }
            restoreScheduled = true
            let generation = restoreGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self else { return }
                self.restoreScheduled = false
                guard !self.detached, let scroll = self.scrollView, let table = self.table else { return }
                guard generation == self.restoreGeneration else {
                    if self.holdingAnchor { self.scheduleRestore() }
                    return
                }
                self.restoring = true
                scroll.layoutSubtreeIfNeeded()
                let marker = self.restoreID.flatMap { id in self.descendants(ListScrollRowMarker.Marker.self, in: table).first { $0.taskID == id } }
                if let marker {
                    self.setOffset(marker.convert(marker.bounds, to: scroll.contentView.documentView).minY - (self.bookmark?.relativeY ?? 0))
                } else if let id = self.restoreID {
                    self.reveal(id, in: table)
                } else { self.setOffset(0) }
                self.restoring = false
                if self.restoreID != nil && marker == nil {
                    if attempt < 6 { self.scheduleRestore(attempt: attempt + 1) }
                } else { self.remember(force: true) }
            }
        }
        /// Reveal the saved task using native row indices before applying its pixel offset.
        /// The nearest realized task accounts for section headers without assuming fixed heights.
        private func reveal(_ id: String, in table: NSTableView) {
            guard let targetIndex = taskIDs.firstIndex(of: id), table.numberOfRows > 0 else { return }
            let candidates = descendants(ListScrollRowMarker.Marker.self, in: table).compactMap { marker -> (Int, Int)? in
                let row = table.row(for: marker)
                guard row >= 0, let index = taskIDs.firstIndex(of: marker.taskID) else { return nil }
                return (index, row)
            }
            guard let nearest = candidates.min(by: { abs($0.0 - targetIndex) < abs($1.0 - targetIndex) }) else { return }
            let row = min(max(nearest.1 + targetIndex - nearest.0, 0), table.numberOfRows - 1)
            table.scrollRowToVisible(row)
        }
        private func setOffset(_ y: CGFloat) {
            guard let scroll = scrollView else { return }
            let clip = scroll.contentView
            var proposed = clip.bounds; proposed.origin.y = y
            let point = clip.constrainBoundsRect(proposed).origin
            if abs(point.y - clip.bounds.origin.y) > 0.5 {
                clip.scroll(to: point); scroll.reflectScrolledClipView(clip)
            }
        }
        private func remember(force: Bool = false) {
            guard !restoring, !detached, let workspace, workspace.section.scope?.preferenceKey == key,
                  let scroll = scrollView, let table else { return }
            let visible = scroll.contentView.bounds
            // Outgoing SwiftUI lists can discard measured heights without scrolling.
            // That must not replace the last user-visible anchor with estimated rows.
            if !force, let saved = workspace.scrollBookmarks[key], abs(saved.fallbackY - visible.minY) <= 0.5 { return }
            let markers = descendants(ListScrollRowMarker.Marker.self, in: table).map { marker in
                (marker.taskID, marker.convert(marker.bounds, to: scroll.contentView.documentView))
            }.filter { $0.1.maxY > visible.minY && $0.1.minY < visible.maxY }.sorted { $0.1.minY < $1.1.minY }
            workspace.scrollBookmarks[key] = ListScrollBookmark(taskID: markers.first?.0, nextID: markers.dropFirst().first?.0,
                relativeY: (markers.first?.1.minY ?? visible.minY) - visible.minY, fallbackY: max(0, visible.minY))
        }
        func disconnect() {
            remember(); detached = true
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            handle.ready = nil
            eventMonitor = nil; scrollView = nil
        }
    }
}
