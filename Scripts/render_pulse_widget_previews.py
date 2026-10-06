#!/usr/bin/env python3
"""Render actual owned SwiftUI widget source; not an installed WidgetKit host."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
source = (root/'TaskfoldWidgets/TaskfoldWidgets.swift').read_text().replace('@main\nstruct TaskfoldWidgetBundle', 'struct TaskfoldWidgetBundle').replace('@Environment(\\.widgetFamily) private var family', 'var family: WidgetFamily = .systemMedium')
source += r'''
@main struct PulsePreviewRenderer {
 @MainActor static func main() throws {
  let mode = CommandLine.arguments[2]
  var entry = PulseEntry.preview
  if mode == "pulse-private" { entry.hideNames = true }
  if mode == "pulse-choose" { entry.projectID = nil }
  if mode == "pulse-unavailable" { entry.projectID = PulseProject.key(account: "preview", project: "removed") }
  if mode == "pulse-refresh" { entry.snapshot.updated -= 86_400 }
  if mode == "pulse-no-history" { entry.snapshot.projectPulse?.recordedFrom = nil; entry.snapshot.projectPulse?.history = "unavailable" }
  if mode == "pulse-incomplete" { entry.snapshot.projectPulse?.history = "incomplete" }
  if mode == "pulse-empty" {
   entry.snapshot.projectPulse?.projects[0].total = 0; entry.snapshot.projectPulse?.projects[0].completed = 0
   for key in entry.snapshot.projectPulse!.projects[0].days.keys { entry.snapshot.projectPulse!.projects[0].days[key] = PulseDay(completions: 0, reopens: 0, additions: 0, movedIn: 0, movedOut: 0, attentionCount: 0, attention: []) }
  }
  if mode == "pulse-dense" {
   entry.snapshot.projectPulse?.projects[0].name = "A long project name for the quarterly café planning and launch programme"
   entry.snapshot.projectPulse?.projects[0].total = 12456; entry.snapshot.projectPulse?.projects[0].completed = 8123
  }
  var rose = entry; rose.palette = .rose
  var lavender = entry; lavender.palette = .lavender
  let content = VStack(alignment: .leading, spacing: 20) {
   Text("A good idea, taking shape").font(.system(size: 28, weight: .bold, design: .rounded))
   Text("Current scope. Recorded events. One useful next step.").font(.subheadline).foregroundStyle(.secondary)
   HStack(alignment: .top, spacing: 20) {
    PulseWidgetView(family: .systemSmall, entry: entry).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
    PulseWidgetView(entry: lavender).padding(16).frame(width: 338, height: 170).background(WidgetSurface(tint: plum)).clipShape(RoundedRectangle(cornerRadius: 24))
   }
   HStack(alignment: .top, spacing: 20) {
    PulseWidgetView(family: .systemLarge, entry: entry).padding(16).frame(width: 338, height: 354).background(WidgetSurface(tint: mint)).clipShape(RoundedRectangle(cornerRadius: 24))
    PulseWidgetView(family: .systemSmall, entry: rose).padding(16).frame(width: 170, height: 170).background(WidgetSurface(tint: brand)).clipShape(RoundedRectangle(cornerRadius: 24))
   }
  }.padding(32).background(mode == "pulse-dark" ? Color(white: 0.09) : Color.white)
   .environment(\.colorScheme, mode == "pulse-dark" ? .dark : .light)
   .environment(\.dynamicTypeSize, mode == "pulse-largest" ? .accessibility3 : .large)
  let renderer = ImageRenderer(content: content); renderer.scale = 2
  guard let image = renderer.cgImage else { fatalError("Pulse render failed") }
  try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
 }
}
'''
output = root/'docs/widget-previews'; output.mkdir(exist_ok=True, parents=True)
with tempfile.TemporaryDirectory(prefix='taskfold-pulse-previews-') as temporary:
 path=Path(temporary); (path/'Preview.swift').write_text(source)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-D','TASKFOLD_WIDGET_EXTENSION',str(root/'Taskfold/Core/WidgetActions.swift'),str(root/'Taskfold/Core/FocusWidget.swift'),str(root/'Taskfold/Core/ProjectPulseWidget.swift'),str(path/'Preview.swift'),'-o',str(path/'preview')],check=True)
 for mode in ['pulse','pulse-dark','pulse-private','pulse-choose','pulse-unavailable','pulse-refresh','pulse-no-history','pulse-incomplete','pulse-empty','pulse-dense','pulse-largest']:
  subprocess.run([str(path/'preview'),str(output/f'{mode}.png'),mode],check=True)
