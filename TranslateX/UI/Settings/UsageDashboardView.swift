import SwiftUI
import Charts

/// The independent Usage navigation page owns its outer scrolling surface.
struct UsageDashboardView: View {
    let store: TranslationServiceStore
    @Environment(\.translateXTheme) private var theme
    @State private var start = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var service = "all"
    @State private var datePopover = false
    @State private var datePopoverHeight: CGFloat = 370
    @State private var metric = "requests"
    @State private var chartMode = "trend"
    @State private var selectedDay: Date?
    @State private var hoveredDay: Date?
    @State private var activeTable = "requests"
    @State private var page = 1
    @State private var pricePage = 1
    @State private var pageSize = "10"
    @State private var confirmingClear = false
    @State private var availableWidth: CGFloat = 790
    private var palette: TranslationServicePalette { .init(theme: theme) }
    private var usage: TranslationUsageStore { store.usage }
    private var calendar: Calendar { .current }
    private var snapshot: TranslationUsageDashboard {
        .init(records: usage.records, summaries: usage.summaries, start: start, end: end, service: service)
    }
    private var earliest: Date { (usage.records.map(\.completedAt) + usage.summaries.map(\.day)).min() ?? Date() }
    private var countPerPage: Int { Int(pageSize) ?? 10 }
    private var requestRows: [TranslationUsageRecord] {
        snapshot.records.filter { selectedDay == nil || calendar.isDate($0.completedAt, inSameDayAs: selectedDay!) }
    }
    private var totalPages: Int { max(1, (requestRows.count + countPerPage - 1) / countPerPage) }
    private var shownPage: Int { min(page, totalPages) }
    private var pageRows: [TranslationUsageRecord] { Array(requestRows.dropFirst((shownPage - 1) * countPerPage).prefix(countPerPage)) }
    // Reference prices are a global catalog, not a subset of the usage filter.
    private var priceRows: [TranslationModelPrice] { usage.pricing.prices.filter { $0.currency == "USD" } }
    private var pricePages: Int { max(1, (priceRows.count + countPerPage - 1) / countPerPage) }
    private var shownPricePage: Int { min(pricePage, pricePages) }
    private var visiblePrices: [TranslationModelPrice] { Array(priceRows.dropFirst((shownPricePage - 1) * countPerPage).prefix(countPerPage)) }
    private var services: [TranslationLanguage] {
        var result = [TranslationLanguage(id: "all", name: L10n.string("All services")), .init(id: "apple", name: L10n.string("Apple Translation"))]
        result += store.configurations.map { .init(id: $0.id.uuidString, name: $0.name) }
        let known = Set(store.configurations.map(\.id))
        let historical = Set(usage.records.compactMap(\.configurationID) + usage.summaries.compactMap(\.configurationID)).subtracting(known)
        result += historical.sorted { $0.uuidString < $1.uuidString }.map { id in
            .init(id: id.uuidString, name: serviceName(id: id, fallback: usage.records.first { $0.configurationID == id }?.serviceName))
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                cards
                chart
                tableSection
                clearSection
            }
            .font(.system(size: 12)).foregroundStyle(palette.ink)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { availableWidth = $0 }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .translateXScrollContent(overlayVerticalIndicator: true)
        }
        // SwiftUI must not reserve its system-style gutter. The shared AppKit
        // anchor owns the draggable overlay indicator independently of layout.
        .scrollIndicators(.never, axes: .vertical)
        .disabled(confirmingClear || datePopover)
        .overlayPreferenceValue(TranslationServicePopupAnchorKey.self) { anchors in
            GeometryReader { geometry in
                if datePopover, let anchor = anchors["usage.date"] {
                    dateOverlay(anchor: geometry[anchor], size: geometry.size)
                }
            }
        }
        .overlay { if confirmingClear { clearConfirmation } }
        .onChange(of: start) { resetRange() }
        .onChange(of: end) { resetRange() }
        .onChange(of: service) { resetRange(); pricePage = 1; confirmingClear = false }
        .onChange(of: pageSize) { page = 1; pricePage = 1 }
        .onChange(of: selectedDay) { page = 1 }
        .onDisappear { confirmingClear = false; datePopover = false }
        .onExitCommand { datePopover = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in datePopover = false }
        .accessibilityIdentifier("settings.usage.page")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { title; Spacer(minLength: 10); filters }
            VStack(alignment: .leading, spacing: 12) { title; filters }
        }
    }
    private var title: some View { Text(L10n.string("Usage statistics")).font(.system(size: 22, weight: .semibold)).fixedSize() }
    private var filters: some View {
        HStack(spacing: 8) {
            Button { datePopover.toggle() } label: {
                HStack(spacing: 7) { Image(systemName: "calendar"); Text(dateRangeLabel) }
            }
            .buttonStyle(TranslationServiceButtonStyle()).fixedSize()
            .translationServicePopupAnchor("usage.date")
            LanguageMenu(label: L10n.string("Service"), selection: $service, languages: services, prominent: false, minimumWidth: 116)
                .fixedSize().accessibilityIdentifier("settings.usage.service")
        }
    }
    private func dateOverlay(anchor: CGRect, size: CGSize) -> some View {
        let frame = UsageDatePopoverLayout.frame(anchor: anchor,
            contentSize: CGSize(width: UsageDatePopoverLayout.preferredWidth, height: datePopoverHeight), containerSize: size)
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { datePopover = false }
            ScrollView {
                UsageDateRangePicker(start: start, end: end, earliest: earliest, width: frame.width) { first, last in
                    start = first; end = last; datePopover = false
                } cancel: { datePopover = false }
                    .contentShape(RoundedRectangle(cornerRadius: 13)).onTapGesture { }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { datePopoverHeight = $0 }
                    .translateXScrollContent()
            }
            .frame(width: frame.width, height: frame.height)
            .background(palette.popover, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.24 : 0.12), radius: 16, y: 5)
            .offset(x: frame.minX, y: frame.minY)
        }.accessibilityElement(children: .contain)
    }
    private var dateRangeLabel: String {
        let count = (calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0) + 1
        if calendar.isDateInToday(end), [7, 30, 90].contains(count) { return String(format: L10n.string("Last %d days"), count) }
        return shortDate(start) + " – " + shortDate(end)
    }
    private var cards: some View {
        let data = snapshot
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: availableWidth < 480 ? 1 : 3), spacing: 10) {
            metricCard("Total cost", icon: "dollarsign.circle") {
                if let amount = data.api.requests == 0 ? Decimal(0) : data.api.costs?["USD"] {
                    Text(UsageCostFormat.compact(amount) + (hasIncompleteCost ? " *" : ""))
                        .font(.system(size: 24, weight: .semibold, design: .rounded)).minimumScaleFactor(0.75)
                } else {
                    Text(L10n.string("Unpriced")).font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.muted).frame(height: 29, alignment: .leading)
                }
            }.translateXTooltip(totalCostHint)
            metricCard("Total requests", icon: "arrow.up.arrow.down.circle") {
                Text(number(data.all.requests)).font(.system(size: 24, weight: .semibold, design: .rounded))
            }.translateXTooltip(String(format: L10n.string("%d local · %d API requests"), data.all.requests - data.api.requests, data.api.requests))
            metricCard("Consumed Tokens", icon: "circle.hexagongrid") {
                Text(data.api.totalTokens.map { decimal($0) + (data.unknownTokens > 0 ? " *" : "") } ?? "—")
                    .font(.system(size: 24, weight: .semibold, design: .rounded)).minimumScaleFactor(0.8)
            }.translateXTooltip(L10n.string("API-reported tokens only. Apple Translation does not provide token counts. * indicates a known subtotal."))
        }
    }
    private var hasIncompleteCost: Bool {
        snapshot.unknownCosts > 0 || (snapshot.api.costs ?? [:]).keys.contains { $0 != "USD" }
    }
    private var totalCostHint: String {
        let amount = snapshot.api.requests == 0 ? Decimal(0) : snapshot.api.costs?["USD"]
        return (amount.map { UsageCostFormat.precise($0) + "\n" } ?? "")
            + L10n.string("Estimated in dollars, not a bill. Missing rates or usage are excluded; * marks a known subtotal.")
    }
    private var metricCardHeight: CGFloat { 72 }
    private func metricCard<C: View>(_ label: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { Image(systemName: icon).font(.system(size: 13, weight: .regular)).frame(width: 16, height: 16).foregroundStyle(palette.accent); Text(L10n.string(label)).foregroundStyle(palette.muted) }
                .font(.system(size: 11, weight: .medium))
            content().lineLimit(1).monospacedDigit()
        }.padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: metricCardHeight, maxHeight: metricCardHeight, alignment: .leading)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack { chartModeControl; Spacer(); chartFilters }
                VStack(alignment: .leading, spacing: 8) { chartModeControl; chartFilters }
            }
            if chartMode == "trend" { trendChart } else { heatmap }
        }
        .padding(14).background(palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
    }
    private var chartModeControl: some View {
        HStack(spacing: 3) { smallTab("Bar chart", key: "trend", selected: $chartMode); smallTab("Heatmap", key: "heat", selected: $chartMode) }
            .padding(3).background(palette.fill, in: RoundedRectangle(cornerRadius: 7))
    }
    private var chartFilters: some View {
        HStack(spacing: 8) {
            LanguageMenu(label: L10n.string("Metric"), selection: $metric, languages: UsageChartMetric.allCases.map { .init(id: $0.rawValue, name: $0.title) }, prominent: false, minimumWidth: 103).fixedSize()
        }
    }
    private func smallTab(_ label: String, key: String, selected: Binding<String>) -> some View {
        Button { selected.wrappedValue = key } label: {
            Text(L10n.string(label)).font(.system(size: 11, weight: selected.wrappedValue == key ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(selected.wrappedValue == key ? palette.accent : palette.muted)
                .background(selected.wrappedValue == key ? palette.panel : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).translateXControlCursor()
    }
    private var dates: [Date] {
        let first = calendar.startOfDay(for: start), last = calendar.startOfDay(for: end)
        let count = max(0, calendar.dateComponents([.day], from: first, to: last).day ?? 0)
        // The date picker excludes pre-Unix/future ranges. Iteration remains finite.
        return (0...count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }
    private func valuesByDay() -> [Date: TranslationUsageDashboard.Day] { Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.date, $0) }) }
    private var chartMetric: UsageChartMetric { UsageChartMetric(rawValue: metric) ?? .requests }
    private func chartValue(_ day: TranslationUsageDashboard.Day?) -> Double? {
        chartMetric.value(in: day).map { NSDecimalNumber(decimal: $0).doubleValue }
    }
    private struct Point: Identifiable { let date: Date; let value: Double; var id: Date { date } }
    private var points: [Point] {
        let byDay = valuesByDay()
        return dates.compactMap { date in
            chartValue(byDay[date]).map { Point(date: date, value: $0) }
        }
    }
    private func chartDetail(_ date: Date) -> String {
        let day = valuesByDay()[date]
        let value = chartMetric.value(in: day)
        let text = value.map { chartMetric == .fees ? UsageCostFormat.precise($0) : decimal($0) }
            ?? L10n.string(chartMetric == .fees ? "Unpriced" : "Not reported")
        return chartMetric.title + "  " + text + (value != nil && chartMetric.isPartial(in: day) ? " *" : "")
    }
    private var chartFootnote: String {
        let data = snapshot
        if metric == "fees" {
            if data.api.requests == 0 && data.all.requests > 0 { return L10n.string("Local translation is free and has no token pricing.") }
            return L10n.string("Dollar estimates · not the provider bill")
                + (data.unknownCosts > 0 ? " · " + L10n.string("Known subtotals only; unreported values are excluded.") : "")
        }
        if metric == "tokens" {
            return L10n.string("API-reported tokens · Apple Translation is not applicable")
                + (data.unknownTokens > 0 ? " · " + L10n.string("Known subtotals only; unreported values are excluded.") : "")
        }
        return L10n.string("Includes translations and connection tests")
    }
    private var trendChart: some View {
        let chartPoints = points
        let first = calendar.startOfDay(for: start)
        let afterLast = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        return VStack(alignment: .leading, spacing: 5) {
            Chart(chartPoints) { point in
                BarMark(x: .value("Date", point.date, unit: .day), y: .value("Value", point.value), width: .ratio(0.65))
                    .cornerRadius(2)
                    .foregroundStyle(palette.accent.opacity(hoveredDay == nil || hoveredDay == point.date ? 1 : 0.45))
                    .accessibilityLabel(point.date.formatted(.dateTime.year().month().day().locale(L10n.currentLocale)))
                    .accessibilityValue(chartDetail(point.date))
            }
            .chartXScale(domain: first...afterLast)
            .chartYScale(domain: 0...max(chartMetric == .fees ? 0.0001 : 1, (chartPoints.map(\.value).max() ?? 0) * 1.12))
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: max(1, dates.count / 5))) { _ in
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: false).font(.system(size: 11))
            } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(palette.line); AxisValueLabel().font(.system(size: 11)) } }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let plot = geometry[anchor]
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard plot.contains(location), let date: Date = proxy.value(atX: location.x - plot.minX),
                                          date >= first, date < afterLast else { hoveredDay = nil; return }
                                    hoveredDay = calendar.startOfDay(for: date)
                                case .ended: hoveredDay = nil
                                }
                            }
                        if let date = hoveredDay,
                           let midpoint = calendar.date(byAdding: .hour, value: 12, to: date),
                           let x = proxy.position(forX: midpoint) {
                            let tooltipWidth = min(230.0, plot.width)
                            let center = min(max(plot.minX + x, plot.minX + tooltipWidth / 2), plot.maxX - tooltipWidth / 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(date.formatted(.dateTime.year().month().day().locale(L10n.currentLocale))).foregroundStyle(palette.muted)
                                Text(chartDetail(date)).fontWeight(.medium).monospacedDigit()
                            }
                            .font(.system(size: 11)).foregroundStyle(palette.ink)
                            .padding(10).frame(width: tooltipWidth, alignment: .leading)
                            .background(palette.popover, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line, lineWidth: 1))
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                            .position(x: center, y: plot.minY + 29).allowsHitTesting(false)
                        }
                    }
                }
            }
            .chartLegend(.hidden).frame(height: 150)
            .onChange(of: metric) { hoveredDay = nil }
            .onChange(of: start) { hoveredDay = nil }
            .onChange(of: end) { hoveredDay = nil }
            .onDisappear { hoveredDay = nil }
            Text(chartFootnote).font(.system(size: 11)).foregroundStyle(palette.muted)
        }
    }
    private var heatmap: some View {
        let byDay = valuesByDay(), allDates = dates
        let maxValue = max(1, allDates.compactMap { chartValue(byDay[$0]) }.max() ?? 1)
        let leading = allDates.first.map { (calendar.component(.weekday, from: $0) - calendar.firstWeekday + 7) % 7 } ?? 0
        let slots = leading + allDates.count
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { offset in
                            Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + offset) % 7]).font(.system(size: 11)).foregroundStyle(palette.muted).frame(width: 13, height: 14)
                        }
                    }
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(14), spacing: 4), count: 7), spacing: 4) {
                        ForEach(0..<slots, id: \.self) { index in
                            if index < leading { Color.clear.frame(width: 14, height: 14) }
                            else { heatCell(allDates[index - leading], value: chartValue(byDay[allDates[index - leading]]), maximum: maxValue) }
                        }
                    }.frame(height: 122)
                }.frame(minWidth: max(0, availableWidth - 30), alignment: .center).padding(.vertical, 1)
                    .translateXScrollContent()
            }.scrollIndicators(.automatic)
            HStack(spacing: 6) {
                Text(shortDate(start)); Spacer(); Text(L10n.string("Less"))
                ForEach(0..<4, id: \.self) { level in RoundedRectangle(cornerRadius: 2).fill(level == 0 ? palette.fill : palette.accent.opacity(Double(level) / 3)).frame(width: 10, height: 10) }
                Text(L10n.string("More")); Spacer(); Text(shortDate(end))
            }.font(.system(size: 11)).foregroundStyle(palette.muted)
            Text(chartFootnote + " · " + L10n.string("Select a day to filter request records")).font(.system(size: 11)).foregroundStyle(palette.muted)
        }
    }
    private func heatCell(_ date: Date, value: Double?, maximum: Double) -> some View {
        Button { selectedDay = selectedDay == date ? nil : date } label: {
            RoundedRectangle(cornerRadius: 3).fill(value.map { $0 == 0 ? palette.fill : palette.accent.opacity(0.22 + 0.78 * $0 / maximum) } ?? palette.line)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(selectedDay == date ? palette.ink : .clear, lineWidth: 1.5)).frame(width: 14, height: 14)
        }.buttonStyle(.plain).translateXControlCursor()
            .translateXTooltip(shortDate(date) + " · " + chartDetail(date))
            .accessibilityLabel(shortDate(date))
    }

    private var tableSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack { tableTabs; Spacer(); tableAction }
                VStack(alignment: .leading, spacing: 8) { tableTabs; tableAction }
            }
            if activeTable == "requests" {
                if let selectedDay {
                    HStack { Text(String(format: L10n.string("Requests on %@"), shortDate(selectedDay))); Spacer(); Button(L10n.string("Show all dates")) { self.selectedDay = nil }.buttonStyle(TranslationServiceButtonStyle(kind: .quiet)) }
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                requestTable
                pagination(count: requestRows.count, current: shownPage, pages: totalPages, setPage: { page = $0 })
                Text(L10n.string("Note: a dash means not applicable or not reported. Dollar estimates are for reference; no translation text is stored."))
                    .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                if snapshot.summarizedRequests > 0 {
                    Text(L10n.string("Earlier requests remain in totals and charts as daily summaries; individual records are unavailable."))
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                }
            } else {
                pricingTable
                pagination(count: priceRows.count, current: shownPricePage, pages: pricePages, setPage: { pricePage = $0 })
                Text(L10n.string("models.dev reference · $ per 1M Tokens. Matches official OpenAI, Anthropic and DeepSeek services. Missing recent costs use current reference rates; existing costs stay unchanged."))
                    .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                if usage.pricing.failed { Text(L10n.string("Prices could not be refreshed. Existing reference rates are unchanged.")) .foregroundStyle(palette.error).font(.system(size: 11)) }
            }
        }
    }
    private var tableTabs: some View {
        HStack(spacing: 4) { smallTab("Request records", key: "requests", selected: $activeTable); smallTab("Pricing", key: "pricing", selected: $activeTable) }
            .padding(3).background(palette.fill, in: RoundedRectangle(cornerRadius: 7)).fixedSize()
    }
    @ViewBuilder private var tableAction: some View {
        if activeTable == "pricing" {
            Button { Task { await usage.refreshPrices() } } label: {
                HStack(spacing: 6) {
                    if usage.pricing.loading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.triangle.2.circlepath") }
                    Text(L10n.string(usage.pricing.loading ? "Fetching prices" : "Update model prices"))
                }
            }.buttonStyle(TranslationServiceButtonStyle()).disabled(usage.pricing.loading)
                .translateXTooltip(L10n.string("Update official text-model reference prices from models.dev. Reseller duplicates and non-text models are excluded. No account information is sent."))
        } else { Text(String(format: L10n.string("%d records"), requestRows.count)).font(.system(size: 11)).foregroundStyle(palette.muted) }
    }
    private var requestTable: some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                requestHeader
                if pageRows.isEmpty { emptyState("No request records in this range", icon: "chart.bar.xaxis") }
                ForEach(pageRows) { record in requestRow(record); if record.id != pageRows.last?.id { Rectangle().fill(palette.line).frame(height: 1) } }
            }.frame(width: max(650, availableWidth - 2)).translateXScrollContent()
        }.scrollIndicators(.automatic).background(palette.panel, in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.line, lineWidth: 1))
    }
    private var requestColumnWidths: [CGFloat] {
        let space = max(650, availableWidth - 2) - 28
        return [0.18, 0.28, 0.19, 0.17, 0.095, 0.085].map { space * $0 }
    }
    private var requestHeader: some View {
        let widths = requestColumnWidths
        return HStack(spacing: 0) {
            tableLabel("Time", width: widths[0]); tableLabel("Service / model", width: widths[1]); tableLabel("Input / output Token", width: widths[2], alignment: .trailing)
            tableLabel("Estimated fees", width: widths[3], alignment: .trailing); tableLabel("Duration", width: widths[4], alignment: .trailing); tableLabel("Status", width: widths[5], alignment: .trailing)
        }.padding(.horizontal, 14).frame(height: 32).background(palette.fill)
    }
    private func requestRow(_ record: TranslationUsageRecord) -> some View {
        let widths = requestColumnWidths
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.completedAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())).monospacedDigit()
                Text(shortDate(record.completedAt) + (record.purpose == .sampleTest ? " · " + L10n.string("Test") : "")).font(.system(size: 11)).foregroundStyle(palette.muted)
            }.frame(width: widths[0], alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(serviceName(id: record.configurationID, fallback: record.serviceName)).lineLimit(1)
                Text(record.configurationID == nil ? L10n.string("Local") : record.model.isEmpty ? "—" : record.model).font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
            }.frame(width: widths[1], alignment: .leading)
                .translateXTooltip(record.model)
            Text(record.configurationID == nil ? "— / —" : token(record.usage?.inputTokens) + " / " + token(record.usage?.outputTokens))
                .monospacedDigit().frame(width: widths[2], alignment: .trailing)
                .translateXTooltip(L10n.string(record.configurationID == nil ? "Apple Translation does not provide token counts." : "Token counts reported by the API. A dash means the service did not report a value."))
            VStack(alignment: .trailing, spacing: 3) {
                Text(UsageCostFormat.compact(record.estimatedUSD)).monospacedDigit()
                if record.configurationID == nil {
                    Text(L10n.string("Free")).font(.system(size: 11)).foregroundStyle(palette.muted)
                } else if record.priceBackfilled == true {
                    Text(L10n.string("Recalculated estimate")).font(.system(size: 10)).foregroundStyle(palette.muted)
                }
            }.frame(width: widths[3], alignment: .trailing)
                .translateXTooltip(costHint(record))
            Text(String(format: "%.2fs", record.duration)).monospacedDigit().frame(width: widths[4], alignment: .trailing)
            Text(record.httpStatus.map(String.init) ?? "—").monospacedDigit()
                .foregroundStyle(record.httpStatus.map { (200..<300).contains($0) ? palette.success : palette.error } ?? palette.muted)
                .frame(width: widths[5], alignment: .trailing)
                .translateXTooltip(L10n.string(record.configurationID == nil ? "Local translation does not use HTTP." : record.httpStatus == nil ? "No HTTP response code was recorded." : "HTTP response code returned by the service."))
        }.padding(.horizontal, 14).frame(height: 52).font(.system(size: 11))
    }
    private var pricingTable: some View {
        let width = max(650, availableWidth - 2), content = width - 28
        let columns: [CGFloat] = [0.40, 0.15, 0.15, 0.15, 0.15].map { content * $0 }
        return ScrollView(.horizontal) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    tableLabel("Model", width: columns[0]); tableLabel("Input", width: columns[1], alignment: .trailing); tableLabel("Output", width: columns[2], alignment: .trailing); tableLabel("Cache read", width: columns[3], alignment: .trailing); tableLabel("Cache write", width: columns[4], alignment: .trailing)
                }.padding(.horizontal, 14).frame(height: 32).background(palette.fill)
                if visiblePrices.isEmpty { emptyState("Fetch reference prices to populate this catalog", icon: "tag") }
                ForEach(visiblePrices) { price in
                    HStack(spacing: 0) {
                        Text(price.model).lineLimit(1)
                            .frame(width: columns[0], alignment: .leading).translateXTooltip(price.model)
                        ForEach(Array([Optional(price.input), price.output, price.cacheRead, price.cacheWrite].enumerated()), id: \.offset) { index, value in
                            Text(value.map { UsageCostFormat.compact($0) } ?? "—").monospacedDigit().frame(width: columns[index + 1], alignment: .trailing)
                                .translateXTooltip(value.map { UsageCostFormat.precise($0) + " / 1M Tokens" } ?? L10n.string("Not reported"))
                        }
                    }.font(.system(size: 11)).padding(.horizontal, 14).frame(height: 38)
                    if price.id != visiblePrices.last?.id { Rectangle().fill(palette.line).frame(height: 1) }
                }
            }.frame(width: width).translateXScrollContent()
        }.scrollIndicators(.automatic).background(palette.panel, in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.line, lineWidth: 1))
    }
    private func tableLabel(_ title: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(L10n.string(title)).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.muted).lineLimit(1).frame(width: width, alignment: alignment)
    }
    private func emptyState(_ title: String, icon: String) -> some View {
        VStack(spacing: 9) { Image(systemName: icon).font(.system(size: 22)).foregroundStyle(palette.accent); Text(L10n.string(title)).foregroundStyle(palette.muted) }
            .frame(maxWidth: .infinity).frame(height: 110)
    }
    private func pagination(count: Int, current: Int, pages: Int, setPage: @escaping (Int) -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { paginationCount(count: count, current: current); Spacer(); paginationControls(current: current, pages: pages, setPage: setPage) }
            VStack(alignment: .leading, spacing: 7) { paginationCount(count: count, current: current); paginationControls(current: current, pages: pages, setPage: setPage) }
        }
    }
    private func paginationCount(count: Int, current: Int) -> some View {
        HStack(spacing: 7) {
            Text(count == 0 ? String(format: L10n.string("%d records"), 0) : String(format: L10n.string("%d–%d of %d"), (current - 1) * countPerPage + 1, min(count, current * countPerPage), count))
            LanguageMenu(label: L10n.string("Rows per page"), selection: $pageSize, languages: ["5", "10", "20"].map { .init(id: $0, name: String(format: L10n.string("%@ / page"), $0)) }, prominent: false, minimumWidth: 82).fixedSize()
        }.font(.system(size: 11)).foregroundStyle(palette.muted)
    }
    private func paginationControls(current: Int, pages: Int, setPage: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 5) {
            Button { setPage(max(1, current - 1)) } label: { Image(systemName: "chevron.left") }.buttonStyle(TranslationServiceIconButtonStyle(size: 27)).disabled(current == 1).accessibilityLabel(L10n.string("Previous page"))
            ForEach(Array(Set([1, max(1, current - 1), current, min(pages, current + 1), pages])).sorted(), id: \.self) { item in
                Button { setPage(item) } label: { Text(String(item)).font(.system(size: 11, weight: current == item ? .semibold : .regular)).frame(minWidth: 25, minHeight: 27).background(current == item ? palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 5)) }
                    .buttonStyle(.plain).foregroundStyle(current == item ? palette.accent : palette.muted).translateXControlCursor().disabled(current == item)
            }
            Text("/ \(pages)").font(.system(size: 11)).foregroundStyle(palette.muted)
            Button { setPage(min(pages, current + 1)) } label: { Image(systemName: "chevron.right") }.buttonStyle(TranslationServiceIconButtonStyle(size: 27)).disabled(current == pages).accessibilityLabel(L10n.string("Next page"))
        }
    }
    private var clearSection: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("Statistics data")).font(.system(size: 12, weight: .medium))
                Text(L10n.string(service == "all" ? "Clear all local statistics, keeping service settings." : "Clear this service's statistics, keeping its settings."))
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            Spacer(minLength: 8)
            Button(L10n.string("Clear statistics")) { confirmingClear = true }
                .buttonStyle(TranslateXTextButtonStyle(destructive: true))
                .fixedSize()
                .disabled(service == "all" ? !usage.hasStatistics : !usage.hasStatistics(for: UUID(uuidString: service)))
        }
        .padding(14).frame(maxWidth: .infinity)
        .background(palette.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .padding(.top, 6)
    }
    private var clearConfirmation: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea().contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "trash").foregroundStyle(palette.error).font(.system(size: 20))
                    Text(L10n.string("Clear statistics")).font(.system(size: 17, weight: .semibold))
                }
                Text(L10n.string(service == "all" ? "Clear all usage statistics? This cannot be undone." : "Clear all statistics for this service? This cannot be undone."))
                    .font(.system(size: 12)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(L10n.string("Cancel")) { confirmingClear = false }.buttonStyle(TranslationServiceButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(L10n.string("Clear statistics")) {
                        if service == "all" { usage.clearAll() } else { usage.clear(configurationID: UUID(uuidString: service)) }
                        confirmingClear = false; page = 1
                    }.buttonStyle(TranslationServiceButtonStyle(kind: .danger))
                }
            }.padding(22).frame(width: min(380, max(230, availableWidth)))
                .background(palette.popover, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.14), radius: 22, y: 10)
        }.foregroundStyle(palette.ink).accessibilityAddTraits(.isModal)
    }
    private func resetRange() { page = 1; selectedDay = nil }
    private func serviceName(id: UUID?, fallback: String? = nil) -> String {
        guard let id else { return L10n.string("Apple Translation") }
        return store.configurations.first { $0.id == id }?.name ?? fallback ?? usage.summaries.first { $0.configurationID == id }?.serviceName ?? L10n.string("Removed service")
    }
    private func number(_ value: Int) -> String { value.formatted(.number.locale(L10n.currentLocale)) }
    private func token(_ value: Int?) -> String { value.map(number) ?? "—" }
    private func decimal(_ value: Decimal, digits: Int = 0) -> String { value.formatted(.number.precision(.fractionLength(0...digits)).locale(L10n.currentLocale)) }
    private func costHint(_ record: TranslationUsageRecord) -> String {
        if record.configurationID == nil { return L10n.string("Local translation is free and has no token pricing.") }
        guard let amount = record.estimatedUSD else {
            return L10n.string("Missing prices or usage are not counted as zero. This estimate is not the provider's billed amount.")
        }
        let basis = record.priceBackfilled == true
            ? L10n.string("Estimated using the current service and reference rate, not a historical bill.")
            : L10n.string("Estimated using the rate saved with this request.")
        return UsageCostFormat.precise(amount) + "\n" + basis
    }
    private func shortDate(_ date: Date) -> String { date.formatted(.dateTime.month(.defaultDigits).day().locale(L10n.currentLocale)) }
}

private struct UsageDateRangePicker: View {
    @Environment(\.translateXTheme) private var theme
    @State private var range: UsageDateRangeSelection
    @State private var month: Date
    @State private var endpoint: UsageDateRangeSelection.Endpoint = .start
    @State private var selectedPreset: Int?
    let earliest: Date
    let width: CGFloat
    let apply: (Date, Date) -> Void
    let cancel: () -> Void
    private var palette: TranslationServicePalette { .init(theme: theme) }
    private var calendar: Calendar { range.calendar }
    private var monthStart: Date { calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month }
    private var calendarHeight: CGFloat { UsageDatePopoverLayout.calendarHeight(weeks: calendarDays.count / 7) }
    private var calendarDays: [Date] {
        let leading = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let cells = ((leading + count + 6) / 7) * 7
        return (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0 - leading, to: monthStart) }
    }

    init(start: Date, end: Date, earliest: Date, width: CGFloat = UsageDatePopoverLayout.preferredWidth, apply: @escaping (Date, Date) -> Void, cancel: @escaping () -> Void) {
        let draft = UsageDateRangeSelection(start: start, end: end)
        _range = State(initialValue: draft)
        _month = State(initialValue: draft.end)
        let count = (draft.calendar.dateComponents([.day], from: draft.start, to: draft.end).day ?? 0) + 1
        let preset = draft.end == draft.maximumDate && [1, 7, 14, 30, 90].contains(count) ? count : nil
        _selectedPreset = State(initialValue: preset)
        self.earliest = earliest; self.width = width; self.apply = apply; self.cancel = cancel
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 5) {
                ForEach([1, 7, 14, 30, 90, 0], id: \.self) { days in presetButton(days) }
            }
            HStack(alignment: .top, spacing: UsageDatePopoverLayout.columnGap) {
                VStack(spacing: UsageDatePopoverLayout.endpointGap) {
                    dateEndpoint(.start, title: "Start date")
                    dateEndpoint(.end, title: "End date")
                }.frame(width: UsageDatePopoverLayout.endpointWidth, height: calendarHeight)
                calendarPanel
            }
            HStack(spacing: 8) {
                Text(L10n.string(endpoint == .start ? "Choose the start date" : "Choose the end date"))
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
                Spacer(minLength: 4)
                Button(L10n.string("Cancel"), action: cancel).buttonStyle(TranslationServiceButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L10n.string("Apply")) { apply(range.start, range.end) }
                    .buttonStyle(TranslationServiceButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }.padding(UsageDatePopoverLayout.outerPadding).frame(width: width)
            .background(palette.popover, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(palette.line, lineWidth: 1))
            .foregroundStyle(palette.ink)
    }

    private var calendarPanel: some View {
        VStack(spacing: UsageDatePopoverLayout.calendarSectionGap) {
            HStack {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(TranslationServiceIconButtonStyle(size: 27))
                    .disabled(monthStart <= range.minimumDate).accessibilityLabel(L10n.string("Previous month"))
                Spacer()
                Text(month.formatted(.dateTime.year().month(.wide).locale(L10n.currentLocale))).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(TranslationServiceIconButtonStyle(size: 27))
                    .disabled(calendar.isDate(month, equalTo: range.maximumDate, toGranularity: .month))
                    .accessibilityLabel(L10n.string("Next month"))
            }.frame(height: UsageDatePopoverLayout.calendarHeaderHeight)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: UsageDatePopoverLayout.calendarRowGap), count: 7), spacing: UsageDatePopoverLayout.calendarRowGap) {
                ForEach(0..<7, id: \.self) { index in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7])
                        .font(.system(size: 11)).foregroundStyle(palette.muted).frame(height: UsageDatePopoverLayout.weekdayHeight)
                }
                ForEach(calendarDays, id: \.self) { dateButton($0) }
            }
        }
        .padding(UsageDatePopoverLayout.endpointPadding)
        .frame(maxWidth: .infinity).frame(height: calendarHeight)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line, lineWidth: 1))
    }

    private func presetButton(_ days: Int) -> some View {
        Button {
            range.preset(days: days == 0 ? nil : days, earliest: earliest)
            selectedPreset = days; month = range.end; endpoint = .start
        } label: {
            Text(days == 0 ? L10n.string("All time") : days == 1 ? L10n.string("Today") : String(format: L10n.string("%dd"), days))
                .font(.system(size: 11, weight: selectedPreset == days ? .semibold : .regular))
                .foregroundStyle(selectedPreset == days ? palette.accent : palette.muted)
                .frame(maxWidth: .infinity).frame(height: 29)
                .background(selectedPreset == days ? palette.accentSoft : palette.fill, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).translateXControlCursor()
            .accessibilityAddTraits(selectedPreset == days ? .isSelected : [])
    }

    private func dateEndpoint(_ field: UsageDateRangeSelection.Endpoint, title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { endpoint = field; month = range.date(for: field) } label: {
                HStack(spacing: 5) {
                    Text(L10n.string(title)).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "calendar").font(.system(size: 11))
                }.foregroundStyle(endpoint == field ? palette.accent : palette.muted)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).translateXControlCursor()
            HStack(spacing: UsageDatePopoverLayout.componentGap) {
                componentMenu(.year, for: field, title: "Date year")
                componentMenu(.month, for: field, title: "Date month")
                componentMenu(.day, for: field, title: "Date day")
            }
        }.padding(UsageDatePopoverLayout.endpointPadding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(endpoint == field ? palette.accentSoft : palette.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(endpoint == field ? palette.accent : palette.line, lineWidth: 1))
    }

    private func componentMenu(_ component: UsageDateRangeSelection.Component, for field: UsageDateRangeSelection.Endpoint, title: String) -> some View {
        let year = range.value(.year, for: field), month = range.value(.month, for: field)
        let values: ClosedRange<Int> = component == .year ? range.years : component == .month ? range.months(in: year) : range.days(in: year, month: month)
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string(title)).font(.system(size: 11)).foregroundStyle(palette.muted)
            LanguageMenu(label: L10n.string(field == .start ? "Start date" : "End date") + " · " + L10n.string(title),
                selection: Binding(get: { String(range.value(component, for: field)) }, set: { value in
                    guard let value = Int(value) else { return }
                    range.set(component, to: value, for: field)
                    endpoint = field; selectedPreset = nil; self.month = range.date(for: field)
                }), languages: values.map { .init(id: String($0), name: component == .year ? String($0) : String(format: "%02d", $0)) },
                prominent: false, minimumWidth: component == .year ? UsageDatePopoverLayout.yearWidth : UsageDatePopoverLayout.monthDayWidth)
                .fixedSize()
                .accessibilityIdentifier("settings.usage.date.\(field == .start ? "start" : "end").\(component == .year ? "year" : component == .month ? "month" : "day")")
        }
    }

    private func dateButton(_ date: Date) -> some View {
        let boundary = date == range.start || date == range.end
        let sameMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
        let valid = date >= range.minimumDate && date <= range.maximumDate
        return Button {
            range.selectCalendarDay(date, for: endpoint)
            endpoint = endpoint == .start ? .end : .start
            selectedPreset = nil; month = date
        } label: {
            Text(String(calendar.component(.day, from: date))).font(.system(size: 12, weight: boundary ? .semibold : .regular))
                .foregroundStyle(boundary ? Color.white : sameMonth ? palette.ink : palette.muted)
                .frame(maxWidth: .infinity).frame(height: UsageDatePopoverLayout.dayHeight)
                .background(boundary ? palette.primary : date >= range.start && date <= range.end ? palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 5))
                .opacity(valid ? 1 : 0.32)
        }.buttonStyle(.plain).translateXControlCursor().disabled(!valid)
            .accessibilityLabel(date.formatted(.dateTime.year().month().day().locale(L10n.currentLocale)))
            .accessibilityAddTraits(boundary ? .isSelected : [])
    }

    private func moveMonth(_ delta: Int) {
        let next = calendar.date(byAdding: .month, value: delta, to: monthStart) ?? month
        month = min(range.maximumDate, max(range.minimumDate, next))
    }
}
