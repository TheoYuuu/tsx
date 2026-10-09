import Foundation

/// Combines retained request details with older daily totals, without fabricating
/// request rows or treating unreported API metrics as zero.
struct TranslationUsageDashboard {
    struct Day: Identifiable {
        let date: Date
        var all = TranslationUsageTotals()
        var api = TranslationUsageTotals()
        var id: Date { date }
    }
    var all = TranslationUsageTotals()
    var api = TranslationUsageTotals()
    var days: [Day] = []
    var records: [TranslationUsageRecord] = []
    var summarizedRequests = 0
    var unknownCosts: Int { max(0, api.requests - (api.costReports ?? 0)) }
    var unknownTokens: Int { max(0, api.requests - api.tokenReports) }

    init(records: [TranslationUsageRecord], summaries: [TranslationUsageDay],
         start: Date, end: Date, service: String = "all", calendar: Calendar = .current) {
        let first = calendar.startOfDay(for: start)
        let after = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        var byDay: [Date: Day] = [:]
        func matches(_ id: UUID?) -> Bool { service == "all" || service == (id?.uuidString ?? "apple") }
        for summary in summaries where matches(summary.configurationID) && summary.day >= first && summary.day < after {
            all.merge(summary.totals)
            summarizedRequests += summary.totals.requests
            let date = calendar.startOfDay(for: summary.day)
            var day = byDay[date, default: Day(date: date)]
            day.all.merge(summary.totals)
            if summary.configurationID != nil { api.merge(summary.totals); day.api.merge(summary.totals) }
            byDay[date] = day
        }
        self.records = records.filter { matches($0.configurationID) && $0.completedAt >= first && $0.completedAt < after }
            .sorted { $0.completedAt > $1.completedAt }
        for record in self.records {
            all.add(record)
            let date = calendar.startOfDay(for: record.completedAt)
            var day = byDay[date, default: Day(date: date)]
            day.all.add(record)
            if record.configurationID != nil { api.add(record); day.api.add(record) }
            byDay[date] = day
        }
        days = byDay.values.sorted { $0.date < $1.date }
    }
}

/// Shared by bars and heatmap details. Missing API measurements stay distinct
/// from a measured zero, and currency totals never cross an exchange boundary.
enum UsageChartMetric: String, CaseIterable {
    case requests, fees, tokens

    var title: String {
        let key = switch self {
        case .requests: "Requests"
        case .fees: "Estimated cost"
        case .tokens: "Consumed Tokens"
        }
        return L10n.string(key)
    }

    func value(in day: TranslationUsageDashboard.Day?) -> Decimal? {
        guard let day else { return 0 }
        switch self {
        case .requests: return Decimal(day.all.requests)
        case .fees: return day.api.requests == 0 ? 0 : day.api.costs?["USD"]
        case .tokens: return day.api.requests == 0 ? 0 : day.api.totalTokens
        }
    }

    func isPartial(in day: TranslationUsageDashboard.Day?) -> Bool {
        guard let day else { return false }
        switch self {
        case .requests: return false
        case .fees: return (day.api.costReports ?? 0) < day.api.requests || (day.api.costs ?? [:]).keys.contains { $0 != "USD" }
        case .tokens: return day.api.tokenReports < day.api.requests
        }
    }
}
