#!/usr/bin/env python3
"""Build a synthetic native accessibility host from owned widget views; not WidgetKit system acceptance."""
from pathlib import Path
import subprocess,plistlib,argparse
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--small', action='store_true', help='Inspect the small widget layout')
parser.add_argument('--kind', choices=['list', 'today-focus', 'remaining'], default='list')
args=parser.parse_args()
repo=Path(__file__).resolve().parent.parent
dest=args.output.expanduser().resolve()
if dest.exists(): parser.error('Output must be new; existing apps are never replaced.')
dest.mkdir(parents=True)
source=(repo/'TaskfoldWidgets/TaskfoldWidgets.swift').read_text().replace('@main\nstruct TaskfoldWidgetBundle','struct TaskfoldWidgetBundle')
source=source.replace('@Environment(\\.widgetFamily) private var family','var family: WidgetFamily = .systemMedium')
source+='''
@main struct WidgetPrivacyTestHost: App {
    var body: some Scene {
        WindowGroup("Taskfold widget privacy test") {
            VStack(alignment: .leading, spacing: 20) {
                Text("Normal").font(.headline)
                cards(privateMode: false)
                Text("Privacy redaction").font(.headline)
                cards(privateMode: true)
            }.padding(24).frame(width: 760, height: 520).environment(\\.colorScheme, .light)
        }
    }
    func cards(privateMode: Bool) -> some View {
        let now = Date()
        var snapshot = TodayEntry.preview.snapshot
        snapshot.tasks = Array(snapshot.tasks.prefix(1))
        snapshot.tasks[0].title = "Private launch budget"
        snapshot.tasks[0].completionToken = "privacy-test-token"
        let listID = snapshot.availableLists.first!.id
        var completed = snapshot
        completed.tasks = []
        completed.completionFeedback = WidgetCompletionFeedback(account: snapshot.account, taskID: "completed-proof", title: "Confidential completed proposal", listIDs: [listID], savedAt: now)
        return HStack(spacing: 20) {
            ListWidgetView(entry: ListEntry(date: now, snapshot: snapshot, listID: listID))
                .padding(16).frame(width: 338, height: 180).background(WidgetSurface(tint: mint))
                .accessibilityElement(children: .contain).accessibilityIdentifier(privateMode ? "private-open" : "normal-open")
            ListWidgetView(entry: ListEntry(date: now, snapshot: completed, listID: listID))
                .padding(16).frame(width: 338, height: 180).background(WidgetSurface(tint: mint))
                .accessibilityElement(children: .contain).accessibilityIdentifier(privateMode ? "private-completed" : "normal-completed")
        }.redacted(reason: privateMode ? .privacy : [])
    }
}
'''
if args.kind == 'today-focus':
    source=source.replace('ListWidgetView(entry: ListEntry(date: now, snapshot: snapshot, listID: listID))', 'TodayWidgetView(entry: TodayEntry(date: now, snapshot: snapshot))')
    source=source.replace('ListWidgetView(entry: ListEntry(date: now, snapshot: completed, listID: listID))', 'FocusWidgetView(entry: TodayEntry(date: now, snapshot: snapshot))')
if args.kind == 'remaining':
    source=source.replace('@main struct WidgetPrivacyTestHost: App {', '@main struct WidgetPrivacyTestHost: App {\n    @State private var selectedPair = 0')
    source=source.replace('Text("Normal").font(.headline)', '''Picker("Widget pair", selection: $selectedPair) {
                    Text("Planning").tag(0)
                    Text("Workload").tag(1)
                    Text("Notes & Focus").tag(2)
                    Text("Week & Pulse").tag(3)
                }.pickerStyle(.segmented)
                Text("Normal").font(.headline)''')
    source=source.replace('ListWidgetView(entry: ListEntry(date: now, snapshot: snapshot, listID: listID))', 'remainingCard(index: 0)')
    source=source.replace('ListWidgetView(entry: ListEntry(date: now, snapshot: completed, listID: listID))', 'remainingCard(index: 1)')
    source=source.replace('    func cards(privateMode: Bool) -> some View {', '''    @ViewBuilder func remainingCard(index: Int) -> some View {
        switch (selectedPair, index) {
        case (0, 0): DeadlineWidgetView(entry: DeadlineEntry(date: TodayEntry.preview.date, snapshot: TodayEntry.preview.snapshot))
        case (0, 1): WindowWidgetView(entry: WindowEntry(date: TodayEntry.preview.date, snapshot: TodayEntry.preview.snapshot))
        case (1, 0): CapacityWidgetView(entry: .preview)
        case (1, 1): InboxWidgetView(entry: .preview)
        case (2, 0): NoteWidgetView(entry: .preview)
        case (2, 1): FocusSessionWidgetView(entry: .preview)
        case (3, 0): WeekWidgetView(entry: .preview)
        default: PulseWidgetView(entry: .preview)
        }
    }
    func cards(privateMode: Bool) -> some View {''')
if args.small:
    source=source.replace('var family: WidgetFamily = .systemMedium', 'var family: WidgetFamily = .systemSmall')
    source=source.replace('frame(width: 338, height: 180)', 'frame(width: 170, height: 170)')
    source=source.replace('frame(width: 760, height: 520)', 'frame(width: 420, height: 500)')
(dest/'Preview.swift').write_text(source)
app=dest/'Taskfold Widget Privacy Test.app'; (app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
info={'CFBundleIdentifier':'com.dbakp.taskfold.widgetprivacyviewtest','CFBundleExecutable':'PrivacyTest','CFBundleName':'Taskfold Widget Privacy Test','CFBundlePackageType':'APPL','NSHighResolutionCapable':True}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['xcrun','swiftc','-parse-as-library','-D','TASKFOLD_WIDGET_EXTENSION',str(repo/'Taskfold/Core/WidgetActions.swift'),str(repo/'Taskfold/Core/FocusWidget.swift'),str(repo/'Taskfold/Core/ProjectPulseWidget.swift'),str(dest/'Preview.swift'),'-o',str(app/'Contents/MacOS/PrivacyTest')],check=True)
print(app)
