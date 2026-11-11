import AppKit
import Carbon.HIToolbox

/// Registers one system-wide hot key with Carbon `RegisterEventHotKey`. It works in the App Sandbox, needs no
/// Accessibility permission and fires while Taskfold is in the background or has no windows open.
@MainActor
final class GlobalHotKey {
    enum Failure: Equatable {
        case taken            // eventHotKeyExistsErr: another app or macOS owns the chord
        case system(OSStatus)
        var message: String {
            switch self {
            case .taken: return "Another app or macOS already uses this shortcut. Choose a different one."
            case .system(let status): return "macOS could not register this shortcut (error \(status)). Choose a different one."
            }
        }
    }

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x54464B51 // 'TFKQ'
    private let action: @MainActor () -> Void
    private(set) var registered: QuickAddShortcut?

    init(action: @escaping @MainActor () -> Void) { self.action = action }

    /// Replaces the current registration. On failure the previous chord stays registered.
    @discardableResult
    func register(_ shortcut: QuickAddShortcut) -> Failure? {
        installHandlerIfNeeded()
        var next: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: signature, id: 1),
                                         GetApplicationEventTarget(), 0, &next)
        guard status == noErr, let next else { return status == eventHotKeyExistsErr ? .taken : .system(status) }
        if let reference { UnregisterEventHotKey(reference) }
        reference = next
        registered = shortcut
        return nil
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        registered = nil
    }

    func tearDown() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let box = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let event, let user else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(user).takeUnretainedValue()
            guard id.signature == owner.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { owner.action() } }
            return noErr
        }, 1, &spec, box, &handler)
    }
}
