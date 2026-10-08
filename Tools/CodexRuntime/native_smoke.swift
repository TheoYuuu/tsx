import Foundation

/// Links the actual native component to the built production executable. Every
/// operation carries a deliberately forbidden environment override, so the
/// helper must reject it before resolving a root, policy, or account.
@main
enum NativeRuntimeSmoke {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw Failure.invalidArguments }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let evidence = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let wrapper = evidence.appendingPathComponent("reject-environment.sh")
        let quoted = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\nCODEX_HOME=must-not-be-read exec " + quoted + "\n"
        try Data(script.utf8).write(to: wrapper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        var passed = 0
        for operation in [CodexRuntimeSession.Operation.status, .login, .logout, .models, .translate] {
            let request: CodexRuntimeSession.Request
            if operation == .translate {
                request = .init(operation: operation, model: "constructed-model", text: "Constructed sample.", targetLanguage: "zh-Hans", expectedGeneration: UUID().uuidString.lowercased())
            } else if operation == .models {
                request = .init(operation: operation, expectedGeneration: UUID().uuidString.lowercased())
            } else { request = .init(operation: operation) }
            let session = CodexRuntimeSession(helper: wrapper)
            var callbacks = 0
            let result = await session.run(request) { _ in callbacks += 1 }
            guard result.failure == nil, result.helperReaped, callbacks == 0,
                  result.terminal?.result?.status == "environment_rejected" else { throw Failure.boundaryFailed }
            passed += 1
        }
        let report: [String: Any] = ["passed": passed == 5, "cases": passed, "accountAccess": false,
            "scope": "native bridge to production executable; rejection before account root"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: evidence.appendingPathComponent("native-boundary.json"), options: .atomic)
        print("Native bridge and production executable: \(passed)/5 account-free boundary cases passed.")
    }

    enum Failure: Error { case invalidArguments, boundaryFailed }
}
