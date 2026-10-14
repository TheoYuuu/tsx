import SwiftUI

struct PermissionPromptView: View {
    static let permissionWindowSize = NSSize(width: 460, height: 400)
    static let minimumWindowSize = NSSize(width: 380, height: 360)
    static let maximumWindowSize = NSSize(width: 640, height: 520)
    let openInput: () -> Void
    let permission: SystemPermission
    let requestPermission: () -> Void
    @Environment(\.translateXTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 15) {
                        Image(systemName: permission == .accessibility ? "accessibility" : "viewfinder")
                            .font(.system(size: 27)).foregroundStyle(theme.accent)
                            .frame(width: 48, height: 48)
                            .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(permission.featureName).font(.system(size: 12)).foregroundStyle(theme.muted)
                            Text(permission.title).font(.system(size: 21, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(permission.explanation)
                        .font(.system(size: 13)).lineSpacing(3).foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 20)
                    VStack(alignment: .leading, spacing: 9) {
                        assurance(permission.triggerNote, symbol: "cursorarrow")
                        assurance(permission.privacyNote, symbol: "checkmark.shield")
                    }.padding(.top, 15)
                    Text(permission.serviceNote)
                        .font(.system(size: 12)).lineSpacing(3).foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 13)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 18)
                .translateXScrollContent()
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { inputButton; permissionButton }
                VStack(alignment: .trailing, spacing: 9) { inputButton; permissionButton }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 28).padding(.top, 4).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.isDark ? Color(white: 0.14) : .white)
        .accessibilityIdentifier("permissionPrompt")
    }

    private func assurance(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 14).padding(.top, 2).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(theme.muted)
    }

    private var inputButton: some View {
        Button(action: openInput) { Text("Use input translation").frame(minHeight: 32) }
            .buttonStyle(TranslateXButtonStyle())
            .overlay { RoundedRectangle(cornerRadius: theme.buttonRadius).strokeBorder(theme.edge, lineWidth: 0.75).allowsHitTesting(false) }
            .accessibilityIdentifier("permissionPrompt.input")
    }

    private var permissionButton: some View {
        Button(action: requestPermission) {
            HStack(spacing: 7) {
                Text("Go to System Settings")
                Image(systemName: "arrow.up.right").font(.system(size: 11)).accessibilityHidden(true)
            }.frame(minHeight: 32)
        }
        .buttonStyle(TranslateXButtonStyle(kind: .primary))
        .accessibilityIdentifier("permissionPrompt.settings")
    }
}
