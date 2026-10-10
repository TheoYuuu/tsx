import Foundation

/// Calendar days follow the user's time zone; elapsed hours remain accurate
/// across midnight and daylight-saving changes. Publication is never inferred
/// from the installed version or the time the release feed was fetched.
enum ReleasePublicationTime {
    enum Age: Equatable {
        case justNow, minutes(Int), hours(Int), yesterday, days(Int), absolute
    }

    static func age(of date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Age {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= -60 else { return .absolute }
        if elapsed < 60 { return .justNow }
        if elapsed < 3_600 { return .minutes(Int(elapsed / 60)) }
        if elapsed < 86_400 { return .hours(Int(elapsed / 3_600)) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                          to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return .yesterday }
        if (2...30).contains(days) { return .days(days) }
        return .absolute
    }

    static func label(for date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        switch age(of: date, now: now, calendar: calendar) {
        case .justNow: return L10n.string("Just published")
        case .minutes(let count):
            return count == 1 ? L10n.string("Published 1 minute ago") : String(format: L10n.string("Published %d minutes ago"), count)
        case .hours(let count):
            return count == 1 ? L10n.string("Published 1 hour ago") : String(format: L10n.string("Published %d hours ago"), count)
        case .yesterday: return L10n.string("Published yesterday")
        case .days(let count): return String(format: L10n.string("Published %d days ago"), count)
        case .absolute:
            return String(format: L10n.string("Published %@"), absolute(date, locale: L10n.currentLocale, timeZone: calendar.timeZone))
        }
    }

    static func absolute(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }

    static func precise(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let offset = timeZone.secondsFromGMT(for: date) / 60
        let zone = String(format: "UTC%@%02d:%02d", offset < 0 ? "−" : "+", abs(offset) / 60, abs(offset) % 60)
        return "\(absolute(date, locale: locale, timeZone: timeZone)) \(formatter.string(from: date)) (\(zone))"
    }
}

/// Presentation-only filtering: retain the published source for external links
/// and never rewrite release assets. A matching section includes its nested
/// headings, ending at the next sibling/ancestor heading.
enum ReleaseNotesPresentation {
    static func content(_ notes: String, version: String) -> String {
        let text = ReleaseNotesLocalization.removingRedundantTitle(notes, version: version)
        var omittedLevel: Int?
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The first English release predates section headings. Its install
            // appendix starts here and continues to the end of that language.
            if version == "1.0.0", trimmed.hasPrefix("Download `TSX-1.0.0-") { break }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            let isHeading = (1...6).contains(level) && trimmed.dropFirst(level).first == " "
            if isHeading {
                if let omitted = omittedLevel, level <= omitted { omittedLevel = nil }
                let heading = trimmed.dropFirst(level).trimmingCharacters(in: CharacterSet(charactersIn: " #")).lowercased()
                let legacyAppendix = version == "1.0.0" && heading == "系统、权限与已知限制"
                if omittedLevel == nil, installationHeadings.contains(heading) || legacyAppendix { omittedLevel = level }
            }
            if omittedLevel == nil { result.append(line) }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let installationHeadings: Set<String> = [
        "安装与说明", "安装说明", "安装", "安装与下载", "下载与安装", "下载与更新", "安装与更新", "下载与验证",
        "installation and notes", "installation notes", "installation", "installation and downloads",
        "download and installation", "downloads and installation", "installation and updates", "download and verification"
    ]

    /// Explicit Markdown leads become the compact title/description pair.
    /// Older unstructured notes keep their exact wording instead of receiving
    /// an invented summary or being truncated to fit the mockup.
    static func item(_ text: String) -> (title: String?, detail: String) {
        guard text.hasPrefix("**"), let end = text.dropFirst(2).range(of: "**") else { return (nil, text) }
        let title = String(text[text.index(text.startIndex, offsetBy: 2)..<end.lowerBound])
        let detail = text[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return (title, detail.trimmingCharacters(in: CharacterSet(charactersIn: ":： ")))
    }
}
