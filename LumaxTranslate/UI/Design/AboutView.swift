import SwiftUI

struct AboutView: View {
    @Environment(\.lumaxTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                WindowTrafficLights().frame(width: 58, height: 14)
                Spacer()
            }
            .padding(.horizontal, 22)
            .frame(height: 43)
            LumaxBrandMark(size: 78)
            Text("TSX")
                .font(.system(size: 23, weight: .semibold))
                .padding(.top, 21)
            Text("A little clarity.")
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .padding(.top, 7)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text(verbatim: version)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.faint)
                    .padding(.top, 10)
            }
            Text("Translation, native to Mac")
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
                .padding(.top, 25)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
