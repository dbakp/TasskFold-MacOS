import SwiftUI
import AuthenticationServices
import CryptoKit
import AppKit

struct AuthView: View {
    @Environment(Store.self) private var store
    @State private var email = ""
    @State private var password = ""
    @State private var signup = false
    @State private var busy = false
    @State private var message: String?
    @State private var shake = 0
    @FocusState private var focus: Field?
    enum Field { case email, password }
    var body: some View {
        HStack(spacing: 0) {
            // Brand panel
            VStack(alignment: .leading, spacing: 18) {
                TaskfoldMark(size: 84)
                Text("Taskfold").font(.system(size: 34, weight: .bold, design: .rounded))
                Text("A little clarity for your day.").font(.title3).foregroundStyle(.secondary)
                Spacer()
                Text("Your tasks sync with the Taskfold web and iOS apps through your existing account.").font(.callout).foregroundStyle(.secondary)
            }
            .padding(40).frame(maxWidth: 360, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.taskfold.opacity(0.06))
            Divider()
            // Form
            VStack(alignment: .leading, spacing: 18) {
                Picker("Account", selection: $signup) { Text("Sign In").tag(false); Text("Create Account").tag(true) }.pickerStyle(.segmented).labelsHidden()
                VStack(spacing: 10) {
                    TextField("Email address", text: $email).textContentType(.username).focused($focus, equals: .email).accessibilityIdentifier("authEmail")
                    SecureField("Password", text: $password).textContentType(signup ? .newPassword : .password).focused($focus, equals: .password).accessibilityIdentifier("authPassword")
                        .onSubmit { if canSubmit { authenticate() } }
                }.textFieldStyle(.roundedBorder).controlSize(.large)
                .modifier(ShakeEffect(trigger: shake))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.red.opacity(message == nil ? 0 : 0.6), lineWidth: 1).padding(-3).animation(Transitions.Ease.out(Transitions.Duration.quick), value: message == nil))
                Button { authenticate() } label: {
                    HStack { Spacer(); if busy { ProgressView().controlSize(.small) } else { Text(signup ? "Create Account" : "Sign In") }; Spacer() }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(busy || !canSubmit).accessibilityIdentifier("nativeSignIn")
                Button {
                    busy = true; message = nil
                    Task { defer { busy = false }; do { try await store.backend.googleOnMac(); await store.authenticated() } catch { message = error.localizedDescription } }
                } label: { HStack { Spacer(); Label("Continue with Google", systemImage: "globe"); Spacer() } }
                .buttonStyle(.bordered).controlSize(.large).disabled(busy).accessibilityIdentifier("googleSignIn")
                if let message { Text(message).font(.callout).foregroundStyle(.secondary).transition(.textSwap).textSelection(.enabled) }
                Divider().padding(.vertical, 4)
                Button("Use on this Mac without an account") { store.startLocal() }.buttonStyle(.link).accessibilityIdentifier("useLocally")
                Text("Local tasks stay on this Mac. Sign in to access your existing Taskfold projects and sync across devices.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(40).frame(maxWidth: 420)
            .animation(Motion.quick, value: message)
            .animation(Motion.quick, value: signup)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focus = .email }
        .accessibilityElement(children: .contain)
    }
    private var canSubmit: Bool { email.contains("@") && (signup ? password.count >= 6 : !password.isEmpty) }
    private func authenticate() {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                if try await store.backend.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password, signup: signup) { await store.authenticated() }
                else { message = "Check your email to confirm your account, then sign in."; signup = false }
            } catch { message = error.localizedDescription; shake += 1 }
        }
    }
}

/// Google sign-in on the Mac. Same PKCE flow and callback validation as iOS; the presentation anchor is the key window.
@MainActor
final class WebAuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthAnchor()
    var session: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
    }
}

extension Backend {
    func googleOnMac() async throws {
        let anchor = WebAuthAnchor.shared
        guard anchor.session == nil else { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppFailure(message: "Could not start secure sign-in.") }
        func encode(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let verifier = encode(Data(bytes))
        let challenge = encode(Data(SHA256.hash(data: Data(verifier.utf8))))
        guard var components = URLComponents(string: baseURL + "/auth/v1/authorize") else { throw AppFailure(message: "The Supabase configuration is missing.") }
        components.queryItems = [URLQueryItem(name: "provider", value: "google"), URLQueryItem(name: "redirect_to", value: "taskfold://auth/callback"), URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "s256")]
        defer { anchor.session?.cancel(); anchor.session = nil }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "taskfold") { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? AppFailure(message: "Sign-in was cancelled.")) }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            anchor.session = session
            if !session.start() { continuation.resume(throwing: AppFailure(message: "Could not open sign-in.")) }
        }
        let code = try OAuthCallback.code(from: callback)
        let data = try await request("/auth/v1/token?grant_type=pkce", method: "POST", body: ["auth_code": .string(code), "code_verifier": .string(verifier)], authenticated: false)
        let next = try JSONDecoder().decode(Session.self, from: data)
        try SecureSession.save(next)
        session = next
    }
}
