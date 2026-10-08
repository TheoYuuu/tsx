import Foundation
import Darwin

@main
struct NativeSessionProbe {
    @MainActor
    static func main() async {
        var data = Data()
        while data.count <= 65536 {
            guard let chunk = try? FileHandle.standardInput.read(upToCount: 65537 - data.count),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= 65536,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == Set(["helper_path", "request", "action"]),
              let path = value["helper_path"] as? String, path.hasPrefix("/"),
              let request = value["request"] as? [String: Any],
              request["operation"] as? String == "login_session", request["protocol_version"] as? Int == 1,
              let requestID = request["request_id"] as? String, let issuer = request["issuer"] as? String,
              let action = value["action"] as? String, ["none", "cancel_ready", "eof_ready", "task_cancel_ready"].contains(action),
              let payload = try? JSONSerialization.data(withJSONObject: request),
              let tmp = ProcessInfo.processInfo.environment["TMPDIR"]
        else {
            print("{\"events\":[],\"helper_reaped\":true,\"stderr_empty\":true,\"host_status\":\"launch_failed\"}")
            return
        }
        let shortWatchdog = CommandLine.arguments.dropFirst() == ["--short-watchdog"]
        let session = CodexAuthSession(helper: URL(fileURLWithPath: path), requestID: requestID,
                                       issuer: issuer, temporaryDirectory: URL(fileURLWithPath: tmp),
                                       watchdogDelay: shortWatchdog ? .milliseconds(100) : .seconds(18),
                                       cleanupGrace: shortWatchdog ? .milliseconds(100) : .seconds(6))
        // A protocol-only regression can create an unrelated child after the
        // pipes exist. It must not inherit a writing end and delay helper EOF.
        let sibling = CommandLine.arguments.dropFirst() == ["--inheritance-probe"]
            ? spawnFixtureSibling(otherPipeEnds: session.pipeDescriptorsForFixture().otherEnds) : nil
        var operation: Task<CodexAuthSession.Result, Never>?
        operation = Task {
            await session.run(request: payload) { _ in
                switch action {
                case "cancel_ready": session.cancel()
                case "eof_ready": session.finishInput()
                case "task_cancel_ready": operation?.cancel()
                default: break
                }
            }
        }
        guard let result = await operation?.value else { return }
        var completedBeforeSibling: Bool?
        if let sibling {
            var status: Int32 = 0
            completedBeforeSibling = waitpid(sibling, &status, WNOHANG) == 0
            if completedBeforeSibling == true {
                _ = await Task.detached {
                    var status: Int32 = 0
                    return waitpid(sibling, &status, 0)
                }.value
            }
        }
        if let encoded = try? JSONEncoder().encode(result),
           var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
            if let completedBeforeSibling { object["completed_before_fixture_sibling_exit"] = completedBeforeSibling }
            guard let resultData = try? JSONSerialization.data(withJSONObject: object) else { return }
            FileHandle.standardOutput.write(resultData)
            FileHandle.standardOutput.write(Data([10]))
        }
    }

    private static func spawnFixtureSibling(otherPipeEnds: [Int32]) -> pid_t? {
        let arguments: [UnsafeMutablePointer<CChar>?] = ["/bin/sleep", "1.5"].map { value in
            value.withCString { strdup($0) }
        } + [nil]
        let environment = [strdup("PATH=/usr/bin:/bin"), nil]
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }
        // Isolate the login stdin writer: no other pipe end may influence EOF.
        for descriptor in otherPipeEnds {
            guard posix_spawn_file_actions_addclose(&actions, descriptor) == 0 else { return nil }
        }
        for descriptor: Int32 in 0...2 {
            guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0) == 0 else { return nil }
        }
        var pid: pid_t = 0
        let status = arguments.withUnsafeBufferPointer { arguments in
            environment.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, "/bin/sleep", &actions, nil,
                            UnsafeMutablePointer(mutating: arguments.baseAddress!),
                            UnsafeMutablePointer(mutating: environment.baseAddress!))
            }
        }
        return status == 0 ? pid : nil
    }
}
