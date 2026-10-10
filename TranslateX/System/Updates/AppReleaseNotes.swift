import Foundation
import Observation

struct AppRelease: Codable, Identifiable, Equatable, Sendable {
    let version: String
    // Bundled notes are prepared before publication; the live release supplies
    // the actual timestamp rather than substituting the build time.
    let publishedAt: Date?
    let notes: String
    let url: URL
    var id: String { version }

    func localizedNotes(languageIdentifier: String) -> String? {
        ReleaseNotesLocalization.content(notes, languageIdentifier: languageIdentifier)
    }
}

enum AppUpdateLinks {
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

/// Public release text is separate from trusted update selection. This client
/// cannot supply an installer URL, signing key, or installable appcast item.
struct AppReleaseNotesClient: Sendable {
    enum LoadError: Error { case response, tooLarge, invalidRelease }
    private static let pageByteLimit = 2 * 1_024 * 1_024

    func load() async throws -> [AppRelease] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: ReleaseNotesRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var releases: [AppRelease] = []
        for page in 1...20 {
            try Task.checkCancellation()
            guard let url = URL(string: "https://api.github.com/repos/TheoYuuu/tsx/releases?per_page=100&page=\(page)") else { throw LoadError.response }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("TSX", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.host == "api.github.com", response.expectedContentLength <= Self.pageByteLimit else { throw LoadError.response }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.pageByteLimit else { throw LoadError.tooLarge }
                data.append(byte)
            }
            let pageResult = try Self.decodePage(data)
            releases.append(contentsOf: pageResult.releases)
            if pageResult.count < 100 {
                var seen = Set<String>()
                return releases.filter { seen.insert($0.version).inserted }.sorted {
                    ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
                }
            }
        }
        throw LoadError.tooLarge
    }

    static func decodePage(_ data: Data) throws -> (releases: [AppRelease], count: Int) {
        struct RemoteRelease: Decodable {
            let tag_name: String
            let published_at: Date?
            let body: String?
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
        }
        guard data.count <= pageByteLimit else { throw LoadError.tooLarge }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let rows = try decoder.decode([RemoteRelease].self, from: data)
        var releases: [AppRelease] = []
        for row in rows where !row.draft && !row.prerelease {
            guard let published = row.published_at,
                  row.html_url.scheme == "https", row.html_url.host == "github.com",
                  row.html_url.user == nil, row.html_url.password == nil,
                  row.html_url.path.hasPrefix("/TheoYuuu/tsx/releases/tag/"),
                  row.tag_name.range(of: "^v?[0-9]+(?:\\.[0-9]+){1,3}$", options: .regularExpression) != nil,
                  row.tag_name.count < 64, (row.body?.utf8.count ?? 0) <= 128 * 1_024 else { throw LoadError.invalidRelease }
            let version = row.tag_name.hasPrefix("v") ? String(row.tag_name.dropFirst()) : row.tag_name
            releases.append(.init(version: version, publishedAt: published, notes: row.body ?? "", url: row.html_url))
        }
        return (releases, rows.count)
    }
}

private final class ReleaseNotesRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
@Observable
final class AppReleaseNotesStore {
    private(set) var entries: [AppRelease]
    private(set) var isLoading = false
    private(set) var failed = false
    private(set) var hasLoaded = false
    @ObservationIgnored private let loader: @Sendable () async throws -> [AppRelease]
    @ObservationIgnored private let allowsNetworkLoading: Bool

    init(entries: [AppRelease]? = nil, allowsNetworkLoading: Bool = true,
         loader: @escaping @Sendable () async throws -> [AppRelease] = { try await AppReleaseNotesClient().load() }) {
        self.entries = entries ?? Self.bundledEntries()
        self.allowsNetworkLoading = allowsNetworkLoading
        self.loader = loader
    }

    func load(force: Bool = false) async {
        guard !isLoading, force || !hasLoaded else { return }
        guard allowsNetworkLoading else { hasLoaded = true; return }
        isLoading = true; failed = false
        defer { isLoading = false }
        do {
            let fetched = try await loader()
            try Task.checkCancellation()
            // A temporarily empty upstream list must not erase shipped notes.
            if !fetched.isEmpty { entries = fetched }
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch { failed = true }
    }

    private static func bundledEntries() -> [AppRelease] {
        guard let url = Bundle.main.url(forResource: "PublishedReleaseNotes", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AppRelease].self, from: data)) ?? []
    }
}
