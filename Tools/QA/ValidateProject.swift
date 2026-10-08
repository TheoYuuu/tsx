import Foundation

/// Repository-specific checks for the two source trees and localized string tables.
/// This tool reads files only; it never starts the app or changes the Xcode project.
@main
enum ValidateProject {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let rootPath = arguments.first else {
                throw CheckFailure("Usage: validate-project <repository-root> [built-app ...]")
            }
            let root = URL(fileURLWithPath: rootPath).standardizedFileURL
            try checkSourceLists(root: root)
            var localized: [String: [String: String]] = [:]
            var localizedInfo: [String: [String: String]] = [:]
            for language in ["en", "zh-Hans"] {
                localized[language] = try stringTable(at: root.appendingPathComponent(
                    "LumaxTranslate/Resources/\(language).lproj/Localizable.strings"
                ))
                localizedInfo[language] = try stringTable(at: root.appendingPathComponent(
                    "LumaxTranslate/Resources/\(language).lproj/InfoPlist.strings"
                ))
            }
            let english = localized["en"]!
            let chinese = localized["zh-Hans"]!
            try require(Set(english.keys) == Set(chinese.keys), "Localizable.strings keys differ between en and zh-Hans")
            try require(Set(localizedInfo["en"]!.keys) == Set(localizedInfo["zh-Hans"]!.keys),
                "InfoPlist.strings keys differ between en and zh-Hans")
            for key in english.keys.sorted() {
                try require(
                    formatArguments(english[key]!) == formatArguments(chinese[key]!),
                    "Localization format arguments differ for key: \(key)"
                )
            }
            for appPath in arguments.dropFirst() {
                let app = URL(fileURLWithPath: appPath).standardizedFileURL
                for language in ["en", "zh-Hans"] {
                    let built = try stringTable(at: app.appendingPathComponent(
                        "Contents/Resources/\(language).lproj/Localizable.strings"
                    ))
                    try require(built == localized[language], "Built \(language) Localizable.strings differs from source: \(app.path)")
                    let builtInfo = try stringTable(at: app.appendingPathComponent(
                        "Contents/Resources/\(language).lproj/InfoPlist.strings"
                    ))
                    try require(builtInfo == localizedInfo[language], "Built \(language) InfoPlist.strings differs from source: \(app.path)")
                }
            }
            print("Project validation passed: both source lists, \(english.count) bilingual keys, format arguments and \(arguments.count - 1) built app(s).")
        } catch {
            FileHandle.standardError.write(Data("Project validation failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func stringTable(at url: URL) throws -> [String: String] {
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        guard let table = value as? [String: String], !table.isEmpty else {
            throw CheckFailure("Missing or invalid string table: \(url.path)")
        }
        for (key, value) in table {
            try require(!key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty localization key: \(url.path)")
            try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty localization value for \(key): \(url.path)")
        }
        return table
    }

    /// Compare printf argument positions and types, allowing positional reordering,
    /// presentation changes such as %02d, and repeated uses of the same argument.
    /// Literal %% consumes no argument. Dynamic width/precision consume Int arguments.
    private static func formatArguments(_ text: String) throws -> [Int: String] {
        let expression = try NSRegularExpression(pattern:
            #"%(%|(?:([1-9]\d*)\$)?[-+ #0']*(\*(?:([1-9]\d*)\$)?|\d+)?(?:\.(\*(?:([1-9]\d*)\$)?|\d+))?(hh|ll|[hlLqztj])?([@diuoxXfFeEgGaAcCsSp]))"#
        )
        let string = text as NSString
        var nextPosition = 1
        var arguments: [Int: String] = [:]
        var usesExplicitPosition = false
        var usesImplicitPosition = false
        for match in expression.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : string.substring(with: range)
            }
            if group(1) == "%" { continue }
            func addArgument(position: String?, type: String) throws {
                let index: Int
                if let position {
                    guard let value = Int(position) else { throw CheckFailure("Invalid format argument position") }
                    index = value
                    usesExplicitPosition = true
                } else {
                    index = nextPosition
                    nextPosition += 1
                    usesImplicitPosition = true
                }
                if let previous = arguments[index] {
                    try require(previous == type, "One format argument has incompatible types")
                }
                arguments[index] = type
            }
            if group(3)?.hasPrefix("*") == true { try addArgument(position: group(4), type: "signed:") }
            if group(5)?.hasPrefix("*") == true { try addArgument(position: group(6), type: "signed:") }
            let length = group(7) ?? ""
            let conversion = group(8)!
            let type: String
            switch conversion {
            case "d", "i": type = "signed:\(length)"
            case "u", "o", "x", "X": type = "unsigned:\(length)"
            case "f", "F", "e", "E", "g", "G", "a", "A": type = length == "L" ? "long-double" : "double"
            default: type = length + conversion
            }
            try addArgument(position: group(2), type: type)
        }
        try require(!(usesExplicitPosition && usesImplicitPosition), "Mixed positional and sequential format arguments")
        return arguments
    }

    private static func checkSourceLists(root: URL) throws {
        let projectURL = root.appendingPathComponent("LumaxTranslate.xcodeproj/project.pbxproj")
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: projectURL), options: [], format: nil)
        guard let project = value as? [String: Any],
              let objects = project["objects"] as? [String: [String: Any]],
              let rootID = project["rootObject"] as? String,
              let mainGroup = objects[rootID]?["mainGroup"] as? String else {
            throw CheckFailure("Cannot read Xcode project groups")
        }
        var paths: [String: URL] = [:]
        var visited: Set<String> = []
        func visit(_ id: String, parent: URL) throws {
            guard visited.insert(id).inserted, let object = objects[id] else {
                throw CheckFailure("Invalid or repeated Xcode group reference: \(id)")
            }
            let sourceTree = object["sourceTree"] as? String ?? "<group>"
            if sourceTree == "BUILT_PRODUCTS_DIR" { return }
            try require(sourceTree == "<group>" || sourceTree == "SOURCE_ROOT", "Unsupported Xcode source tree: \(sourceTree)")
            let base = sourceTree == "SOURCE_ROOT" ? root : parent
            let path = (object["path"] as? String).map { base.appendingPathComponent($0) } ?? base
            paths[id] = path.standardizedFileURL
            for child in object["children"] as? [String] ?? [] { try visit(child, parent: path) }
        }
        try visit(mainGroup, parent: root)

        for name in ["LumaxTranslate", "LumaxTranslateTests"] {
            let matches = objects.values.filter { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == name }
            guard matches.count == 1, let phases = matches[0]["buildPhases"] as? [String] else {
                throw CheckFailure("Missing or ambiguous Xcode target: \(name)")
            }
            var compiled: [String] = []
            for phase in phases where objects[phase]?["isa"] as? String == "PBXSourcesBuildPhase" {
                guard let files = objects[phase]?["files"] as? [String] else { throw CheckFailure("Invalid source build phase") }
                for file in files {
                    guard let reference = objects[file]?["fileRef"] as? String, let path = paths[reference] else {
                        throw CheckFailure("Unresolved source build file: \(file)")
                    }
                    if path.pathExtension == "swift" { compiled.append(path.path) }
                }
            }
            let directory = root.appendingPathComponent(name)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                throw CheckFailure("Cannot enumerate source directory: \(directory.path)")
            }
            let sourceFiles = (enumerator.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension == "swift" }.map { $0.standardizedFileURL.path }
            try require(!sourceFiles.isEmpty, "Empty source directory: \(name)")
            try require(Set(compiled).count == compiled.count, "Duplicate Swift build entries in \(name)")
            let missing = Set(sourceFiles).subtracting(compiled).sorted()
            let unexpected = Set(compiled).subtracting(sourceFiles).sorted()
            try require(missing.isEmpty && unexpected.isEmpty,
                "\(name) source list differs; run xcodegen generate. Missing: \(missing); unexpected: \(unexpected)")
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw CheckFailure(message) }
    }

    private struct CheckFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
