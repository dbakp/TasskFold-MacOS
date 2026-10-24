import SwiftUI

/// Kept out of release navigation until organization rollout is ready.
enum TeamOrganizationAvailability {
    static var enabled: Bool { Bundle.main.object(forInfoDictionaryKey: "TaskfoldTeamsEnabled") as? Bool == true }
}

struct TeamOrganizationView: View {
    var teamID: String?
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var browser: TeamOrganizationBrowser?
    @State private var loadedScope: String?

    private var scope: String? {
        #if DEBUG
        if TeamOrganizationFixture.enabled { return "synthetic-team-overview" }
        #endif
        guard phase == .active, store.teamOrganizationReadable, let origin = try? store.backend.accountRemovalOrigin else { return nil }
        return "\(store.userID)|\(origin)|\(store.workspaceGeneration)|\(store.workspaceReadRevision)|\(store.backend.reminderSessionIncarnation)"
    }
    var body: some View {
        Group {
            if let scope, scope == loadedScope, let browser {
                if browser.loading { ProgressView("Refreshing teams…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let message = browser.message { unavailable(message, retry: true) }
                else if let detail = browser.detail { detailView(detail) }
                else if let overview = browser.overview { overviewView(overview) }
                else { unavailable("Refresh to view your teams.", retry: true) }
            } else { unavailable("Open your synced account to view its teams.", retry: false) }
        }
        .navigationTitle(teamID == nil ? "Teams" : (scope != nil && scope == loadedScope ? browser?.detail?.team.name : nil) ?? "Team")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .frame(minWidth: 540, idealWidth: 660, minHeight: 500)
        #endif
        .toolbar {
            if teamID == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            ToolbarItem { Button { Task { await browser?.refresh(team: teamID) } } label: { Label("Refresh teams", systemImage: "arrow.clockwise") }.disabled(scope == nil || browser?.loading == true) }
        }
        .task(id: scope) { await start() }
        .onDisappear { browser?.invalidate() }
    }
    private func unavailable(_ text: String, retry: Bool) -> some View {
        ContentUnavailableView {
            Label("Your teams", systemImage: "person.3")
        } description: { Text(text) } actions: {
            if retry { Button("Try again") { Task { await browser?.refresh(team: teamID) } } }
        }
    }
    private func overviewView(_ overview: TeamOrganizationOverview) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "person.3.sequence.fill").font(.largeTitle).foregroundStyle(.tint).accessibilityHidden(true)
                    Text("A place for shared work").font(.title2.bold())
                    Text("See the teams you belong to and how each one is organized.").foregroundStyle(.secondary)
                }.padding(.vertical, 12).listRowBackground(Color.accentColor.opacity(0.07))
            }
            if !overview.enabled {
                Section { Label("Team setup is paused. Existing team details are still available.", systemImage: "pause.circle").font(.callout).foregroundStyle(.secondary) }
            }
            if overview.teams.isEmpty {
                Section { ContentUnavailableView("No teams yet", systemImage: "person.3", description: Text("Your teams will appear here when you join one.")) }
            } else {
                let active = overview.teams.filter { !$0.archived }
                let archived = overview.teams.filter(\.archived)
                if !active.isEmpty { Section("Your teams") { ForEach(active) { teamRow($0) } } }
                if !archived.isEmpty { Section("Archived") { ForEach(archived) { teamRow($0) } } }
            }
            let offers = overview.invitations.filter { $0.expires > Date() }
            if !offers.isEmpty {
                Section {
                    ForEach(offers) { offer in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(offer.name, systemImage: "envelope").font(.headline)
                            Text("Invited as \(offer.role.title.lowercased()) · Expires \(offer.expires.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                } header: { Text("Invitations") } footer: { Text("This preview shows your pending invitations. Responses aren’t available here yet.") }
            }
        }
        .refreshable { await browser?.refresh() }
        .accessibilityIdentifier("teamOverview")
    }
    private func teamRow(_ team: TeamOrganization) -> some View {
        NavigationLink { TeamOrganizationView(teamID: team.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: team.archived ? "archivebox" : "person.2.fill").foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) { Text(team.name).font(.headline); Text(team.role.title).font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 5)
        }.accessibilityIdentifier("team-\(team.id)")
    }
    private func detailView(_ detail: TeamOrganizationDetail) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(detail.team.name, systemImage: "person.3.fill").font(.title2.bold())
                    Text("Your role: \(detail.team.role.title)").foregroundStyle(.secondary)
                    if detail.team.archived { Label("Archived", systemImage: "archivebox").font(.callout).foregroundStyle(.secondary) }
                }.padding(.vertical, 10).listRowBackground(Color.accentColor.opacity(0.07))
            }
            if detail.team.role != .guest {
                Section {
                    if detail.folders.isEmpty { Text("No folders yet").foregroundStyle(.secondary) }
                    ForEach(detail.folders) { Label($0.name, systemImage: "folder").padding(.vertical, 3) }
                } header: { Text("Folders") } footer: { Text("Folders organize the team. Project access is managed separately.") }
            }
            if detail.team.role.directoryVisible {
                Section("Members") {
                    ForEach(detail.members) { member in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(member.id == detail.account ? "You" : "Member \(member.id.suffix(8))").font(.headline)
                                if member.id != detail.account { Text("Name not shared").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 8)
                            Text(member.role.title).font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
                let pending = detail.invitations.filter { $0.expires > Date() }
                if !pending.isEmpty {
                    Section("Pending invitations") {
                        ForEach(pending) { invitation in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(invitation.email).textSelection(.enabled)
                                Text("\(invitation.role.title) · Expires \(invitation.expires.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Section { Label("The member directory is visible to team owners and admins.", systemImage: "person.crop.circle.badge.checkmark").font(.callout).foregroundStyle(.secondary) }
            }
            if let transfer = detail.transfer, transfer.expires > Date() {
                Section("Ownership") {
                    Label(transfer.target == detail.account ? "You’ve been offered ownership" : "Ownership transfer pending", systemImage: "person.badge.key")
                    Text("Expires \(transfer.expires.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .refreshable { await browser?.refresh(team: teamID) }
        .accessibilityIdentifier("teamDetails")
    }
    @MainActor private func start() async {
        browser?.invalidate(); browser = nil; loadedScope = nil
        guard let captured = scope else { return }
        #if DEBUG
        if TeamOrganizationFixture.enabled {
            browser = TeamOrganizationFixture.browser(); loadedScope = captured
            await browser?.refresh(team: teamID); return
        }
        #endif
        let account = store.userID
        guard let origin = try? store.backend.accountRemovalOrigin else { return }
        let backend = store.backend
        browser = TeamOrganizationBrowser(account: account, origin: origin, current: { scope == captured },
            overview: { try await backend.teamOrganizationOverview(account: account, origin: origin) },
            detail: { try await backend.teamOrganizationDetail(team: $0, account: account, origin: origin) })
        loadedScope = captured
        await browser?.refresh(team: teamID)
    }
}

#if DEBUG
/// This route never signs in, sends email or touches task data.
enum TeamOrganizationFixture {
    static var enabled: Bool {
        ["com.dbakp.taskfold.workflowteststeams", "com.dbakp.taskfold.mac.workflowteststeams"].contains(Bundle.main.bundleIdentifier ?? "") && ProcessInfo.processInfo.arguments.contains("--team-overview-testing")
    }
    static let account = "ea300000-0000-4000-8000-000000000001"
    static let team = "ea300000-0000-4000-8000-000000000002"
    static var row: [String: JSON] { ["id": .string(team), "name": .string("Design studio"), "role": .string("owner"), "state": .string("active"), "revision": .number(3)] }
    @MainActor static func browser() -> TeamOrganizationBrowser {
        TeamOrganizationBrowser(account: account, origin: "https://synthetic.example", current: { enabled }, overview: {
            try TeamOrganizationOverview(list: ["enabled": .bool(false), "teams": .array([.object(row)])], invitations: ["enabled": .bool(false), "invitations": .array([])], account: account, origin: "https://synthetic.example")
        }, detail: { id in
            var raw = row
            raw["folders"] = .array([.object(["id": .string("ea300000-0000-4000-8000-000000000003"), "name": .string("Product design"), "position": .number(0)]), .object(["id": .string("ea300000-0000-4000-8000-000000000004"), "name": .string("Launch planning"), "position": .number(1)])])
            raw["members"] = .array([.object(["user_id": .string(account), "role": .string("owner")])]); raw["invitations"] = .array([])
            return try TeamOrganizationDetail(raw, team: id, account: account, origin: "https://synthetic.example")
        })
    }
}
#endif
