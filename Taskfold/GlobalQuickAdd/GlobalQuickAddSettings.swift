import SwiftUI
import AppKit
import ServiceManagement

/// Settings > General: the global shortcut recorder, "Show in menu bar" and "Open at login".
struct GlobalQuickAddSettings: View {
    static let menuBarKey = "showInMenuBar"
    static let menuBarTitleKey = "showMenuBarTitle"
    @AppStorage(GlobalQuickAddSettings.menuBarKey) private var showInMenuBar = true
    @AppStorage(GlobalQuickAddSettings.menuBarTitleKey) private var showMenuBarTitle = false
    private let controller = GlobalQuickAddController.shared
    @State private var login = LaunchAtLogin()

    var body: some View {
        Section("Quick Add") {
            LabeledContent("Quick Add from anywhere") {
                HStack(spacing: DS.Space.s) {
                    QuickAddShortcutRecorder(controller: controller)
                    Button("Clear") { controller.clearShortcut() }.disabled(controller.shortcut == nil).accessibilityIdentifier("clearQuickAddShortcut")
                }
            }
            if let message = controller.message {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(DS.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("quickAddShortcutConflict")
            } else {
                HStack {
                    Text(controller.shortcut == nil ? "No shortcut set. Click the field and press a combination such as ⌃⌥Space."
                         : "Press it in any app to add a task without switching to Taskfold.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if controller.shortcut != QuickAddShortcut.default { Button("Reset to ⌃⌥Space") { controller.resetShortcut() }.buttonStyle(.link).font(.caption) }
                }
            }
            Toggle("Show in menu bar", isOn: $showInMenuBar).accessibilityIdentifier("showInMenuBar")
            Toggle("Show current task in menu bar", isOn: $showMenuBarTitle).disabled(!showInMenuBar)
                .accessibilityIdentifier("showMenuBarTitle")
            Text("Adds a short title next to the icon, such as “▸ Write report · 18m” during Focus, or your next timed task.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Open at login", isOn: Binding(get: { login.isOn }, set: { login.set($0) })).accessibilityIdentifier("openAtLogin")
            if let line = login.statusLine {
                HStack {
                    Text(line).font(.caption).foregroundStyle(login.error == nil ? Color.secondary : DS.Palette.danger).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if login.status == .requiresApproval { Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.link).font(.caption) }
                }
                .accessibilityIdentifier("openAtLoginStatus")
            }
        }
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }
}

/// `SMAppService.mainApp`: register or unregister Taskfold as a login item and report what macOS says.
struct LaunchAtLogin {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var statusLine: String? {
        if let error { return error }
        switch status {
        case .enabled: return "Taskfold opens when you log in."
        case .requiresApproval: return "Waiting for approval: allow Taskfold in System Settings > General > Login Items."
        case .notFound: return "Opening at login is not available for this build."
        default: return nil
        }
    }
    mutating func refresh() { status = SMAppService.mainApp.status }
    mutating func set(_ on: Bool) {
        error = nil
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { self.error = "macOS could not change this setting: \(error.localizedDescription)" }
        refresh()
    }
}

/// A click-to-record shortcut field. While recording, the next key combination is captured (Esc cancels, Delete clears).
struct QuickAddShortcutRecorder: View {
    let controller: GlobalQuickAddController
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Text(recording ? "Type shortcut…" : (controller.shortcut?.displayString ?? "Not set"))
                .font(.body.monospacedDigit()).foregroundStyle(recording ? Color.taskfold : controller.shortcut == nil ? DS.Palette.textTertiary : DS.Palette.textPrimary)
                .frame(minWidth: 112).padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
                .background(DS.Palette.surfaceSunken, in: .rect(cornerRadius: DS.Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).strokeBorder(Color.taskfold.opacity(recording ? 0.7 : 0), lineWidth: 1.5))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Click, then press the shortcut you want").accessibilityLabel("Quick Add shortcut")
        .accessibilityValue(controller.shortcut?.displayString ?? "Not set").accessibilityIdentifier("quickAddShortcutRecorder")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 { stop(); return nil } // Esc cancels
            if event.keyCode == 51, flags.intersection([.command, .control, .option, .shift]).isEmpty { controller.clearShortcut(); stop(); return nil }
            controller.apply(QuickAddShortcut(keyCode: event.keyCode, flags: flags))
            stop()
            return nil
        }
    }
    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
