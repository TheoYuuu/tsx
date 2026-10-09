import Foundation

/// Day-only range editing. Construct a valid month before applying its day so
/// Calendar cannot roll February 31 into March. Changing one endpoint keeps it
/// authoritative and moves the other only when needed to preserve start <= end.
nonisolated struct UsageDateRangeSelection: Equatable {
    enum Endpoint { case start, end }
    enum Component { case year, month, day }

    private(set) var start: Date
    private(set) var end: Date
    let calendar: Calendar
    let minimumDate: Date
    let maximumDate: Date

    init(start: Date, end: Date, now: Date = Date(), calendar: Calendar = .current) {
        // Numeric year/month/day controls always use Gregorian years. Calendars
        // such as Japanese interpret year 1900 within the current era instead.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = calendar.locale
        gregorian.firstWeekday = calendar.firstWeekday
        gregorian.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        self.calendar = gregorian
        minimumDate = gregorian.date(from: DateComponents(year: 1900, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
        maximumDate = max(minimumDate, gregorian.startOfDay(for: now))
        let first = min(maximumDate, max(minimumDate, gregorian.startOfDay(for: start)))
        let last = min(maximumDate, max(minimumDate, gregorian.startOfDay(for: end)))
        self.start = min(first, last)
        self.end = max(first, last)
    }

    var years: ClosedRange<Int> { calendar.component(.year, from: minimumDate)...calendar.component(.year, from: maximumDate) }

    func months(in year: Int) -> ClosedRange<Int> {
        let safeYear = min(years.upperBound, max(years.lowerBound, year))
        let first = calendar.date(from: DateComponents(year: safeYear, month: 1, day: 1)) ?? minimumDate
        let count = calendar.range(of: .month, in: .year, for: first)?.count ?? 12
        let upper = safeYear == years.upperBound ? calendar.component(.month, from: maximumDate) : count
        return 1...max(1, upper)
    }

    func days(in year: Int, month: Int) -> ClosedRange<Int> {
        let safeYear = min(years.upperBound, max(years.lowerBound, year))
        let monthRange = months(in: safeYear)
        let safeMonth = min(monthRange.upperBound, max(monthRange.lowerBound, month))
        let first = calendar.date(from: DateComponents(year: safeYear, month: safeMonth, day: 1)) ?? minimumDate
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 28
        let isCurrentMonth = safeYear == years.upperBound && safeMonth == calendar.component(.month, from: maximumDate)
        let upper = isCurrentMonth ? calendar.component(.day, from: maximumDate) : count
        return 1...max(1, upper)
    }

    func date(for endpoint: Endpoint) -> Date { endpoint == .start ? start : end }

    func value(_ component: Component, for endpoint: Endpoint) -> Int {
        calendar.component(component == .year ? .year : component == .month ? .month : .day, from: date(for: endpoint))
    }

    mutating func set(_ component: Component, to value: Int, for endpoint: Endpoint) {
        var year = self.value(.year, for: endpoint)
        var month = self.value(.month, for: endpoint)
        var day = self.value(.day, for: endpoint)
        switch component {
        case .year: year = value
        case .month: month = value
        case .day: day = value
        }
        year = min(years.upperBound, max(years.lowerBound, year))
        let monthRange = months(in: year)
        month = min(monthRange.upperBound, max(monthRange.lowerBound, month))
        let dayRange = days(in: year, month: month)
        day = min(dayRange.upperBound, max(dayRange.lowerBound, day))
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return }
        select(date, for: endpoint)
    }

    mutating func select(_ date: Date, for endpoint: Endpoint) {
        let selected = min(maximumDate, max(minimumDate, calendar.startOfDay(for: date)))
        if endpoint == .start { start = selected; end = max(end, start) }
        else { end = selected; start = min(start, end) }
    }

    /// Calendar range selection supports a second click before the first click.
    /// In that case both clicked dates remain selected, in chronological order.
    mutating func selectCalendarDay(_ date: Date, for endpoint: Endpoint) {
        let selected = min(maximumDate, max(minimumDate, calendar.startOfDay(for: date)))
        if endpoint == .end && selected < start {
            end = start
            start = selected
        } else { select(selected, for: endpoint) }
    }

    mutating func preset(days: Int?, earliest: Date) {
        end = maximumDate
        let first = days.map { calendar.date(byAdding: .day, value: 1 - max(1, $0), to: end) ?? end } ?? earliest
        start = min(end, max(minimumDate, calendar.startOfDay(for: first)))
    }
}
