import AppKit
import SwiftUI

/// The shared account is presented inside the same editor as API connections.
/// This card owns no credential, model, save, or navigation state.
struct CodexAccountSettingsView: View {
    @Environment(\.lumaxTheme) private var theme
    @Environment(\.openURL) private var openURL
    @Bindable var editor: TranslationServiceEditor
    @State private var copiedCode = false

    private var account: CodexAccountController { editor.codex }
    private var p: TranslationServicePalette { TranslationServicePalette(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if account.isCancelling {
                progress("Stopping the account request…")
            } else if account.isCommitting {
                accountHead(title: "Finishing sign-in…", spinning: true, detail: "Saving account status. Please wait.") { EmptyView() }
                detail("Sign-in is finishing. Closing this page may still leave you signed in.")
                    .padding(.top, 10)
            } else if account.operation == .login {
                loginProgress
            } else {
                switch account.status {
                case .unknown:
                    accountHead(title: "ChatGPT account", detail: "Sign-in status is not confirmed.") {
                        Button(L10n.string("Check status")) { editor.refreshCodexStatus() }
                            .buttonStyle(TranslationServiceButtonStyle(kind: .soft))
                            .disabled(account.isBusy || editor.ownsCodexOperation)
                    }
                case .signedOut:
                    accountHead(title: "Use your ChatGPT account", detail: "Sign in separately in TSX. No API key is needed.") {
                        Button(L10n.string("Sign in to ChatGPT")) { editor.signInCodex() }
                            .buttonStyle(TranslationServiceButtonStyle(kind: .soft))
                            .disabled(account.isBusy || editor.ownsCodexOperation)
                    }
                    detail("Other apps’ sign-ins are not read. OpenAI determines account eligibility and available models.").padding(.top, 10)
                case .signedIn:
                    accountHead(title: "Signed in with ChatGPT", checked: true,
                                detail: account.accountPlan.map { String(format: L10n.string("Plan: %@"), $0) }
                                    ?? L10n.string("Account confirmed. Your plan is determined by the service."), localizedDetail: true) {
                        Button(L10n.string("Sign out")) { editor.signOutCodex() }
                            .buttonStyle(TranslationServiceButtonStyle(kind: .quiet))
                            .disabled(account.operation != nil && account.operation != .translate)
                    }
                    detail("This account is shared by all Codex configurations in TSX.").padding(.top, 10)
                }
                if account.operation == .status || account.operation == .logout {
                    progress(account.operation == .status ? "Checking sign-in status…" : "Signing out of ChatGPT…").padding(.top, 9)
                }
            }
            if let error = account.error {
                TranslationServiceHint(text: error.localizedDescription, error: true).padding(.top, 10)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(p.line, lineWidth: 1).allowsHitTesting(false) }
        .onChange(of: account.deviceCode) { _, _ in copiedCode = false }
        .serviceDesignMetric("account.card")
    }

    @ViewBuilder private var loginProgress: some View {
        if let code = account.deviceCode,
           account.verificationURL?.absoluteString == "https://auth.openai.com/codex/device" {
            Text(L10n.string("Finish signing in on OpenAI’s official page"))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(p.ink)
            detail("Open the sign-in page and enter the device code below.").padding(.top, 3)
            Text(L10n.string("One-time device code")).font(.system(size: 10)).foregroundStyle(p.muted).padding(.top, 12)
            HStack(spacing: 10) {
                Text(verbatim: code).font(.system(size: 21, weight: .medium, design: .monospaced)).tracking(3)
                    .textSelection(.enabled).lineLimit(1).accessibilityLabel(L10n.string("Device code"))
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    copiedCode = NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: copiedCode ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13)).frame(width: 28, height: 28)
                }
                .buttonStyle(LumaxHoverButtonStyle()).foregroundStyle(p.muted)
                .accessibilityLabel(L10n.string(copiedCode ? "Code copied" : "Copy code"))
                .help(L10n.string(copiedCode ? "Code copied" : "Copy code"))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(p.fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(p.line, lineWidth: 1) }
            .padding(.top, 5).padding(.bottom, 11)
            HStack {
                Button {
                    if let url = URL(string: "https://auth.openai.com/codex/device") { openURL(url) }
                } label: { Label(L10n.string("Open sign-in page"), systemImage: "arrow.up.right") }
                .buttonStyle(TranslationServiceButtonStyle(kind: .primary))
                Spacer()
                if editor.ownsCodexOperation {
                    Button(L10n.string("Cancel sign-in")) { editor.cancelCodexOperation() }
                        .buttonStyle(TranslationServiceButtonStyle(kind: .quiet))
                }
            }
            progress("Waiting for you to finish in the browser…").padding(.top, 9)
        } else {
            progress("Preparing sign-in…")
            if editor.ownsCodexOperation {
                Button(L10n.string("Cancel sign-in")) { editor.cancelCodexOperation() }
                    .buttonStyle(TranslationServiceButtonStyle(kind: .quiet)).padding(.top, 8)
            }
        }
    }

    private func accountHead<Action: View>(title: String, checked: Bool = false, spinning: Bool = false,
                                           detail: String, localizedDetail: Bool = false,
                                           @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            TranslationServiceProviderMark(kind: .codex)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if spinning { ProgressView().controlSize(.mini) }
                    if checked { Image(systemName: "checkmark").font(.system(size: 13)) }
                    Text(L10n.string(title)).font(.system(size: 12, weight: .semibold))
                        .frame(minHeight: 18)
                }
                Text(localizedDetail ? detail : L10n.string(detail))
                    .font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(4.5).padding(.vertical, 2.25)
            }
            Spacer(minLength: 4)
            action().fixedSize()
        }
    }
    private func detail(_ key: String) -> some View {
        Text(L10n.string(key)).font(.system(size: 10.5)).foregroundStyle(p.muted)
            .fixedSize(horizontal: false, vertical: true).lineSpacing(3.8).padding(.vertical, 1.9)
    }
    private func progress(_ key: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(L10n.string(key)).font(.system(size: 10.5)).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(p.muted)
    }
}
