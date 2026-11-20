import SwiftUI
import AuthenticationServices
import CryptoKit
import AppKit

/// The full sign-in screen (design review mac-r2): a 320 pt brand panel and a 300 pt form column.
struct AuthView: View {
    /// Screenshot fixture for `--capture-signin=<state>`; nil in the app.
    var preview: String? = nil
    var body: some View {
        HStack(spacing: 0) {
            AuthBrandPanel().frame(width: 320)
            AuthFormView(style: .page, preview: preview)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Palette.surface)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.surface)
        .accessibilityElement(children: .contain)
    }
}

struct AuthBrandPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            TaskfoldMark(size: 64)
            Text("Taskfold").font(.custom(DS.Font.displayTitleFace, size: 28, relativeTo: .largeTitle)).padding(.top, 20)
            Text("A little clarity for your day.").font(.system(size: 15)).foregroundStyle(DS.Palette.textSecondary).padding(.top, 6)
            Spacer()
            Label("Works with Taskfold on iPhone and the web.", systemImage: "laptopcomputer.and.iphone")
                .font(.system(size: 11)).foregroundStyle(DS.Palette.textSecondary).labelStyle(.titleAndIcon).lineLimit(1).minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 32).padding(.vertical, 32)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.taskfold.opacity(0.06))
    }
}

extension Workspace {
    /// Opens the sign-in sheet on the main window (never on Settings) and brings that window forward.
    func presentSignIn() {
        signInRequested = true
        NSApp.activate()
        (NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
}

/// The compact 440 pt "Sign in to sync" sheet, opened on the main window from the sidebar card, the Account menu,
/// Settings and ⌘⇧L. It never asks anyone to leave the local workspace.
struct SignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    var preview: String? = nil
    var body: some View {
        AuthFormView(style: .sheet, preview: preview, cancel: { dismiss() })
            .frame(width: 440)
            .background(DS.Palette.surface)
    }
}

/// A quiet bordered button: raised ground and a hairline, so the one crimson button on the screen leads.
private struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background(DS.Palette.surfaceRaised.opacity(configuration.isPressed ? 0.6 : 1), in: .rect(cornerRadius: DS.Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 1))
            .opacity(enabled ? 1 : 0.55)
            .contentShape(.rect)
    }
}

private struct GoogleGlyph: View {
    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2, c = CGPoint(x: size.width / 2, y: size.height / 2), w = r * 0.36
            func arc(_ from: Double, _ to: Double, _ color: Color) {
                var path = Path(); path.addArc(center: c, radius: r - w / 2, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .butt))
            }
            arc(-45, 45, Color(red: 0.26, green: 0.52, blue: 0.96)) // blue (right, below the bar)
            arc(45, 135, Color(red: 0.20, green: 0.66, blue: 0.33)) // green (bottom)
            arc(135, 215, Color(red: 0.98, green: 0.74, blue: 0.02)) // yellow (left)
            arc(215, 315, Color(red: 0.92, green: 0.26, blue: 0.21)) // red (top)
            var bar = Path(); bar.addRect(CGRect(x: c.x, y: c.y - w / 2, width: r, height: w))
            context.fill(bar, with: .color(Color(red: 0.26, green: 0.52, blue: 0.96)))
        }.frame(width: 16, height: 16)
    }
}

private struct AuthNotice: Equatable {
    var text: String
    var outlines = false
    var resend = false
    var isError = true
}

struct AuthFormView: View {
    enum Style { case page, sheet }
    enum Mode { case signIn, create, resetRequest, resetCode }
    let style: Style
    var preview: String? = nil
    var cancel: (() -> Void)? = nil
    @Environment(Store.self) private var store
    @Environment(Workspace.self) private var workspace
    @Environment(\.openSettings) private var openSettings
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var code = ""
    @State private var showPassword = false
    @State private var busyEmail = false
    @State private var busyGoogle = false
    @State private var switchingLocal = false
    @State private var notice: AuthNotice?
    @State private var shake = 0
    @State private var providers = AuthProviderAvailability.unknown
    @State private var resendAvailableAt = Date.distantPast
    @State private var codeSentTo = ""
    @State private var recoveryVerified = false
    @FocusState private var focus: Field?
    enum Field { case name, email, password, code }

    init(style: Style, preview: String? = nil, cancel: (() -> Void)? = nil) {
        self.style = style; self.preview = preview; self.cancel = cancel
        var mode = Mode.signIn, email = "", password = "", notice: AuthNotice?, providers = AuthProviderAvailability.unknown, code = ""
        switch preview {
        case "error": email = "maya.lind@example.com"; password = "correct horse"; providers = .init(google: .unavailable); notice = AuthNotice(text: AuthFeedback.badCredentials.text, outlines: true)
        case "create": mode = .create; email = "maya.lind@example.com"; password = "abcdef"
        case "create-met": mode = .create; email = "maya.lind@example.com"; password = "abcdefghijkl"
        case "reset": mode = .resetCode; email = "maya.lind@example.com"; password = "correct horse"; code = "4719"
        default: break
        }
        _mode = State(initialValue: mode); _email = State(initialValue: email); _password = State(initialValue: password)
        _notice = State(initialValue: notice); _providers = State(initialValue: providers); _code = State(initialValue: code)
        _codeSentTo = State(initialValue: email)
    }

    private var heading: Font { .custom(DS.Font.screenTitleFace, size: 20, relativeTo: .title2) }
    private var busy: Bool { busyEmail || busyGoogle || switchingLocal }
    private var title: String {
        switch mode {
        case .signIn: return style == .sheet ? "Sign in to sync" : "Sign in to Taskfold"
        case .create: return "Create your account"
        case .resetRequest: return "Reset your password"
        case .resetCode: return "Check your email"
        }
    }
    private var primaryTitle: String {
        switch mode { case .signIn: return "Sign In"; case .create: return "Create Account"; case .resetRequest: return "Send Code"; case .resetCode: return "Set Password" }
    }
    private var showsGoogle: Bool { mode == .signIn || mode == .create }

    var body: some View {
        Group {
            if style == .page { pageBody } else { sheetBody }
        }
        .animation(Motion.quick, value: mode)
        .animation(Motion.quick, value: notice)
        .task {
            guard preview == nil else { return }
            providers = await store.backend.authProviders()
        }
        .onAppear { if preview == nil { focus = mode == .create ? .name : .email } }
        .onChange(of: mode) { _, _ in notice = nil; showPassword = false; if preview == nil { focus = mode == .resetCode ? .code : mode == .create ? .name : .email } }
        .background {
            Button("") { focus = .email }.keyboardShortcut("l", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
    }

    private var pageBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 14) { content }.frame(width: 300)
            Spacer(minLength: 24)
            if mode == .signIn || mode == .create { VStack(spacing: 3) {
                Button(switchingLocal ? "Opening local workspace…" : "Use Taskfold without an account", action: useLocally)
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).disabled(busy).accessibilityIdentifier("useLocally")
                Text("Tasks stay on this Mac. You can sign in later.").font(.system(size: 11)).foregroundStyle(DS.Palette.textTertiary)
            }.padding(.bottom, 28) } else { Spacer().frame(height: 28) }
        }
    }

    private var sheetBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if mode == .signIn {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(heading)
                        Text("Back up your tasks and use Taskfold on iPhone and the web.").font(.system(size: 13)).foregroundStyle(DS.Palette.textSecondary)
                    }
                    form
                    if store.localMode {
                        Label("After you sign in, you can bring the tasks on this Mac into your account.", systemImage: "laptopcomputer")
                            .font(.system(size: 12)).foregroundStyle(DS.Palette.textSecondary).padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Palette.surfaceSunken, in: .rect(cornerRadius: DS.Radius.m, style: .continuous))
                    }
                } else { content }
            }.padding(24)
            Divider()
            HStack {
                Button("Cancel") { cancel?() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButtonStyle()).disabled(busyEmail && mode != .signIn)
                Spacer()
                primaryButton(fullWidth: false)
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
    }

    @ViewBuilder private var content: some View {
        Text(title).font(heading).multilineTextAlignment(.center).padding(.bottom, 2)
        switch mode {
        case .resetRequest: resetRequestForm
        case .resetCode: resetCodeForm
        default: form
        }
    }

    // MARK: Sign in and create

    @ViewBuilder private var form: some View {
        if showsGoogle {
            VStack(spacing: 6) {
                Button { google() } label: {
                    HStack(spacing: 8) { Spacer(); if busyGoogle { ProgressView().controlSize(.small) } else { GoogleGlyph() }; Text("Continue with Google"); Spacer() }
                }
                .buttonStyle(QuietButtonStyle()).controlSize(.large).disabled(busy || !providers.googleEnabled).accessibilityIdentifier("googleSignIn")
                if !providers.googleEnabled {
                    Text(AuthProviderAvailability.googleUnavailableCaption).font(.system(size: 12)).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center)
                }
            }
            HStack(spacing: 10) {
                Rectangle().fill(DS.Palette.separator).frame(height: 1)
                Text("or").font(.system(size: 12)).foregroundStyle(DS.Palette.textTertiary)
                Rectangle().fill(DS.Palette.separator).frame(height: 1)
            }
        }
        VStack(spacing: 8) {
            if mode == .create {
                TextField("Name (optional)", text: $name).textContentType(.name).focused($focus, equals: .name).accessibilityIdentifier("authName")
            }
            TextField("Email address", text: $email).textContentType(.username).focused($focus, equals: .email).accessibilityIdentifier("authEmail")
            passwordField("Password", text: $password, field: .password, id: "authPassword", reveal: mode == .create)
                .onSubmit { submit() }
        }
        .textFieldStyle(.roundedBorder).controlSize(.large)
        .modifier(ShakeEffect(trigger: shake))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).strokeBorder(Color.red.opacity(notice?.outlines == true ? 0.7 : 0), lineWidth: 1).padding(-2))
        if mode == .create { PasswordRuleCaption(password: password) }
        noticeView
        if mode == .signIn {
            if style == .page {
                HStack { Spacer(); Button("Forgot password?") { mode = .resetRequest }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("forgotPassword") }
            }
        }
        if style == .page { primaryButton(fullWidth: true) }
        switchLinks
        if mode == .create && style == .page { privacyNote }
    }

    private var switchLinks: some View {
        Group {
            if style == .sheet && mode == .signIn {
                HStack {
                    HStack(spacing: 4) { Text("New to Taskfold?").foregroundStyle(DS.Palette.textSecondary); accentLink("Create account") { mode = .create } }
                    Spacer()
                    Button("Forgot password?") { mode = .resetRequest }.buttonStyle(.plain).foregroundStyle(DS.Palette.textSecondary).accessibilityIdentifier("forgotPassword")
                }.font(.system(size: 12))
            } else if mode == .signIn {
                HStack(spacing: 4) { Text("New to Taskfold?").foregroundStyle(DS.Palette.textSecondary); accentLink("Create account") { mode = .create } }.font(.system(size: 13))
            } else if mode == .create {
                HStack(spacing: 4) { Text("Already have an account?").foregroundStyle(DS.Palette.textSecondary); accentLink("Sign in") { mode = .signIn } }.font(.system(size: 13))
            }
        }
    }

    private var privacyNote: some View {
        (Text("Your data is described in ") + Text("Privacy").underline() + Text("."))
            .font(.system(size: 11.5)).foregroundStyle(DS.Palette.textTertiary).multilineTextAlignment(.center)
            .onTapGesture { workspace.settingsTab = .privacy; openSettings() }
    }

    private func accentLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(DS.Palette.accent).disabled(busy)
    }

    @ViewBuilder private func passwordField(_ prompt: String, text: Binding<String>, field: Field, id: String, reveal: Bool) -> some View {
        ZStack(alignment: .trailing) {
            if showPassword && reveal {
                TextField(prompt, text: text).focused($focus, equals: field).textContentType(.newPassword).accessibilityIdentifier(id)
            } else {
                SecureField(prompt, text: text).focused($focus, equals: field).textContentType(mode == .signIn ? .password : .newPassword).accessibilityIdentifier(id)
            }
            if reveal {
                Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(DS.Palette.textSecondary).frame(width: 28, height: 24) }
                    .buttonStyle(.plain).padding(.trailing, 4).accessibilityLabel(showPassword ? "Hide password" : "Show password")
            }
        }
    }

    @ViewBuilder private var noticeView: some View {
        if let notice {
            VStack(alignment: .leading, spacing: 4) {
                Label { Text(notice.text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: notice.isError ? "exclamationmark.circle" : "info.circle") }
                    .font(.system(size: 12)).foregroundStyle(notice.isError ? Color.red : DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("authMessage").transition(.textSwap)
                if notice.resend { Button("Resend confirmation email") { resendConfirmation() }.buttonStyle(.link).font(.system(size: 12)).disabled(busy) }
            }
        }
    }

    @ViewBuilder private func primaryButton(fullWidth: Bool) -> some View {
        Button { submit() } label: {
            HStack { if fullWidth { Spacer() }; if busyEmail { ProgressView().controlSize(.small) } else { Text(primaryTitle) }; if fullWidth { Spacer() } }
                .frame(minWidth: fullWidth ? nil : 64)
        }
        .buttonStyle(.borderedProminent).tint(DS.Palette.accentFill).controlSize(.large).keyboardShortcut(.defaultAction)
        .disabled(busy).accessibilityIdentifier("nativeSignIn")
    }

    // MARK: Reset

    @ViewBuilder private var resetRequestForm: some View {
        Text("Enter your email and we'll send you a 6-digit code.").font(.system(size: 13)).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center)
        TextField("Email address", text: $email).textFieldStyle(.roundedBorder).controlSize(.large).textContentType(.username)
            .focused($focus, equals: .email).onSubmit { submit() }.accessibilityIdentifier("authEmail")
        noticeView
        if style == .page { primaryButton(fullWidth: true) }
        backToSignIn
    }

    @ViewBuilder private var resetCodeForm: some View {
        Text("We sent a 6-digit code to \(RecoveryCode.masked(email: codeSentTo)). Enter it and choose a new password.")
            .font(.system(size: 13)).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        RecoveryCodeField(code: $code, focus: $focus)
        VStack(alignment: .leading, spacing: 6) {
            Text("New password").font(.system(size: 12)).foregroundStyle(DS.Palette.textSecondary)
            passwordField("New password", text: $password, field: .password, id: "authNewPassword", reveal: true)
                .textFieldStyle(.roundedBorder).controlSize(.large).onSubmit { submit() }
        }
        PasswordRuleCaption(password: password, showRemaining: false)
        noticeView
        if style == .page { primaryButton(fullWidth: true) }
        resendRow
        backToSignIn
    }

    private var resendRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let left = preview != nil ? 42 : max(0, Int(ceil(resendAvailableAt.timeIntervalSince(timeline.date))))
            HStack(spacing: 4) {
                Text("Didn't get it?").foregroundStyle(DS.Palette.textTertiary)
                if left > 0 {
                    Text("Send a new code in \(left / 60):\(String(format: "%02d", left % 60))").foregroundStyle(DS.Palette.textTertiary).monospacedDigit()
                } else {
                    Button("Send a new code") { sendCode(resend: true) }.buttonStyle(.plain).fontWeight(.medium).disabled(busy)
                }
            }.font(.system(size: 13))
        }
    }

    private var backToSignIn: some View {
        Button { mode = .signIn; password = ""; code = "" } label: { Label("Back to sign in", systemImage: "chevron.left").labelStyle(.titleAndIcon) }
            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(DS.Palette.textSecondary).disabled(busyEmail)
    }

    // MARK: Actions

    private func submit() {
        guard !busy else { return }
        switch mode {
        case .signIn, .create: authenticate()
        case .resetRequest: sendCode(resend: false)
        case .resetCode: setPassword()
        }
    }

    private var emailOK: Bool { let value = email.trimmingCharacters(in: .whitespaces); return value.contains("@") && value.contains(".") }

    private func authenticate() {
        let signup = mode == .create
        guard emailOK else { fail("Enter a valid email address.", shake: false); return }
        if signup { guard ClientHardening.passwordIsAcceptable(password) else { fail("Use \(ClientHardening.passwordRequirement) for your password."); return } }
        else { guard !password.isEmpty else { fail("Enter your password.", shake: false); return } }
        busyEmail = true; notice = nil
        let address = email.trimmingCharacters(in: .whitespaces), display = name
        Task {
            defer { busyEmail = false }
            do {
                if try await store.backend.signIn(email: address, password: password, signup: signup, displayName: display) { await finishSignIn() }
                else { mode = .signIn; password = ""; notice = AuthNotice(text: "Check your email to confirm your account, then sign in.", resend: true, isError: false) }
            } catch {
                guard let feedback = AuthFeedback.classify(error) else { return }
                notice = AuthNotice(text: feedback.text, outlines: feedback.outlinesFields, resend: feedback.offersResend); if feedback.outlinesFields { shake += 1 }
            }
        }
    }

    private func finishSignIn() async {
        await store.authenticated()
        password = ""; code = ""
        cancel?()
    }

    private func fail(_ text: String, shake bump: Bool = true) { notice = AuthNotice(text: text, outlines: false); if bump { shake += 1 } }

    private func google() {
        guard !busy else { return }
        busyGoogle = true; notice = nil
        Task {
            defer { busyGoogle = false }
            do { try await store.backend.googleOnMac(); await finishSignIn() }
            catch { if let feedback = AuthFeedback.classify(error, google: true) { notice = AuthNotice(text: feedback.text) } }
        }
    }

    private func resendConfirmation() {
        guard emailOK, !busy else { return }
        busyEmail = true
        Task {
            defer { busyEmail = false }
            do { try await store.backend.resendConfirmation(email: email); notice = AuthNotice(text: "We sent the confirmation email again.", isError: false) }
            catch { notice = AuthNotice(text: (AuthFeedback.classify(error) ?? .generic).text) }
        }
    }

    private func sendCode(resend: Bool) {
        guard emailOK else { fail("Enter a valid email address.", shake: false); return }
        busyEmail = true; notice = nil
        let address = email.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busyEmail = false }
            do {
                try await store.backend.sendPasswordReset(email: address)
                codeSentTo = address; resendAvailableAt = Date().addingTimeInterval(60); recoveryVerified = false
                if resend { code = ""; notice = AuthNotice(text: "We sent a new code.", isError: false) } else { password = ""; mode = .resetCode }
            } catch { if let feedback = AuthFeedback.classify(error) { notice = AuthNotice(text: feedback.text) } }
        }
    }

    private func setPassword() {
        guard RecoveryCode.isComplete(code) else { fail("Enter the 6-digit code from the email.", shake: false); return }
        guard ClientHardening.passwordIsAcceptable(password) else { fail("Use \(ClientHardening.passwordRequirement) for your password."); return }
        busyEmail = true; notice = nil
        Task {
            defer { busyEmail = false }
            do {
                if !recoveryVerified { try await store.backend.verifyRecovery(email: codeSentTo, code: code); recoveryVerified = true }
                try await store.backend.updateAccount(password: password)
                await finishSignIn()
            } catch {
                guard let feedback = AuthFeedback.classify(error) else { return }
                notice = AuthNotice(text: recoveryVerified && feedback == .generic ? "Couldn't save the new password. Try again." : feedback.text)
            }
        }
    }

    private func useLocally() {
        guard !switchingLocal else { return }
        switchingLocal = true; notice = nil
        let needsCredentialClear = busyEmail || busyGoogle || store.backend.session != nil
        password = "" // Local entry is not a successful password sign-in.
        Task {
            defer { switchingLocal = false }
            do {
                // Clear is ordered after any in-flight credential save and invalidates its response.
                // Enter local mode only after that clear succeeds.
                if needsCredentialClear { try await store.backend.clearSession() }
                store.startLocal()
            } catch is CancellationError { }
            catch { notice = AuthNotice(text: (AuthFeedback.classify(error) ?? .generic).text) }
        }
    }
}

/// "Use at least 10 characters." with a ring that becomes a green check once the rule is met.
struct PasswordRuleCaption: View {
    let password: String
    var showRemaining = true
    var body: some View {
        let status = PasswordRuleStatus(password)
        HStack(spacing: 6) {
            Image(systemName: status.met ? "checkmark.circle.fill" : "circle").foregroundStyle(status.met ? Color.green : DS.Palette.textTertiary)
            Text(status.text).foregroundStyle(status.met ? Color.green : DS.Palette.textSecondary)
            if showRemaining, let remaining = status.remaining { Text(remaining).foregroundStyle(DS.Palette.textTertiary) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12)).accessibilityElement(children: .combine).accessibilityIdentifier("passwordRule")
    }
}

/// Six boxes over one hidden field, so typing, pasting a whole code and deleting all behave like a normal text field.
private struct RecoveryCodeField: View {
    @Binding var code: String
    var focus: FocusState<AuthFormView.Field?>.Binding
    var body: some View {
        let digits = Array(RecoveryCode.normalized(code))
        ZStack {
            TextField("", text: Binding(get: { code }, set: { code = RecoveryCode.normalized($0) }))
                .focused(focus, equals: .code).textFieldStyle(.plain).opacity(0.01).accessibilityLabel("6-digit code").accessibilityIdentifier("authCode")
            HStack(spacing: 8) {
                ForEach(0..<RecoveryCode.length, id: \.self) { index in
                    if index == 3 { Spacer().frame(width: 6) }
                    let active = index == min(digits.count, RecoveryCode.length - 1) && focus.wrappedValue == .code
                    Text(index < digits.count ? String(digits[index]) : "")
                        .font(.system(size: 22, weight: .medium).monospacedDigit())
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(DS.Palette.surfaceRaised, in: .rect(cornerRadius: DS.Radius.s, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).strokeBorder(active ? DS.Palette.accent : DS.Palette.separator, lineWidth: active ? 1.5 : 1))
                }
            }.allowsHitTesting(false)
        }
        .contentShape(.rect).onTapGesture { focus.wrappedValue = .code }
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
    func googleOnMac(reauthenticating context: AccountReauthentication? = nil, willCommit: (() -> Void)? = nil) async throws {
        let anchor = WebAuthAnchor.shared
        guard anchor.session == nil else { throw CancellationError() }
        let attempt = try startAuthentication(reauthenticating:context,cancelBrowser: { anchor.session?.cancel(); anchor.session = nil })
        defer { endAuthentication(attempt) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppFailure(message: "Could not start secure sign-in.") }
        func encode(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let verifier = encode(Data(bytes))
        let challenge = encode(Data(SHA256.hash(data: Data(verifier.utf8))))
        guard var components = URLComponents(string: baseURL + "/auth/v1/authorize") else { throw AppFailure(message: "The Supabase configuration is missing.") }
        components.queryItems = [URLQueryItem(name: "provider", value: "google"), URLQueryItem(name: "redirect_to", value: "taskfold://auth/callback"), URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "s256")]
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
        try requireAuthentication(attempt)
        let code = try OAuthCallback.code(from: callback)
        let data = try await request("/auth/v1/token?grant_type=pkce", method: "POST", body: ["auth_code": .string(code), "code_verifier": .string(verifier)], authenticated: false)
        try requireAuthentication(attempt)
        let next = try Foundation.JSONDecoder().decode(Session.self, from: data)
        try await acceptAuthentication(next,attempt:attempt,reauthenticating:context,willCommit:willCommit)
    }
}
