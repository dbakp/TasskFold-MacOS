"""Temporary phase markers/readback UI in an exact reserved native Mac host."""
import argparse,json,shutil
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--host',type=Path,required=True);p.add_argument('--source',type=Path,required=True);a=p.parse_args()
host=a.host.resolve();source=a.source.resolve()
receipt=json.loads((host/'isolation-receipt.json').read_text())
assert receipt['bundleID']=='com.dbakp.taskfold.mac.workflowteststeameditbridge' and host!=source
for f in ['Taskfold/Core/Store.swift','Taskfold/Core/TaskActivity.swift','Taskfold/TeamTemplateNativeFixture.swift']:shutil.copyfile(source/f,host/f)
p=host/'Taskfold/Core/Store.swift';s=p.read_text();anchor='    @ObservationIgnored private(set) var workflowPreparedEncodingUsed = false';assert s.count(anchor)==1
s=s.replace(anchor,anchor+'''
    @ObservationIgnored var workflowCommitProfile: [String: Double] = [:]
    @ObservationIgnored private var workflowProfileClock: ContinuousClock.Instant?
    private func workflowProfileStart() {
        guard WorkflowUndoNativePeer.enabled, ProcessInfo.processInfo.arguments.contains("--workflow-profile-local-commit") else { return }
        workflowCommitProfile = [:]; workflowProfileClock = .now
    }
    private func workflowProfileMark(_ stage: String, finish: Bool = false) {
        guard let previous = workflowProfileClock else { return }
        let now = ContinuousClock.now, elapsed = previous.duration(to: now)
        workflowCommitProfile[stage] = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        workflowProfileClock = finish ? nil : now
    }
''')
def mark(anchor,name):
 global s
 assert s.count(anchor)==1,(anchor,s.count(anchor))
 s=s.replace(anchor,'        #if DEBUG\n        workflowProfileMark("'+name+'")\n        #endif\n'+anchor)
s=s.replace('        let historySourceRevision = snapshotRevision','        #if DEBUG\n        workflowProfileStart()\n        #endif\n        let historySourceRevision = snapshotRevision')
mark('        let old = snapshot\n        // Normalization precedes','commandValidation')
mark('        // This synchronous creation path reads rows directly','normalization')
mark('        if projectsFreshCreation {\n            var projectionSource','commandProjection')
mark('        if let widgetReceipt { snapshot.widgetCompletion.record','historyAdoption')
mark('        if deferringPresentation {\n            workflowPresentationDeferred = false; deferringPresentation = false','undo')
mark('        do { try persist(backgroundWidgets: projectsFreshCreation','presentation')
start=s.index('    func persist(acceptingTimeSnooze');end=s.index('    func makeInboxReview',start);head,body,tail=s[:start],s[start:end],s[end:]
for anchor,name in [('        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent()','widgetPrepare'),('        var durable = snapshot','diskRead'),('        let preparedData = try preparedEncoding?.matching(durable)','receiptStaging'),('        let data = try preparedData ?? JSONEncoder().encode(durable)','encodingAdmission'),('        if UUID(uuidString: userID) != nil {','encoding'),('        snapshot = durable','atomicWrite'),('        scheduleDailyBackup()','publication')]:
 assert body.count(anchor)==1,(anchor,body.count(anchor));body=body.replace(anchor,'        #if DEBUG\n        workflowProfileMark("'+name+'")\n        #endif\n'+anchor)
s=head+body+tail
anchor='        Task { await reschedule(); await sync() }\n        return true\n    }\n    @discardableResult\n    func save('
assert s.count(anchor)==1;s=s.replace(anchor,'        Task { await reschedule(); await sync() }\n        #if DEBUG\n        workflowProfileMark("postPersist", finish: true)\n        #endif\n        return true\n    }\n    @discardableResult\n    func save(');p.write_text(s)
p=host/'Taskfold/TeamTemplateNativeFixture.swift';s=p.read_text();anchor='    @State private var scaleOriginal: Snapshot?';assert s.count(anchor)==1;s=s.replace(anchor,anchor+'\n    @State private var renderedProfile: String?')
anchor='                    Button("Measure workflow commit")';assert s.count(anchor)==1;s=s.replace(anchor,'''                    if ProcessInfo.processInfo.arguments.contains("--workflow-profile-local-commit") {
                        Button("Read commit profile") {
                            do {
                                guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--workflow-commit-proof=") }), let proof = UUID(uuidString: String(argument.dropFirst("--workflow-commit-proof=".count))) else { return }
                                let bytes = try Data(contentsOf: TeamTemplateNativeFixture.root.appendingPathComponent("commit-scale-" + proof.uuidString.lowercased() + ".json"))
                                let object = try JSONSerialization.jsonObject(with: bytes)
                                renderedProfile = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
                            } catch { renderedProfile = error.localizedDescription }
                        }.accessibilityIdentifier("readWorkflowCommitProfile")
                        if let renderedProfile { Text(renderedProfile).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).accessibilityIdentifier("workflowCommitProfileJSON") }
                    }
'''+anchor)
anchor='                "synchronousCommitSeconds": .number(Double(commitElapsed.components.seconds) + Double(commitElapsed.components.attoseconds) / 1e18),';assert s.count(anchor)==1;s=s.replace(anchor,anchor+'\n                "commitProfile": .object(store.workflowCommitProfile.mapValues { .number($0) }),');p.write_text(s)
print('Instrumented only the reserved disposable Mac host; repository source unchanged')
