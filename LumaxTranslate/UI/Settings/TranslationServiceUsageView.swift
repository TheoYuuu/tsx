import Charts
import SwiftUI

/// A service-local secondary page. Opening it only reads numeric local records.
struct TranslationServiceUsageView: View {
    @Environment(\.lumaxTheme) private var theme
    let configuration: TranslationServiceConfiguration?
    let usage: TranslationUsageStore
    var finish: () -> Void = {}
    @State private var days = 7
    @State private var purpose: TranslationUsagePresentation.PurposeFilter = .all
    @State private var chartMetric: ChartMetric = .tokens
    @State private var selectedDay: Date?
    @State private var expandedRecords: Set<UUID> = []
    @State private var clearPresented = false
    #if LUMAX_VISUAL_QA
    @Environment(\.translationServiceReviewUsageState) private var reviewState
    #endif

    private var p: TranslationServicePalette { .init(theme: theme) }
    private var records: [TranslationUsageRecord] {
        TranslationUsagePresentation.filtered(usage.records(for: configuration?.id, days: days), purpose: purpose)
    }
    private var daily: [UsageDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.completedAt) }
        var segment = 0
        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let values = grouped[date] ?? []
            let value = chartValue(values)
            if value == nil { segment += 1 }
            return UsageDay(date: date, value: value, segment: segment)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    TranslationServiceDivider()
                    if records.isEmpty { emptyState }
                    else { chart; requestList }
                    if !usage.isEnabled {
                        Label(L10n.string("Recording is paused. Existing records remain available."), systemImage: "pause.circle")
                            .font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(1).padding(.bottom, 18)
                .translationServiceScrollContent()
                .serviceDesignMetric("usage.content")
            }
            .scrollIndicators(.automatic).frame(maxHeight: .infinity, alignment: .top)
            .serviceDesignMetric("usage.scroll")
            footer
        }
        .padding(.horizontal, 36).padding(.top, 10)
        .foregroundStyle(p.ink)
        .serviceDesignMetric("usage.panel")
        .onAppear {
            #if LUMAX_VISUAL_QA
            if let reviewState, reviewState.configurationID == configuration?.id {
                days = reviewState.days
                purpose = reviewState.sampleTests ? .sampleTests : .all
                if reviewState.selectedDay != nil, let first = records.first { expandedRecords.insert(first.id) }
            }
            #endif
        }
        .onChange(of: days) { _, _ in expandedRecords = []; selectedDay = nil }
        .onChange(of: purpose) { _, _ in expandedRecords = []; selectedDay = nil }
        .alert(L10n.string("Clear this service’s local records?"), isPresented: $clearPresented) {
            Button(L10n.string("Cancel"), role: .cancel) {}
            Button(L10n.string("Clear records"), role: .destructive) { usage.clear(configurationID: configuration?.id); expandedRecords = [] }
        } message: {
            Text(L10n.string("This removes local statistics only. Your service configuration and account allowance stay unchanged."))
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button(action: finish) {
                Image(systemName: "chevron.left").font(.system(size: 15))
                    .foregroundStyle(p.muted).frame(width: 32, height: 32)
                    .background(p.fill, in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(p.line) }
            }
            .buttonStyle(LumaxHoverButtonStyle()).lumaxTooltip(L10n.string("Back to services"))
            .accessibilityLabel(L10n.string("Back to services"))
            .frame(width: 40, alignment: .leading).serviceDesignMetric("usage.back")
            Text(configuration?.name ?? L10n.string("Apple Translation"))
                .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity).accessibilityAddTraits(.isHeader)
            Color.clear.frame(width: 40, height: 1).accessibilityHidden(true)
        }.frame(height: 38).serviceDesignMetric("usage.header")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(L10n.string("Local usage")).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Picker(L10n.string("Statistics period"), selection: $days) {
                    Text(L10n.string("7 days")).tag(7)
                    Text(L10n.string("30 days")).tag(30)
                }.labelsHidden().pickerStyle(.menu).font(.system(size: 11)).controlSize(.small).tint(p.muted).frame(width: 96)
                    .serviceDesignMetric("usage.period")
                Picker(L10n.string("Request type"), selection: $purpose) {
                    ForEach(TranslationUsagePresentation.PurposeFilter.allCases) { filter in
                        Text(L10n.string(filter.title)).tag(filter)
                    }
                }.labelsHidden().pickerStyle(.menu).font(.system(size: 11)).controlSize(.small).tint(p.muted).frame(width: 122)
                    .serviceDesignMetric("usage.purpose")
            }
            HStack(spacing: 14) {
                metric("Requests", value: TranslationUsagePresentation.number(records.count))
                metric("Known tokens", value: TranslationUsagePresentation.totalTokens(records)
                    .map { TranslationUsagePresentation.decimal($0, fractionDigits: 0) } ?? "—")
                    .lumaxTooltip(String(format: L10n.string("%d of %d requests reported"),
                                        records.filter { TranslationUsagePresentation.reportedTokens($0.usage) != nil }.count, records.count)
                                  + "\n" + L10n.string("Some requests did not return usage. Totals include reported values only."))
                metric("Average duration", value: TranslationUsagePresentation.averageDuration(records)
                    .map { String(format: L10n.string("%.1f s"), $0) } ?? "—")
            }.serviceDesignMetric("usage.metrics")
        }.serviceDesignMetric("usage.summary")
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.string(title)).font(.system(size: 11)).foregroundStyle(p.muted)
            Text(value).font(.system(size: 22, weight: .semibold)).tracking(-0.4).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line").font(.system(size: 25)).foregroundStyle(p.muted)
            Text(L10n.string("No recorded requests in this period")).font(.system(size: 12, weight: .medium))
            Text(L10n.string("Statistics begin when local recording is enabled. Earlier activity cannot be recovered."))
                .font(.system(size: 11)).foregroundStyle(p.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.vertical, 34).serviceDesignMetric("usage.empty")
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.string("Usage trend")).font(.system(size: 12, weight: .medium))
                Spacer()
                Picker(L10n.string("Chart metric"), selection: $chartMetric) {
                    ForEach(ChartMetric.allCases) { metric in Text(L10n.string(metric.title)).tag(metric) }
                }.labelsHidden().pickerStyle(.menu).font(.system(size: 11)).controlSize(.small).tint(p.muted).frame(width: 114).serviceDesignMetric("usage.metric")
            }
            if chartMetric == .requests || records.contains(where: { chartValue([$0]) != nil }) {
                Chart(daily) { day in
                    if let value = day.value {
                        LineMark(x: .value(L10n.string("Day"), day.date), y: .value(L10n.string(chartMetric.title), value),
                                 series: .value("Series", day.segment))
                            .interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2))
                            .foregroundStyle(p.accent)
                            .accessibilityLabel(day.date.formatted(.dateTime.month().day().locale(L10n.currentLocale)))
                            .accessibilityValue(value.formatted(.number.locale(L10n.currentLocale)))
                    }
                    if let selectedDay, Calendar.current.isDate(day.date, inSameDayAs: selectedDay), let value = day.value {
                        RuleMark(x: .value(L10n.string("Day"), day.date)).foregroundStyle(p.muted.opacity(0.3))
                        PointMark(x: .value(L10n.string("Day"), day.date), y: .value(L10n.string(chartMetric.title), value))
                            .foregroundStyle(p.accent)
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                Text(value.formatted(.number.locale(L10n.currentLocale)))
                                    .font(.system(size: 10)).padding(5).background(p.panel, in: RoundedRectangle(cornerRadius: 5))
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: min(days, 7))) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day().locale(L10n.currentLocale)).font(.system(size: 10))
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .chartYScale(domain: 0...max(1, daily.compactMap(\.value).max() ?? 1))
                .chartXSelection(value: $selectedDay)
                .frame(height: 110).environment(\.locale, L10n.currentLocale)
            } else {
                Text(L10n.string("No reported values for this unit in the selected period."))
                    .font(.system(size: 11)).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, minHeight: 110)
            }
        }.serviceDesignMetric("usage.chart")
    }

    private var requestList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("Request history")).font(.system(size: 12, weight: .medium))
            VStack(spacing: 0) {
                requestColumns(time: L10n.string("Request time"), model: L10n.string("Model"),
                               status: L10n.string("Result"), input: L10n.string("Input"),
                               output: L10n.string("Output"), duration: L10n.string("Duration"))
                    .font(.system(size: 10)).foregroundStyle(p.muted).padding(.horizontal, 12).frame(height: 30)
                    .background(p.fill.opacity(0.8)).serviceDesignMetric("usage.tableHeader")
                LazyVStack(spacing: 0) {
                    ForEach(records) { record in
                        requestRow(record)
                        TranslationServiceDivider()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(p.line) }
        }.serviceDesignMetric("usage.requests")
    }

    private func requestColumns(time: String, model: String, status: String, input: String, output: String, duration: String) -> some View {
        HStack(spacing: 8) {
            Text(time).frame(width: 110, alignment: .leading)
            Text(model).frame(maxWidth: .infinity, alignment: .leading)
            Text(status).frame(width: 44)
            Text(input).frame(width: 48, alignment: .trailing)
            Text(output).frame(width: 48, alignment: .trailing)
            Text(duration).frame(width: 52, alignment: .trailing)
            Color.clear.frame(width: 12, height: 1)
        }.lineLimit(1)
    }

    private func requestRow(_ record: TranslationUsageRecord) -> some View {
        let expanded = expandedRecords.contains(record.id)
        return VStack(spacing: 0) {
            Button {
                if expanded { expandedRecords.remove(record.id) } else { expandedRecords.insert(record.id) }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TranslationUsagePresentation.startedAt(record).formatted(.dateTime.hour().minute().second().locale(L10n.currentLocale)))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(p.ink)
                        Text(TranslationUsagePresentation.startedAt(record).formatted(.dateTime.month().day().locale(L10n.currentLocale)) + " · " + purposeTitle(record))
                            .font(.system(size: 9)).foregroundStyle(p.muted)
                    }.frame(width: 110, alignment: .leading)
                    Text(record.model.isEmpty ? L10n.string("Apple Translation") : record.model)
                        .font(.system(size: 10)).foregroundStyle(p.ink).frame(maxWidth: .infinity, alignment: .leading)
                    Text(outcomeTitle(record)).font(.system(size: 9)).foregroundStyle(outcomeColor(record))
                        .frame(width: 44, height: 21).background(outcomeColor(record).opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
                    Text(count(record.usage?.inputTokens)).frame(width: 48, alignment: .trailing)
                    Text(count(record.usage?.outputTokens)).frame(width: 48, alignment: .trailing)
                    Text(String(format: L10n.string("%.1f s"), record.duration)).frame(width: 52, alignment: .trailing)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9)).frame(width: 12)
                }
                .font(.system(size: 10)).foregroundStyle(p.muted).monospacedDigit().lineLimit(1)
                .padding(.horizontal, 12).frame(minHeight: 52)
                .background(expanded ? p.accentSoft.opacity(0.4) : p.panel)
                .contentShape(Rectangle())
            }
            .buttonStyle(LumaxHoverButtonStyle())
            .accessibilityLabel(purposeTitle(record) + ", " + outcomeTitle(record) + ", " + record.completedAt.formatted(.dateTime.locale(L10n.currentLocale)))
            .accessibilityValue(L10n.string(expanded ? "Expanded" : "Collapsed"))
            .serviceDesignMetric("usage.row.\(record.id)")
            if expanded { requestDetails(record) }
        }
    }

    private func requestDetails(_ record: TranslationUsageRecord) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("Request information")).font(.system(size: 11, weight: .medium)).padding(.bottom, 2)
                detail("Request time", value: TranslationUsagePresentation.startedAt(record).formatted(.dateTime.year().month().day().hour().minute().second().locale(L10n.currentLocale)))
                detail("Model", value: record.model.isEmpty ? L10n.string("Apple Translation") : record.model)
                detail("Request type", value: purposeTitle(record))
                detail("Result", value: outcomeTitle(record))
                detail("Duration", value: String(format: L10n.string("%.1f s"), record.duration))
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("Usage details")).font(.system(size: 11, weight: .medium)).padding(.bottom, 2)
                detail("Input tokens", value: count(record.usage?.inputTokens))
                detail("Output tokens", value: count(record.usage?.outputTokens))
                detail("Total tokens", value: count(TranslationUsagePresentation.reportedTokens(record.usage)))
                detail("Characters", value: count(record.usage?.characters))
                Text(L10n.string("Missing counts are not zero usage."))
                    .font(.system(size: 9)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .background(p.fill.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
        .serviceDesignMetric("usage.detailsInner")
        .padding(12).background(p.panel).serviceDesignMetric("usage.details")
    }

    private func detail(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(title)).foregroundStyle(p.muted)
            Text(value).foregroundStyle(p.ink).textSelection(.enabled)
        }.font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            TranslationServiceDivider()
            HStack(spacing: 12) {
                Text(L10n.string("Numeric records only · Retained for 30 days"))
                    .font(.system(size: 10)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
                    .lumaxTooltip(L10n.string("Only TSX activity on this Mac is included. Missing usage and failed or cancelled requests do not imply zero charges."))
                Spacer()
                Button { clearPresented = true } label: { Image(systemName: "trash") }
                    .buttonStyle(TranslationServiceIconButtonStyle(destructive: true))
                    .lumaxTooltip(L10n.string("Clear records")).accessibilityLabel(L10n.string("Clear records"))
                    .disabled(usage.records(for: configuration?.id, days: 30).isEmpty)
            }.frame(minHeight: 50)
        }.serviceDesignMetric("usage.footer")
    }

    private func count(_ value: Int?) -> String { value.map(TranslationUsagePresentation.number) ?? "—" }
    private func purposeTitle(_ record: TranslationUsageRecord) -> String {
        L10n.string(record.purpose == .sampleTest ? "Sample test" : "Translation request")
    }
    private func outcomeTitle(_ record: TranslationUsageRecord) -> String {
        L10n.string(record.outcome == .succeeded ? "Succeeded" : record.outcome == .failed ? "Failed" : "Cancelled")
    }
    private func outcomeColor(_ record: TranslationUsageRecord) -> Color {
        record.outcome == .succeeded ? p.success : record.outcome == .failed ? p.error : p.muted
    }
    private func chartValue(_ records: [TranslationUsageRecord]) -> Double? {
        if chartMetric == .requests { return Double(records.count) }
        if records.isEmpty { return 0 }
        let values = records.compactMap { chartMetric == .tokens ? TranslationUsagePresentation.reportedTokens($0.usage) : $0.usage?.characters }
        return values.isEmpty ? nil : values.reduce(0) { $0 + Double($1) }
    }
    private struct UsageDay: Identifiable {
        let date: Date
        let value: Double?
        let segment: Int
        var id: Date { date }
    }
    private enum ChartMetric: String, CaseIterable, Identifiable {
        case tokens, requests, characters
        var id: String { rawValue }
        var title: String { switch self { case .tokens: "Tokens"; case .requests: "Requests"; case .characters: "Characters" } }
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
    static func reportedTokens(_ usage: TranslationUsage?) -> Int? {
        if let total = usage?.totalTokens { return total }
        guard let input = usage?.inputTokens, let output = usage?.outputTokens else { return nil }
        let total = input.addingReportingOverflow(output)
        return total.overflow ? nil : total.partialValue
    }
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

#if LUMAX_VISUAL_QA
struct TranslationServiceReviewUsageState {
    let configurationID: UUID
    var accountTab = false
    var days = 7
    var selectedDay: Date?
    var sampleTests = false
    var snapshot: TranslationAccountUsageSnapshot?
    var opensUsagePage = true
    var hoveredID: UUID?
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
