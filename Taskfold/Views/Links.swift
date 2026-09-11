import SwiftUI
import AppKit
import LinkPresentation

/// Finds web links in free text (with or without a scheme) and shows them by page title, the way the iOS app does.
enum Linkify {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    struct Match: Equatable {
        var range: Range<String.Index>
        var url: URL
    }
    static func links(in text: String) -> [Match] {
        guard let detector, !text.isEmpty, text.contains(".") else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let url = result.url, let range = Range(result.range, in: text) else { return nil }
            let scheme = url.scheme?.lowercased() ?? ""
            guard scheme == "http" || scheme == "https" || scheme.isEmpty else { return nil }
            let fixed = scheme.isEmpty ? URL(string: "https://" + url.absoluteString) ?? url : url
            return Match(range: range, url: fixed)
        }
    }
    static func urls(in text: String) -> [URL] {
        var seen = Set<String>()
        return links(in: text).map(\.url).filter { seen.insert($0.absoluteString).inserted }
    }
    static func host(_ url: URL) -> String { (url.host() ?? url.absoluteString).replacingOccurrences(of: "www.", with: "") }
    /// A compact stand-in while the page title loads: the host without "www.", plus the last path piece.
    static func shortLabel(_ url: URL) -> String {
        let last = url.pathComponents.last { $0 != "/" } ?? ""
        return last.isEmpty || last.count > 24 ? host(url) : host(url) + " › " + last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }
}

/// Fetches page titles once with LinkPresentation and caches them in UserDefaults, so tasks read
/// "Apple Design Resources" rather than a URL. Full metadata stays in memory for hover previews.
@MainActor @Observable
final class LinkTitles {
    static let shared = LinkTitles()
    private(set) var titles: [String: String] = (try? JSONDecoder().decode([String: String].self, from: UserDefaults.standard.data(forKey: "linkTitles") ?? Data())) ?? [:]
    @ObservationIgnored private(set) var metadata: [String: LPLinkMetadata] = [:]
    @ObservationIgnored private var inFlight = Set<String>()
    @ObservationIgnored private var failed = Set<String>()
    @ObservationIgnored private var waiters: [String: [(LPLinkMetadata?) -> Void]] = [:]
    /// Returns the cached title, kicking off a fetch the first time a URL is seen.
    func title(for url: URL) -> String? {
        let key = url.absoluteString
        if let title = titles[key] { return title }
        if !inFlight.contains(key) && !failed.contains(key) { fetch(url) }
        return nil
    }
    /// Calls back with rich metadata for a preview, fetching if needed.
    func metadata(for url: URL, completion: @escaping (LPLinkMetadata?) -> Void) {
        let key = url.absoluteString
        if let cached = metadata[key] { completion(cached); return }
        if failed.contains(key) { completion(nil); return }
        waiters[key, default: []].append(completion)
        if !inFlight.contains(key) { fetch(url) }
    }
    private func fetch(_ url: URL) {
        let key = url.absoluteString
        inFlight.insert(key)
        Task {
            let provider = LPMetadataProvider()
            provider.timeout = 8
            let result = try? await provider.startFetchingMetadata(for: url)
            inFlight.remove(key)
            if let result {
                metadata[key] = result
                if let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    titles[key] = title.count > 70 ? String(title.prefix(67)) + "…" : title
                    if titles.count > 400 { titles = Dictionary(uniqueKeysWithValues: Array(titles.suffix(300))) }
                    UserDefaults.standard.set(try? JSONEncoder().encode(titles), forKey: "linkTitles")
                }
            } else { failed.insert(key) }
            let callbacks = waiters.removeValue(forKey: key) ?? []
            for callback in callbacks { callback(result) }
        }
    }
}

/// Opens links in the default browser. Fixture launches record the link instead so tests never leave the app.
@MainActor
enum LinkOpener {
    static var testing: Bool { ProcessInfo.processInfo.arguments.contains("--uitesting") }
    static func open(_ url: URL, workspace: Workspace?, via: String = "click") {
        if testing { workspace?.confirm("Would open \(Linkify.host(url)) via \(via)", undoable: false); return }
        NSWorkspace.shared.open(url)
    }
    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        NSPasteboard.general.setString(url.absoluteString, forType: .URL)
    }
}

/// Text whose links are clickable, hoverable, and right-clickable, without stealing the row's selection click.
/// Backed by an `NSTextView` whose hit test claims only the pointer over a link; everything else passes through
/// to the list, so a click on plain words still selects the row.
struct LinkText: NSViewRepresentable {
    let text: String
    var font: NSFont = .preferredFont(forTextStyle: .body)
    var color: NSColor = .labelColor
    var linkColor: NSColor = .controlAccentColor
    var strikethrough = false
    var lineLimit = 2
    var accessibilityIdentifier: String? = nil
    var accessibilityLabel: String? = nil
    @Environment(Workspace.self) private var workspace

    func makeNSView(context: Context) -> LinkAwareTextView {
        let view = LinkAwareTextView(frame: .zero)
        view.isEditable = false; view.isSelectable = false; view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false; view.isHorizontallyResizable = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setAccessibilityRole(.staticText)
        return view
    }
    func updateNSView(_ view: LinkAwareTextView, context: Context) {
        view.workspace = workspace
        view.textContainer?.maximumNumberOfLines = lineLimit
        view.textContainer?.lineBreakMode = .byTruncatingTail
        view.linkTextAttributes = [.foregroundColor: linkColor, .cursor: NSCursor.pointingHand]
        let content = attributed()
        view.textStorage?.setAttributedString(content)
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        view.setAccessibilityLabel(accessibilityLabel ?? content.string)
        view.setAccessibilityValue(content.string)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LinkAwareTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 10_000
        nsView.textContainer?.containerSize = NSSize(width: width, height: 10_000)
        nsView.layoutManager?.ensureLayout(for: nsView.textContainer!)
        let used = nsView.layoutManager?.usedRect(for: nsView.textContainer!) ?? .zero
        // Hug the text so the element ends where the words end; the row, not this view, fills the width.
        return CGSize(width: min(width, ceil(used.width) + 1), height: ceil(used.height))
    }
    /// Plain runs in `color`; each link run carries its URL and reads as the page title (or the host until it loads).
    private func attributed() -> NSAttributedString {
        let result = NSMutableAttributedString()
        var base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if strikethrough { base[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; base[.strikethroughColor] = NSColor.secondaryLabelColor }
        var cursor = text.startIndex
        for match in Linkify.links(in: text) {
            if match.range.lowerBound > cursor { result.append(NSAttributedString(string: String(text[cursor..<match.range.lowerBound]), attributes: base)) }
            var attributes = base
            attributes[.link] = match.url
            attributes[.foregroundColor] = linkColor
            attributes[.toolTip] = match.url.absoluteString
            result.append(NSAttributedString(string: LinkTitles.shared.title(for: match.url) ?? Linkify.shortLabel(match.url), attributes: attributes))
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex { result.append(NSAttributedString(string: String(text[cursor...]), attributes: base)) }
        return result
    }
}

/// The text view behind `LinkText`: claims clicks only over links, opens them, shows a preview popover on
/// hover, and offers Open, Copy Link, and Share from the context menu.
final class LinkAwareTextView: NSTextView, NSTextViewDelegate {
    weak var workspace: Workspace?
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) { super.init(frame: frameRect, textContainer: container); delegate = self }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); delegate = self }
    required init?(coder: NSCoder) { super.init(coder: coder); delegate = self }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { LinkOpener.open(url, workspace: workspace, via: "delegate") }
        return true
    }
    private var hoverTimer: Timer?
    private var popover: NSPopover?
    private var hoveredLink: URL?
    private var tracking: NSTrackingArea?

    func link(at point: NSPoint) -> URL? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: local, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -1, dy: -2).contains(local) else { return nil }
        return storage.attribute(.link, at: index, effectiveRange: nil) as? URL
    }
    /// The list's table claims every click inside a row before it forwards it, which would select the row
    /// even when the pointer is on a link. A single local monitor sees the click first: over a link it opens
    /// the link and swallows the press and its release; anywhere else it stays out of the way.
    private static var registry = NSHashTable<LinkAwareTextView>.weakObjects()
    private static var monitor: Any?
    private static var swallowRelease = false
    private static func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { event in
            MainActor.assumeIsolated { route(event) }
        }
    }
    @MainActor private static func route(_ event: NSEvent) -> NSEvent? {
        if event.type == .leftMouseUp {
            defer { swallowRelease = false }
            return swallowRelease ? nil : event
        }
        guard let window = event.window else { return event }
        for view in registry.allObjects where view.window == window && !view.isHiddenOrHasHiddenAncestor {
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point), let url = view.link(at: point) else { continue }
            if event.type == .rightMouseDown { view.showMenu(for: url, with: event); return nil }
            view.closePopover()
            swallowRelease = true
            LinkOpener.open(url, workspace: view.workspace, via: "monitor")
            return nil
        }
        return event
    }
    /// Accessibility presses (VoiceOver, automation) reach the text view directly; route them the same way.
    override func accessibilityPerformPress() -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        var found: URL?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, stop in if let url = value as? URL { found = url; stop.pointee = true } }
        guard let found else { return false }
        LinkOpener.open(found, workspace: workspace, via: "accessibility")
        return true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.registry.add(self); Self.installMonitorIfNeeded() } else { Self.registry.remove(self) }
    }
    /// Clicks never target this view directly; the monitor above handles links and the row keeps the rest.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func showMenu(for url: URL, with event: NSEvent) {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Link", action: #selector(openLink(_:)), keyEquivalent: ""); open.representedObject = url; open.target = self
        let copy = NSMenuItem(title: "Copy Link", action: #selector(copyLink(_:)), keyEquivalent: ""); copy.representedObject = url; copy.target = self
        let share = NSMenuItem(title: "Share…", action: #selector(shareLink(_:)), keyEquivalent: ""); share.representedObject = url; share.target = self
        menu.items = [open, copy, NSMenuItem.separator(), share]
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func openLink(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { LinkOpener.open(url, workspace: workspace) } }
    @objc private func copyLink(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { LinkOpener.copy(url); workspace?.confirm("Copied link", undoable: false) } }
    @objc private func shareLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    // MARK: Hover preview

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        let url = link(at: convert(event.locationInWindow, from: nil))
        if url != hoveredLink {
            hoveredLink = url
            hoverTimer?.invalidate(); hoverTimer = nil
            if url == nil { closePopover() }
            else if let url {
                // An intent delay so a passing pointer does not open previews.
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.showPreview(for: url) }
                }
            }
        }
        if url != nil { NSCursor.pointingHand.set() }
    }
    override func mouseExited(with event: NSEvent) {
        hoveredLink = nil; hoverTimer?.invalidate(); hoverTimer = nil
        closePopover()
    }
    private func showPreview(for url: URL) {
        guard hoveredLink == url, window != nil, !LinkOpener.testing else { return }
        LinkTitles.shared.metadata(for: url) { [weak self] metadata in
            guard let self, let metadata, self.hoveredLink == url, self.popover == nil else { return }
            let linkView = LPLinkView(metadata: metadata)
            linkView.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
            let controller = NSViewController(); controller.view = linkView
            let popover = NSPopover()
            popover.contentViewController = controller
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.show(relativeTo: self.bounds, of: self, preferredEdge: .maxY)
            self.popover = popover
        }
    }
    private func closePopover() {
        popover?.performClose(nil); popover = nil
    }
    override func resetCursorRects() {}
    override var acceptsFirstResponder: Bool { false }
}
