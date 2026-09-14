#if DEBUG
import AppKit

/// Read-only measurements for isolated fixtures when the external XCTest service is unavailable.
/// This command is absent from Release and refuses to report a real account/workspace.
@MainActor enum DebugDiagnostics {
    static func report(_ workspace: Workspace) {
        guard ProcessInfo.processInfo.arguments.contains("--uitesting"), workspace.store.userID == "ui-testing" else { return }
        func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
        }
        let tables: [[String: Any]] = NSApp.windows.filter { $0.isVisible }.flatMap { window in
            guard let content = window.contentView else { return [[String: Any]]() }
            return descendants(NSTableView.self, in: content).map { table in
                let rows: [[String: Any]] = descendants(ListScrollRowMarker.Marker.self, in: table).compactMap { marker in
                    let row = table.row(for: marker)
                    guard row >= 0 else { return nil }
                    let rect = table.rect(ofRow: row)
                    return ["task": marker.taskID, "height": rect.height, "y": rect.minY,
                            "visibleY": rect.minY - (table.enclosingScrollView?.contentView.bounds.minY ?? 0)]
                }
                return ["rows": rows, "floatsGroupRows": table.floatsGroupRows,
                        "offset": table.enclosingScrollView?.contentView.bounds.minY ?? 0,
                        "viewportHeight": table.enclosingScrollView?.contentView.bounds.height ?? 0]
            }
        }
        let tasks: [[String: Any]] = workspace.store.tasks.map {
            ["id": $0.id, "title": $0.title, "due": $0.string("due_date"), "section": $0.string("section_id"), "priority": $0.priority, "completed": $0.completed]
        }
        let report: [String: Any] = ["dragActive": workspace.drag.active, "windows": NSApp.windows.filter { $0.isVisible }.map { ["title": $0.title, "class": $0.className] }, "density": UserDefaults.standard.string(forKey: "mac.taskDensity") ?? "roomy", "tables": tables, "tasks": tasks]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
            FileHandle.standardOutput.write(Data(("TASKFOLD_DIAGNOSTICS=" + text + "\n").utf8))
        }
    }
}
#endif
