import SwiftUI

/// Account security actions from Settings ▸ Account. Every sheet surfaces the server's message verbatim.
struct ChangeEmailSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var busy = false
    @State private var message: String?
    @State private var sent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Email").font(.headline)
            Text("Taskfold sends a confirmation link to the new address. The change applies once you open it.").font(.callout).foregroundStyle(.secondary)
            TextField("New email address", text: $email).textContentType(.emailAddress).textFieldStyle(.roundedBorder).disabled(sent)
                .accessibilityIdentifier("newEmail")
            if let message { Text(message).font(.callout).foregroundStyle(sent ? Color.secondary : Color.red).textSelection(.enabled).accessibilityIdentifier("accountMessage") }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(sent ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if !sent {
                    Button("Send Confirmation") { submit() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(busy || !email.contains("@") || email.lowercased() == store.email.lowercased())
                }
            }
        }.padding(20).frame(width: 420)
    }
    private func submit() {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { try await store.backend.updateAccount(email: email); sent = true; message = "Check \(email.trimmingCharacters(in: .whitespaces)) for the confirmation link." }
            catch { message = error.localizedDescription }
        }
    }
}

struct ChangePasswordSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var message: String?
    @State private var done = false
    private var mismatch: Bool { !confirmation.isEmpty && confirmation != password }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Password").font(.headline)
            SecureField("New password (at least 6 characters)", text: $password).textContentType(.newPassword).textFieldStyle(.roundedBorder).accessibilityIdentifier("newPassword")
            SecureField("Confirm new password", text: $confirmation).textContentType(.newPassword).textFieldStyle(.roundedBorder).accessibilityIdentifier("confirmPassword")
            if mismatch { Text("The passwords do not match.").font(.caption).foregroundStyle(.red) }
            if let message { Text(message).font(.callout).foregroundStyle(done ? Color.secondary : Color.red).textSelection(.enabled).accessibilityIdentifier("accountMessage") }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(done ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if !done {
                    Button("Change Password") { submit() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(busy || password.count < 6 || confirmation != password)
                }
            }
        }.padding(20).frame(width: 420)
    }
    private func submit() {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { try await store.backend.updateAccount(password: password); done = true; message = "Your password was changed." }
            catch { message = error.localizedDescription }
        }
    }
}

struct DeleteAccountSheet: View {
    let workspace: WorkspaceBinding
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var understood = false
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Delete Account", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.red)
            Text("This permanently removes your Taskfold account, profile, owned projects and tasks, and uploaded files. Other people’s tasks stay; comments on surviving shared tasks may remain anonymously.").font(.callout)
            Text("Saved account data and recovery backups on this Mac are erased after server confirmation. Exported files and copies on other devices are not erased. If interrupted, removal resumes when you reopen Taskfold. Export your workspace first if you want a copy.").font(.callout).foregroundStyle(.secondary)
            Toggle("I understand this is permanent", isOn: $understood).accessibilityIdentifier("deleteUnderstood")
            if let message { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("accountMessage") }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Delete Account", role: .destructive) { submit() }.buttonStyle(.borderedProminent).tint(.red)
                    .disabled(!understood || busy).accessibilityIdentifier("confirmDeleteAccount")
            }
        }.padding(20).frame(width: 440)
    }
    private func submit() {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                try await store.deleteAccount(expected: workspace)
                dismiss()
            } catch { message = error.localizedDescription }
        }
    }
}
