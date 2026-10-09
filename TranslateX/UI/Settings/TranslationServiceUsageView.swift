import SwiftUI

/// Service-specific query preferences, independent of the usage dashboard.
struct TranslationServiceUsageView: View {
    @Environment(\.translateXTheme) private var theme
    @Bindable var draft: TranslationAccountQueryDraft
    let accounts: TranslationAccountUsageController
    var finish: () -> Void = {}
    var saved: () -> Void = {}

    private var p: TranslationServicePalette { .init(theme: theme) }
    private var configuration: TranslationServiceConfiguration? { draft.configuration }
    private var name: String { configuration?.name ?? L10n.string("Apple Translation") }
    private var accountState: TranslationAccountUsageController.State {
        configuration.map { accounts.state(for: $0.id) } ?? .init()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: finish) { Image(systemName: "arrow.left") }
                        .buttonStyle(TranslationServiceIconButtonStyle(size: 32))
                        .translateXTooltip(L10n.string("Back to services"))
                        .accessibilityLabel(L10n.string("Back to services"))
                        .serviceDesignMetric("query.back")
                    Text(L10n.string("Configure usage query"))
                        .font(.system(size: 20, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                }.frame(minHeight: 34).padding(.bottom, 16)
                    .serviceDesignMetric("query.header")

                if draft.supportsAccountQuery { queryCard }
                else { unavailableQuery }

                recordCard.padding(.top, 12)
                if let error = draft.errorMessage {
                    TranslationServiceHint(text: error, error: true).padding(.top, 10)
                }
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text(L10n.string("Applies only to"))
                        Text(name).fontWeight(.medium)
                    }.font(.system(size: 11)).foregroundStyle(p.muted)
                    Spacer(minLength: 8)
                    Button(L10n.string("Cancel"), action: finish)
                        .buttonStyle(TranslationServiceButtonStyle())
                    Button {
                        if draft.save() { accounts.configurationDidChange(); saved() }
                    } label: { Label(L10n.string("Save configuration"), systemImage: "checkmark") }
                        .buttonStyle(TranslationServiceButtonStyle(kind: .primary))
                }.padding(.top, 14).serviceDesignMetric("query.footer")
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
            .translateXScrollContent()
        }
        .scrollIndicators(.automatic)
        .foregroundStyle(p.ink)
        .serviceDesignMetric("query.scroll")
    }

    private var queryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("Enable usage query")).font(.system(size: 12, weight: .medium))
                    Text(L10n.string(draft.enabled
                        ? "Show account allowance in the service list"
                        : "Account queries are hidden from the service list"))
                        .font(.system(size: 11)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle(L10n.string("Enable usage query"), isOn: $draft.enabled)
                    .labelsHidden().toggleStyle(TranslateXSwitchStyle())
            }.frame(minHeight: 62).padding(.top, 1)
                .serviceDesignMetric("query.enable")

            if draft.enabled {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) { intervalField; timeoutField }
                    VStack(alignment: .leading, spacing: 14) { intervalField; timeoutField }
                }
                .serviceDesignMetric("query.fields")
                HStack(spacing: 12) {
                    Image(systemName: "wallet.bifold").font(.system(size: 12)).foregroundStyle(p.muted)
                    Text(accountMessage).font(.system(size: 11)).foregroundStyle(accountState.errorMessage == nil ? p.muted : p.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        guard let configuration, let preferences = draft.validatedPreferences() else { return }
                        accounts.refresh(configuration, timeoutSeconds: preferences.timeoutSeconds)
                    } label: {
                        HStack(spacing: 5) {
                            if accountState.isLoading { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .medium)) }
                            Text(L10n.string("Query now"))
                        }
                    }.buttonStyle(TranslationServiceButtonStyle())
                        .disabled(accountState.isLoading)
                }.padding(.top, 12).padding(.bottom, 13)
                    .serviceDesignMetric("query.result")
            }
        }
        .padding(.horizontal, 17)
        .background(p.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(p.line) }
    }

    private var intervalField: some View {
        durationField("Automatic query interval", value: $draft.interval, options: draft.intervalOptions,
                      hint: draft.interval == "0" ? "Refresh manually from the service list" : "Automatic queries run while TSX is open.")
    }
    private var timeoutField: some View {
        durationField("Request timeout", value: $draft.timeout, options: draft.timeoutOptions,
                      hint: "End this query when the timeout is reached")
    }
    private func durationField(_ title: String, value: Binding<String>, options: [Int], hint: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.string(title)).font(.system(size: 11, weight: .medium))
            LanguageMenu(label: L10n.string(title), selection: value, languages: options.map {
                .init(id: String($0), name: $0 == 0 ? L10n.string("No automatic queries") : String(format: L10n.string("%d seconds"), $0))
            }, prominent: false, minimumWidth: 180)
                .fixedSize()
            Text(L10n.string(hint)).font(.system(size: 10.5)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
    }

    private var recordCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("Record local translation usage")).font(.system(size: 12, weight: .medium))
                Text(L10n.string(!draft.recordsUsage ? "New records are paused. Existing statistics are kept."
                    : configuration == nil ? "Record request counts and duration without translation content."
                    : "Record requests, tokens, costs and duration without translation content."))
                    .font(.system(size: 11)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(L10n.string("Track this service"), isOn: $draft.recordsUsage)
                .labelsHidden().toggleStyle(TranslateXSwitchStyle())
        }
        .padding(.horizontal, 17).padding(.vertical, 11).frame(minHeight: 62)
        .background(p.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(p.line) }
        .serviceDesignMetric("query.record")
    }

    private var unavailableQuery: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: configuration == nil ? "character.bubble" : "wallet.bifold")
                .font(.system(size: 18)).foregroundStyle(p.muted)
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string(configuration == nil ? "Apple Translation needs no balance query" : "Account query is unavailable for this service"))
                    .font(.system(size: 12, weight: .medium))
                Text(L10n.string(configuration == nil ? "Translate on this Mac without an account."
                    : "Local request statistics remain available. Check account allowance on the provider’s website."))
                    .font(.system(size: 11)).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(p.fill, in: RoundedRectangle(cornerRadius: 12))
    }

    private var accountMessage: String {
        if accountState.isLoading { return L10n.string("Querying account allowance") }
        if let error = accountState.errorMessage { return error }
        guard let snapshot = accountState.snapshot else { return L10n.string("Account allowance has not been queried") }
        let amount: String
        if !snapshot.balances.isEmpty {
            amount = snapshot.balances.map { TranslationUsagePresentation.decimal($0.total) + " " + $0.currency }.joined(separator: " · ")
        } else if let used = snapshot.usedCharacters {
            amount = snapshot.hasUnlimitedCharacters ? L10n.string("Unlimited") :
                snapshot.characterLimit.map { TranslationUsagePresentation.number(max(0, $0 - used)) } ?? "—"
        } else { amount = "—" }
        return amount + " · " + String(format: L10n.string("Updated %@"), snapshot.fetchedAt.formatted(.dateTime.locale(L10n.currentLocale).hour().minute()))
    }
}

/// Shared presentation rules keep filters, summaries and individual requests
/// consistent without changing stored data or making any provider requests.
nonisolated enum TranslationUsagePresentation {
    enum PurposeFilter: String, CaseIterable, Identifiable {
        case all, translations, sampleTests
        var id: String { rawValue }
        var title: String { switch self { case .all: "All requests"; case .translations: "Translations"; case .sampleTests: "Sample tests" } }
    }
    static func filtered(_ records: [TranslationUsageRecord], purpose: PurposeFilter) -> [TranslationUsageRecord] {
        records.filter { purpose == .all || (purpose == .sampleTests ? $0.purpose == .sampleTest : $0.purpose == .translation) }
            .sorted {
                let a = startedAt($0), b = startedAt($1)
                return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
            }
    }
    static func startedAt(_ record: TranslationUsageRecord) -> Date { record.completedAt.addingTimeInterval(-record.duration) }
    static func reportedTokens(_ usage: TranslationUsage?) -> Int? { usage?.reportedTokenTotal }
    static func totalTokens(_ records: [TranslationUsageRecord]) -> Decimal? {
        let values = records.compactMap { reportedTokens($0.usage) }
        return values.isEmpty ? nil : values.reduce(Decimal.zero) { $0 + Decimal($1) }
    }
    static func averageDuration(_ records: [TranslationUsageRecord]) -> TimeInterval? {
        guard !records.isEmpty else { return nil }
        return records.reduce(0) { $0 + $1.duration / Double(records.count) }
    }
    static func number(_ value: Int) -> String { value.formatted(.number.locale(L10n.currentLocale)) }
    static func decimal(_ value: Decimal, fractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = L10n.currentLocale; formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits; formatter.maximumFractionDigits = max(fractionDigits, 4)
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
    }
}

#if TRANSLATEX_VISUAL_QA
struct TranslationServiceReviewUsageState {
    let configurationID: UUID
    var accountTab = false
    var days = 7
    var selectedDay: Date?
    var sampleTests = false
    var snapshot: TranslationAccountUsageSnapshot?
    var opensUsagePage = true
    var hoveredID: UUID?
    var opensManager = false
    var expandDetails = false
}
private struct TranslationServiceReviewUsageStateKey: EnvironmentKey {
    static let defaultValue: TranslationServiceReviewUsageState? = nil
}
extension EnvironmentValues {
    var translationServiceReviewUsageState: TranslationServiceReviewUsageState? {
        get { self[TranslationServiceReviewUsageStateKey.self] }
        set { self[TranslationServiceReviewUsageStateKey.self] = newValue }
    }
}
#endif
