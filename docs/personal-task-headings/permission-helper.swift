import AppKit
import Network
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var browser: NWBrowser?
    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Taskfold Network Permission Test"
        let explanation = NSTextField(wrappingLabelWithString: "Disposable permission check. No Taskfold tasks or accounts are loaded. Choose Don’t Allow when macOS asks about local-network access.")
        explanation.frame = NSRect(x: 24, y: 82, width: 432, height: 80)
        let button = NSButton(title: "Request Local Network", target: self, action: #selector(requestPermission))
        button.frame = NSRect(x: 125, y: 25, width: 230, height: 34)
        window.contentView!.addSubview(explanation); window.contentView!.addSubview(button)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func requestPermission() {
        guard browser == nil else { return }
        browser = NWBrowser(for: .bonjour(type: "_taskfold-privacy-test._tcp", domain: nil), using: .tcp)
        browser!.start(queue: DispatchQueue(label: "taskfold.disposable.permission"))
    }
    func applicationWillTerminate(_ note: Notification) { browser?.cancel() }
}
let app = NSApplication.shared
let delegate = Delegate(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
