import Foundation
import XCTest
@testable import TranslateX

final class UsageDateRangeSelectionTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
    private func range(_ start: Date, _ end: Date, now: Date? = nil) -> UsageDateRangeSelection {
        .init(start: start, end: end, now: now ?? date(2026, 10, 9), calendar: calendar)
    }

    func testLeapDayClampsWhenChangingYearWithoutRollingIntoMarch() {
        var selection = range(date(2024, 2, 29), date(2024, 3, 10))
        selection.set(.year, to: 2023, for: .start)
        XCTAssertEqual(selection.start, date(2023, 2, 28))
        XCTAssertEqual(selection.end, date(2024, 3, 10))
        XCTAssertEqual(selection.days(in: 2000, month: 2).upperBound, 29)
        XCTAssertEqual(selection.days(in: 1900, month: 2).upperBound, 28)
    }

    func testMonthEndClampsToNewMonthAndDropdownOffersOnlyValidDays() {
        var selection = range(date(2026, 3, 31), date(2026, 6, 1))
        selection.set(.month, to: 4, for: .start)
        XCTAssertEqual(selection.start, date(2026, 4, 30))
        XCTAssertEqual(selection.days(in: 2026, month: 4), 1...30)
        selection.set(.month, to: 2, for: .start)
        XCTAssertEqual(selection.start, date(2026, 2, 28))
    }

    func testFutureDropdownValuesAndDirectSelectionAreClampedToToday() {
        var selection = range(date(2025, 12, 31), date(2025, 12, 31))
        selection.set(.year, to: 2026, for: .end)
        XCTAssertEqual(selection.end, date(2026, 10, 9))
        XCTAssertEqual(selection.months(in: 2026), 1...10)
        XCTAssertEqual(selection.days(in: 2026, month: 10), 1...9)
        selection.select(date(2028, 1, 1), for: .start)
        XCTAssertEqual(selection.start, date(2026, 10, 9))
        XCTAssertEqual(selection.end, selection.start)
    }

    func testEditingAnEndpointKeepsItAuthoritativeWithoutReversedRanges() {
        var selection = range(date(2026, 3, 10), date(2026, 3, 20))
        selection.set(.day, to: 25, for: .start)
        XCTAssertEqual(selection.start, date(2026, 3, 25))
        XCTAssertEqual(selection.end, selection.start)
        selection.set(.month, to: 2, for: .end)
        XCTAssertEqual(selection.end, date(2026, 2, 25))
        XCTAssertEqual(selection.start, selection.end)
    }

    func testCalendarSecondClickBeforeFirstPreservesBothClickedDates() {
        var selection = range(date(2026, 3, 10), date(2026, 3, 20))
        selection.selectCalendarDay(date(2026, 3, 8), for: .end)
        XCTAssertEqual(selection.start, date(2026, 3, 8))
        XCTAssertEqual(selection.end, date(2026, 3, 10))
    }

    func testDayPresetUsesCalendarArithmeticAcrossDaylightSavingTransition() {
        let today = date(2026, 11, 3)
        var selection = range(today, today, now: today)
        selection.preset(days: 7, earliest: date(2026, 1, 1))
        XCTAssertEqual(selection.start, date(2026, 10, 28))
        XCTAssertEqual(selection.end, today)
        XCTAssertEqual(calendar.dateComponents([.day], from: selection.start, to: selection.end).day, 6)
        XCTAssertNotEqual(selection.end.timeIntervalSince(selection.start), 6 * 86_400)
    }

    func testJapaneseCalendarUsesGregorianYearsAndPreservesRegionalSettings() {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        japanese.locale = Locale(identifier: "ja_JP")
        japanese.firstWeekday = 2
        japanese.minimumDaysInFirstWeek = 4
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = japanese.timeZone
        let now = gregorian.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 13))!
        let start = gregorian.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let selection = UsageDateRangeSelection(start: start, end: now, now: now, calendar: japanese)
        XCTAssertEqual(selection.calendar.identifier, .gregorian)
        XCTAssertEqual(selection.calendar.timeZone, japanese.timeZone)
        XCTAssertEqual(selection.calendar.locale, japanese.locale)
        XCTAssertEqual(selection.calendar.firstWeekday, 2)
        XCTAssertEqual(selection.calendar.minimumDaysInFirstWeek, 4)
        XCTAssertEqual(selection.years, 1900...2026)
        XCTAssertEqual(selection.minimumDate, gregorian.date(from: DateComponents(year: 1900, month: 1, day: 1)))
        XCTAssertEqual(selection.start, start)
        XCTAssertEqual(selection.end, gregorian.startOfDay(for: now))
    }

    func testAllTimeUsesAvailableHistoryAndInitialRangeIsNormalized() {
        var selection = range(date(2028, 1, 1), date(1890, 1, 1))
        XCTAssertEqual(selection.start, date(1900, 1, 1))
        XCTAssertEqual(selection.end, date(2026, 10, 9))
        selection.preset(days: nil, earliest: date(2009, 5, 6))
        XCTAssertEqual(selection.start, date(2009, 5, 6))
        XCTAssertEqual(selection.end, date(2026, 10, 9))
        selection.preset(days: 1, earliest: date(2009, 5, 6))
        XCTAssertEqual(selection.start, selection.end)
    }
}
