import SwiftUI

/// Settings > Privacy. Every statement comes from PrivacyFacts so both apps say the same thing.
struct PrivacySettings: View {
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    var body: some View {
        Form {
            Section { Text(PrivacyFacts.intro).font(.callout).fixedSize(horizontal: false, vertical: true) }
            ForEach(PrivacyFacts.items) { item in Section { PrivacyItemView(item: item) } }
            Section("Your controls") {
                if store.signedIn { control(PrivacyFacts.control("export")) }
                if store.signedIn, !store.localMode { control(PrivacyFacts.control("local")) }
                if store.signedIn, !store.localMode { control(PrivacyFacts.control("delete")) }
                if !store.signedIn || store.localMode {
                    Text("You’re using Taskfold on this Mac without a cloud account. Nothing syncs.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Section { Text(PrivacyFacts.footer).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier(PrivacyFacts.screenIdentifier)
    }
    /// All three live in the Account tab: Backups & restore, Sign Out, and Delete Account.
    private func control(_ control: PrivacyFacts.Control) -> some View {
        Button { workspace.settingsTab = .account } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(control.title); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true) }
                Text(control.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the Account tab")
        .accessibilityIdentifier("privacyControl-" + control.id)
    }
}

/// One topic on the Privacy screen. Placement is a small caption (never colour alone) and wraps under large text.
struct PrivacyItemView: View {
    let item: PrivacyFacts.Item
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title).font(.headline)
            Label(item.location.label, systemImage: item.location.symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            Text(item.summary).font(.body)
            ForEach(Array(item.points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(point).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityIdentifier("privacyItem-" + item.id)
    }
}

