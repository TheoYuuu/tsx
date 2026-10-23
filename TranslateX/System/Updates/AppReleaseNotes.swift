import Foundation
import Observation
import Sparkle

struct AppRelease: Codable, Identifiable, Equatable, Sendable {
    let version: String
    // Bundled notes are prepared before publication; the live release supplies
    // the actual timestamp rather than substituting the build time.
    let publishedAt: Date?
    let notes: String
    let url: URL?
    var id: String { version }

    func localizedNotes(languageIdentifier: String) -> String? {
        ReleaseNotesLocalization.content(notes, languageIdentifier: languageIdentifier)
    }
}

enum AppUpdateLinks {
    static func allowedReleaseURL(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              url.query == nil, url.fragment == nil,
              !url.absoluteString.contains("%"), !url.pathComponents.contains("..") else { return nil }
        let permitted: Bool
        switch url.host {
        case "github.com":
            permitted = ["/TheoYuuu/tsx/releases", "/uuthings/tsx/releases"].contains {
                url.path == $0 || url.path.hasPrefix($0 + "/tag/")
            }
        case "lumaxspace.com":
            permitted = ["/products/tsx", "/zh/products/tsx"].contains {
                url.path == $0 || url.path.hasPrefix($0 + "/")
            }
        case "uuthings.com": permitted = url.path.hasPrefix("/products/tsx/")
        default: permitted = false
        }
        return permitted ? url : nil
    }

    static func productPage(languageIdentifier: String) -> URL {
        let chinese = Locale.Language(identifier: languageIdentifier).languageCode?.identifier == "zh"
        return URL(string: chinese ? "https://lumaxspace.com/zh/products/tsx/" : "https://lumaxspace.com/products/tsx/")!
    }
}

/// Selects published language sections without translating or rewriting them.
/// Supports labeled sections and the horizontal-rule-separated bilingual format
/// used by the existing release. An unavailable language stays unavailable.
enum ReleaseNotesLocalization {
    /// The surrounding release row already identifies the version. Remove only
    /// an identical leading Markdown title, retaining substantive headings.
    static func removingRedundantTitle(_ notes: String, version: String) -> String {
        var lines = notes.components(separatedBy: .newlines)
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        if let first = lines.first, first.hasPrefix("# ") {
            let title = first.dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased()
            if [version, "v" + version, "tsx " + version, "tsx v" + version].contains(title) {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func content(_ notes: String, languageIdentifier: String) -> String? {
        let requested = Locale.Language(identifier: languageIdentifier).languageCode?.identifier == "zh" ? "zh" : "en"
        let lines = notes.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let title = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# TSX ") }
        var selected: String
        if lines.contains(where: { languageHeading($0) != nil }) {
            var current: String?
            var selectedLines: [String] = []
            for line in lines {
                if let language = languageHeading(line) { current = language }
                else if current == requested { selectedLines.append(line) }
            }
            selected = selectedLines.joined(separator: "\n")
        } else {
            let separated = lines.joined(separator: "\n").replacingOccurrences(
                of: "(?m)^[ \\t]*(?:-{3,}|\\*{3,}|_{3,})[ \\t]*$", with: "\u{001e}", options: .regularExpression)
            selected = separated.components(separatedBy: "\u{001e}").filter { section in
                guard !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                let hasChinese = section.unicodeScalars.contains {
                    (0x3400...0x9fff).contains($0.value) || (0xf900...0xfaff).contains($0.value) || (0x20000...0x2fa1f).contains($0.value)
                }
                return (hasChinese ? "zh" : "en") == requested
            }.joined(separator: "\n\n---\n\n")
        }
        selected = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        let prose = selected.replacingOccurrences(of: "(?m)^[ \\t]*(?:-{3,}|\\*{3,}|_{3,})[ \\t]*$",
                                                  with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prose.isEmpty, prose != title else { return nil }
        if let title, !selected.hasPrefix(title) { selected = title + "\n\n" + selected }
        return selected
    }

    private static func languageHeading(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let heading = trimmed.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces).lowercased()
        switch heading {
        case "中文", "简体中文", "chinese", "zh", "zh-hans": return "zh"
        case "english", "en": return "en"
        default: return nil
        }
    }
}

/// Only the updater delegate supplies these values, after Sparkle has parsed the
/// appcast. The store still checks the feed validation result before using them.
struct AppcastReleaseNotes: Sendable {
    var version: String
    var build: String
    var publishedAt: Date?
    var notes: String?
    var format: String?
    var url: URL?
    var channel: String?

    init(version: String, build: String, publishedAt: Date? = nil, notes: String? = nil,
         format: String? = "plain-text", url: URL? = nil, channel: String? = nil) {
        self.version = version; self.build = build; self.publishedAt = publishedAt
        self.notes = notes; self.format = format; self.url = url; self.channel = channel
    }

    init(_ item: SUAppcastItem) {
        self.init(version: item.displayVersionString, build: item.versionString, publishedAt: item.date,
                  notes: item.itemDescription, format: item.itemDescriptionFormat,
                  url: item.fullReleaseNotesURL, channel: item.channel)
    }
}

@MainActor
@Observable
final class AppReleaseNotesStore {
    private(set) var entries: [AppRelease]
    private(set) var isLoading = false
    private(set) var failed = false
    private(set) var hasLoaded = false
    @ObservationIgnored private let allowsNetworkLoading: Bool

    init(entries: [AppRelease]? = nil, allowsNetworkLoading: Bool = true) {
        self.entries = entries ?? Self.bundledEntries()
        self.allowsNetworkLoading = allowsNetworkLoading
    }

    func needsLoad(force: Bool = false) -> Bool {
        allowsNetworkLoading && !isLoading && (force || !hasLoaded)
    }

    @discardableResult
    func beginLoading(force: Bool = false) -> Bool {
        guard needsLoad(force: force) else { return false }
        isLoading = true; failed = false
        return true
    }

    func loadingFailed() {
        guard isLoading else { return }
        isLoading = false; failed = true
    }

    /// Never persist remote notes. An invalid/unsigned feed or an interrupted
    /// check leaves the bundled and previously verified in-memory entries intact.
    func receive(_ items: [AppcastReleaseNotes], status: SPUAppcastSigningValidationStatus) {
        guard status == .succeeded, items.count <= 200,
              items.reduce(0, { $0 + ($1.notes?.utf8.count ?? 0) }) <= 2 * 1_024 * 1_024 else {
            isLoading = false; failed = true; return
        }
        let comparator = SUStandardVersionComparator()
        var selected: [String: AppcastReleaseNotes] = [:]
        for item in items {
            guard item.channel == nil || item.channel == "stable",
                  Self.validVersion(item.version), Self.validBuild(item.build),
                  (item.notes?.utf8.count ?? 0) <= 128 * 1_024 else { continue }
            if let previous = selected[item.version],
               comparator.compareVersion(item.build, toVersion: previous.build) != .orderedDescending { continue }
            selected[item.version] = item
        }
        var merged = Dictionary(entries.map { ($0.version, $0) }, uniquingKeysWith: { first, _ in first })
        for (version, item) in selected {
            let previous = merged[version]
            let text = item.format == "plain-text" ? item.notes?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            merged[version] = .init(version: version, publishedAt: item.publishedAt ?? previous?.publishedAt,
                                    notes: text.flatMap { $0.isEmpty ? nil : $0 } ?? previous?.notes ?? "",
                                    url: AppUpdateLinks.allowedReleaseURL(item.url) ?? previous?.url)
        }
        entries = merged.values.sorted { comparator.compareVersion($0.version, toVersion: $1.version) == .orderedDescending }
        isLoading = false; failed = false; hasLoaded = true
    }

    private static func validVersion(_ value: String) -> Bool {
        value.count < 64 && value.range(of: "^[0-9]+(?:\\.[0-9]+){1,3}$", options: .regularExpression) != nil
    }
    private static func validBuild(_ value: String) -> Bool {
        value.count < 64 && value.range(of: "^[0-9]+(?:\\.[0-9]+)*$", options: .regularExpression) != nil
    }
    private static func bundledEntries() -> [AppRelease] {
        guard let url = Bundle.main.url(forResource: "PublishedReleaseNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AppRelease].self, from: data)) ?? []
    }
}
