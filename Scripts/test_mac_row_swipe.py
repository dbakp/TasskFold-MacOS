#!/usr/bin/env python3
"""Exercise production Mac swipe routing with real AppKit views, without posting input.

Windows stay offscreen; this does not establish physical trackpad or complete app UI
acceptance. Model intents are tested separately against production Core records.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--previews', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
args.previews.mkdir(parents=True, exist_ok=True)
harness = r'''
import SwiftUI
import AppKit

enum Motion {
    static let settle = Animation.linear(duration: 0)
    static func respecting(_ reduced: Bool, _ animation: Animation) -> Animation? { nil }
}
@main struct Proof {
    @MainActor static func main() async throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        var checks: [String: Bool] = [:], calls: [String] = []
        let c = MacRowSwipeController(); c.reduceMotion = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
        defer { window.close(); other.close() }
        let first = MacSwipeAnchor.View(id: UUID(), controller: c, prepare: { { calls.append("first:" + $0.rawValue) } })
        let second = MacSwipeAnchor.View(id: UUID(), controller: c, prepare: { { calls.append("second:" + $0.rawValue) } })
        first.frame = NSRect(x: 0, y: 0, width: 600, height: 40); second.frame = NSRect(x: 0, y: 60, width: 600, height: 40)
        window.contentView!.addSubview(first); window.contentView!.addSubview(second)
        let a = NSPoint(x: 300, y: 20), b = NSPoint(x: 300, y: 80)
        func send(_ phase: MacSwipeSample.Phase, dx: Double = 0, dy: Double = 0, point: NSPoint? = nil, to target: NSWindow? = nil, momentumEnded: Bool = false) -> Bool {
            c.route(MacSwipeSample(phase: phase, dx: dx, dy: dy, momentumEnded: momentumEnded), at: point ?? a, window: target ?? window)
        }
        checks["markersDoNotInterceptClicks"] = first.hitTest(.zero) == nil && second.hitTest(.zero) == nil
        checks["verticalPassesThrough"] = !send(.begin, dy: 30) && !send(.end) && calls.isEmpty
        checks["orphanChangeCannotClaim"] = !send(.change, dx: 200) && calls.isEmpty
        _ = send(.begin, dx: 100); _ = send(.end)
        checks["defaultsRevealWithoutExecuting"] = calls.isEmpty && c.motion.stage == .open && c.surface == first.id
        checks["onlyRevealedRegionContainsActions"] = c.actionsContain(NSPoint(x: 20, y: 20), window: window) && !c.actionsContain(a, window: window)
        c.perform(.complete, on: first.id); c.perform(.complete, on: first.id)
        checks["revealedButtonDeliversExactlyOnce"] = calls == ["first:complete"]
        calls = []; _ = send(.begin, dx: -150, point: b); _ = send(.end, point: b)
        c.perform(.delete, on: first.id); checks["anotherSurfaceCannotInvokeOpenRow"] = calls.isEmpty
        c.perform(.delete, on: second.id)
        checks["repeatedTaskRowsHaveIndependentSurfaces"] = calls == ["second:delete"]
        calls = []; c.configure(leading: .complete, trailing: .tomorrow, fullSwipe: true, rightToLeft: false)
        _ = send(.begin, dx: 600); _ = send(.cancel); _ = send(.end)
        checks["cancelCannotCompleteArmedRow"] = calls.isEmpty && c.surface == nil
        _ = send(.begin, dx: 600); c.cancel(); _ = send(.end)
        checks["contextCancellationCannotComplete"] = calls.isEmpty
        _ = send(.begin, dx: 600); _ = send(.end)
        checks["optInFullCompletion"] = calls == ["first:complete"]
        checks["ownedMomentumSuppressed"] = send(.momentum, dx: 600, momentumEnded: true)
        checks["unownedMomentumPassesThrough"] = !send(.momentum, dx: 600)
        calls = []; _ = send(.begin, dx: -600); _ = send(.end)
        checks["fullTomorrowIsNotDelete"] = calls == ["first:tomorrow"]
        calls = []; _ = send(.begin, dx: 600); _ = send(.end, to: other)
        checks["anotherWindowCannotFinishAction"] = calls.isEmpty
        c.configure(leading: .none, trailing: .none, fullSwipe: true, rightToLeft: false)
        checks["disabledEdgePassesThrough"] = !send(.begin, dx: 600) && calls.isEmpty
        c.configure(leading: .complete, trailing: .tomorrow, fullSwipe: true, rightToLeft: true)
        _ = send(.begin, dx: -600); _ = send(.end)
        checks["rtlLeadingIsMirrored"] = calls == ["first:complete"]
        calls = []; first.completed = true; _ = send(.begin, dx: 600); _ = send(.end)
        checks["completedTomorrowDisabled"] = calls.isEmpty
        first.completed = false; c.configure(leading: .complete, trailing: .tomorrow, fullSwipe: false, rightToLeft: false)
        _ = send(.begin, dx: 100); _ = send(.end); c.unregister(first); c.perform(.complete, on: first.id)
        checks["unregisteredAnchorRevokesButton"] = calls.isEmpty
        c.register(first); _ = send(.begin, dx: 100)
        await Task.yield()
        checks["deferredTeardownCannotCancelNewGesture"] = c.surface == first.id && c.motion.stage == .tracking
        c.cancel(); c.isAvailable = { false }
        checks["unavailableListNeverClaims"] = !send(.begin, dx: 600) && calls.isEmpty
        c.isAvailable = { true }; c.cancel()
        checks["outsideRowsPassesThrough"] = !send(.begin, dx: 600, point: NSPoint(x: 610, y: 200))

        let suite = "com.dbakp.taskfold.swipeproof." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for (name, dark, large) in [("settings-light", false, false), ("settings-dark", true, true)] {
            let hosting = NSHostingView(rootView: MacSwipeSettings().defaultAppStorage(defaults).environment(\.colorScheme, dark ? .dark : .light).environment(\.dynamicTypeSize, large ? .accessibility3 : .large).frame(width: 620, height: 520))
            let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
            preview.isReleasedWhenClosed = false; preview.contentView = hosting; preview.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hosting.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.15)); hosting.displayIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(name + ".png")) }
            }
            preview.close()
        }
        for (name, dx, rtl, full) in [("row-leading", 150.0, false, false), ("row-trailing", -150.0, false, false), ("row-rtl", -150.0, true, false), ("row-full-tomorrow", -600.0, false, true)] {
            let rowController = MacRowSwipeController(); rowController.reduceMotion = true
            rowController.configure(leading: .complete, trailing: .tomorrow, fullSwipe: full, rightToLeft: rtl)
            let hosting = NSHostingView(rootView: MacSwipeRow(controller: rowController, completed: false, selected: false, prepare: { { _ in } }) {
                HStack(spacing: 10) { Image(systemName: "circle"); Text("Review the desktop layout"); Spacer(); Image(systemName: "flag") }.padding(.horizontal, 12).frame(height: 60)
            }.environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight).frame(width: 640, height: 60))
            let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
            preview.isReleasedWhenClosed = false; preview.contentView = hosting
            hosting.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let point = hosting.convert(NSPoint(x: 320, y: 30), to: nil)
            _ = rowController.route(MacSwipeSample(phase: .begin, dx: dx), at: point, window: preview)
            if !full { _ = rowController.route(MacSwipeSample(phase: .end), at: point, window: preview) }
            checks[name + "SwiftUIAnchorTargets"] = rowController.surface != nil && (full ? rowController.motion.armed : rowController.motion.stage == .open)
            hosting.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.15)); hosting.displayIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let left = bitmap.colorAt(x: 4, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
                let right = bitmap.colorAt(x: bitmap.pixelsWide - 5, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
                func actionColor(_ color: NSColor) -> Bool {
                    dx > 0 || rtl ? color.greenComponent > color.redComponent + 0.15 && color.greenComponent > color.blueComponent : color.redComponent > color.greenComponent + 0.15 && color.greenComponent > color.blueComponent + 0.15
                }
                checks[name + "PaintedOnCorrectSide"] = dx > 0 && !rtl ? actionColor(left) && !actionColor(right) : actionColor(right) && !actionColor(left)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(name + ".png")) }
            }
            rowController.cancel(); preview.close()
        }
        let result = URL(fileURLWithPath: CommandLine.arguments[1])
        try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]).write(to: result)

        guard checks.count == 30, checks.values.allSatisfy({ $0 }) else { print("Failed checks: \(checks)"); exit(1) }
    }
}
'''
with tempfile.TemporaryDirectory(prefix='taskfold-mac-swipe-') as temporary:
    temporary = Path(temporary)
    source = (repo/'Taskfold/Core/RowGesture.swift').read_text()
    # Intent checks use real Core records in XCTest. The AppKit harness compiles
    # the unchanged production enum/commands/motion and entire native adapter/row.
    model = source.split('/// The root also fences')[0] + source[source.index('/// Logical leading/trailing'):]
    (temporary/'Model.swift').write_text(model)
    (temporary/'Proof.swift').write_text(harness)
    (temporary/'Environment.swift').write_text((repo/'Taskfold/Views/TaskRowView.swift').read_text().split('/// One task in the content list:')[0])
    command = ['xcrun','swiftc','-parse-as-library',str(temporary/'Model.swift'),str(repo/'Taskfold/Views/RowSwipe.swift'),str(temporary/'Proof.swift'),str(temporary/'Environment.swift'),'-o',str(temporary/'Proof')]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    result = subprocess.run([str(temporary/'Proof'),str(args.output.resolve()),str(args.previews.resolve())],text=True,capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
checks = json.loads(args.output.read_text())
evidence = {'checks':checks,'sourceSHA256':{name:hashlib.sha256((repo/name).read_bytes()).hexdigest() for name in ['Taskfold/Core/RowGesture.swift','Taskfold/Views/RowSwipe.swift','Taskfold/Views/TaskRowView.swift']},'limits':['No event posting or physical trackpad input; route tests use real offscreen AppKit views and normalized samples.','Motion adapter is inert; production intent checks are separate Core tests.','Settings previews do not establish full main-app/native-settings-window acceptance.']}
args.output.write_text(json.dumps(evidence,indent=2)+'\n')
print(f'{len(checks)} AppKit routing checks passed')
