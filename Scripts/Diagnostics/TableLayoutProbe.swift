import SwiftUI
struct Sample: Identifiable {
    let id: Int
    var title: String { id % 3 == 0 ? "A longer synthetic task title to exercise wrapping across the task list while the native table estimates row heights, sample \(id)" : "Synthetic task \(id)" }
}
enum Scope: String, CaseIterable, Identifiable { case today = "Today", all = "All Tasks"; var id: Self { self } }
@main struct LayoutProbe: App {
    var body: some Scene { WindowGroup { ProbeView().frame(minWidth: 900, minHeight: 650) } }
}
struct ProbeView: View {
    @State private var scope: Scope? = .today
    @State private var selection = Set<Int>()
    private var rows: [Sample] { (0..<(scope == .today ? 44 : 256)).map(Sample.init) }
    var body: some View {
        NavigationSplitView {
            List(Scope.allCases, selection: $scope) { Text($0.rawValue).tag($0) }
        } detail: {
            List(selection: $selection) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title).lineLimit(2)
                        if row.id % 2 == 0 { Text("Synthetic supporting note \(row.id)").font(.callout).lineLimit(1).foregroundStyle(.secondary) }
                        HStack { Text("Project \(row.id % 5)"); Text("15 min"); Text("Oct 13") }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(row.id)
                }
            }.id(scope).listStyle(.inset).frame(maxWidth: 720).frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.2), value: rows.map(\.id))
        }
    }
}
