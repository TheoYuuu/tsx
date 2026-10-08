import Foundation
import Darwin
import Dispatch

/// A native host for the isolated QA protocol, not a shipped account service.
/// Public codes stay in memory. Tokens never belong to this protocol.
@MainActor
final class CodexAuthSession {
    struct Event: Codable, Sendable {
        let event: String
        let protocolVersion: Int
        let requestID: String
        let status: String?
        let phase: String?
        let userCode: String?
        let verificationURL: String?
        let authorizationUIDisabled: Bool?
        let workerReaped: Bool?
        let stageHome: String?
        let stageSavedConfirmed: Bool?
        let stageCleanupOK: Bool?
        let targetAuthPresent: Bool?
        let authHeaderPresent: Bool?
        let accountMatches: Bool?
        let userMatches: Bool?
        let pendingCleanupHomes: [String]?
        let cleanupJournal: String?

        enum CodingKeys: String, CodingKey {
            case event, status, phase
            case protocolVersion = "protocol_version", requestID = "request_id"
            case userCode = "user_code", verificationURL = "verification_url"
            case authorizationUIDisabled = "authorization_ui_disabled", workerReaped = "worker_reaped"
            case stageHome = "stage_home", stageSavedConfirmed = "stage_saved_confirmed"
            case stageCleanupOK = "stage_cleanup_ok", targetAuthPresent = "target_auth_present"
            case authHeaderPresent = "auth_header_present", accountMatches = "account_matches"
            case userMatches = "user_matches", pendingCleanupHomes = "pending_cleanup_homes"
            case cleanupJournal = "cleanup_journal"
        }
    }

    struct Result: Encodable, Sendable {
        let events: [Event]
        let helperReaped: Bool
        let stderrEmpty: Bool
        let hostStatus: String

        enum CodingKeys: String, CodingKey {
            case events
            case helperReaped = "helper_reaped", stderrEmpty = "stderr_empty", hostStatus = "host_status"
        }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let requestID: String
    private let issuer: String
    private let watchdogDelay: Duration
    private let cleanupGrace: Duration
    private var continuation: CheckedContinuation<Result, Never>?
    private var onReady: ((Event) -> Void)?
    private var watchdog: Task<Void, Never>?
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var writeTask: Task<Void, Never>?
    private var queuedInput = Data()
    private var pending = Data()
    private var outputBytes = 0
    private var errorBytes = 0
    private var events: [Event] = []
    private var stdoutEnded = false
    private var stderrEnded = false
    private var exitStatus: Int32?
    private var inputClosed = false
    private var cancellationRequested = false
    private var failure: String?
    private var started = false
    private var finished = false
    private var pipesCloseOnExec = true

    init(helper: URL, requestID: String, issuer: String, temporaryDirectory: URL,
         watchdogDelay: Duration = .seconds(18), cleanupGrace: Duration = .seconds(6)) {
        self.requestID = requestID
        self.issuer = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.watchdogDelay = watchdogDelay
        self.cleanupGrace = cleanupGrace
        process.executableURL = helper
        process.currentDirectoryURL = temporaryDirectory
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": temporaryDirectory.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Foundation.Pipe does not set FD_CLOEXEC on this macOS runtime. A
        // separately spawned child must not retain a login pipe's writing end.
        for pipe in [input, output, errors] {
            for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
                let descriptor = handle.fileDescriptor
                let flags = fcntl(descriptor, F_GETFD)
                if flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) < 0 {
                    pipesCloseOnExec = false
                }
            }
        }
    }

    /// Completes only after the terminal frame, both pipe EOFs, and process exit.
    /// A protocol failure is never converted to a successful account state.
    func run(request: Data, onReady: @escaping (Event) -> Void) async -> Result {
        guard !started, pipesCloseOnExec, request.count < 32768,
              UUID(uuidString: requestID)?.uuidString.lowercased() == requestID.lowercased()
        else { return Result(events: [], helperReaped: true, stderrEmpty: true, hostStatus: "launch_failed") }
        started = true
        self.onReady = onReady
        return await withTaskCancellationHandler {
            if Task.isCancelled {
                finished = true
                self.onReady = nil
                return Result(events: [], helperReaped: true, stderrEmpty: true, hostStatus: "cancelled_before_launch")
            }
            return await waitForProcess(request: request)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func waitForProcess(request: Data) async -> Result {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                Task { @MainActor in
                    self?.exitStatus = status
                    self?.completeIfReady()
                }
            }
            do {
                outputSource = try readPipe(output.fileHandleForReading, stderr: false)
                errorSource = try readPipe(errors.fileHandleForReading, stderr: true)
                try process.run()
                let descriptor = input.fileHandleForWriting.fileDescriptor
                let flags = fcntl(descriptor, F_GETFL)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0,
                      fcntl(descriptor, F_SETNOSIGPIPE, 1) >= 0 else { throw CocoaError(.fileWriteUnknown) }
                var line = request
                line.append(10)
                enqueue(line)
            } catch {
                failure = "launch_failed"
                finishInput()
                if !process.isRunning {
                    exitStatus = -1
                    stdoutEnded = true
                    stderrEnded = true
                    completeIfReady()
                    return
                }
            }
            watchdog = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: self.watchdogDelay) } catch { return }
                guard !self.finished else { return }
                self.failure = "cleanup_required"
                self.finishInput()
                // A normal EOF gets a separate cleanup grace period.
                do { try await Task.sleep(for: self.cleanupGrace) } catch { return }
                self.forceStopOwnedHelper()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if !self.finished { self.finishResult(helperReaped: self.exitStatus != nil) }
            }
        }
    }

    func cancel() {
        guard started, !finished, !inputClosed, !cancellationRequested,
              !events.contains(where: { $0.event == "terminal" }) else { return }
        cancellationRequested = true
        do {
            var line = try JSONSerialization.data(withJSONObject: [
                "operation": "cancel", "protocol_version": 1, "request_id": requestID
            ])
            line.append(10)
            enqueue(line)
        } catch {
            finishInput()
        }
    }

    /// Simulates the native owner's normal disappearance without killing it.
    func finishInput() {
        guard !inputClosed else { return }
        inputClosed = true
        cancellationRequested = true
        writeTask?.cancel()
        writeTask = nil
        queuedInput.removeAll(keepingCapacity: false)
        do { try input.fileHandleForWriting.close() }
        catch { failure = "cleanup_required" }
    }

    private func enqueue(_ data: Data) {
        guard !inputClosed else { return }
        queuedInput.append(data)
        guard writeTask == nil else { return }
        writeTask = Task { [weak self] in
            guard let self else { return }
            while !self.queuedInput.isEmpty, !self.inputClosed {
                let descriptor = self.input.fileHandleForWriting.fileDescriptor
                let written = self.queuedInput.withUnsafeBytes { bytes in
                    Darwin.write(descriptor, bytes.baseAddress, bytes.count)
                }
                if written > 0 {
                    self.queuedInput.removeFirst(written)
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                } else {
                    self.finishInput()
                    break
                }
            }
            self.writeTask = nil
        }
    }

    /// Only the protocol-only sibling fixture uses these descriptor numbers.
    func pipeDescriptorsForFixture() -> (writer: Int32, otherEnds: [Int32]) {
        (input.fileHandleForWriting.fileDescriptor,
         [input.fileHandleForReading, output.fileHandleForReading, output.fileHandleForWriting,
          errors.fileHandleForReading, errors.fileHandleForWriting].map(\.fileDescriptor))
    }

    private func readPipe(_ handle: FileHandle, stderr: Bool) throws -> DispatchSourceRead {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0
        else { throw CocoaError(.fileReadUnknown) }
        // Independent readiness sources let a silent stderr remain open without
        // delaying stdout. One main-actor consumer preserves protocol ordering.
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drainPipe(descriptor, stderr: stderr) }
        }
        // A descriptor must stay valid until dispatch finishes cancelling its
        // source; closing it earlier could redirect a queued read to a reused FD.
        source.setCancelHandler { try? handle.close() }
        source.resume()
        return source
    }

    private func drainPipe(_ descriptor: Int32, stderr: Bool) {
        guard !finished, !(stderr ? stderrEnded : stdoutEnded) else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Bound work per callback so a noisy helper cannot starve cancellation
        // or the watchdog. Readiness will schedule any remaining pipe contents.
        for _ in 0..<4 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                receive(Data(buffer.prefix(count)), stderr: stderr)
                if finished { return }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                if count < 0 { failProtocol() }
                (stderr ? errorSource : outputSource)?.cancel()
                receive(Data(), stderr: stderr)
                return
            }
        }
    }

    private func stopPipeReaders() {
        if let outputSource { outputSource.cancel() }
        else { try? output.fileHandleForReading.close() }
        if let errorSource { errorSource.cancel() }
        else { try? errors.fileHandleForReading.close() }
    }

    private func receive(_ data: Data, stderr: Bool) {
        guard !finished else { return }
        if stderr {
            errorBytes += data.count
            if data.isEmpty {
                stderrEnded = true
            } else {
                // Do not retain or print raw errors. Unexpected stderr invalidates the run.
                failProtocol()
            }
        } else if data.isEmpty {
            stdoutEnded = true
            if !pending.isEmpty { failProtocol() }
        } else {
            outputBytes += data.count
            if outputBytes > 65536 {
                failProtocol()
                pending.removeAll(keepingCapacity: false)
            } else if failure == nil {
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    accept(line)
                    if failure != nil { pending.removeAll(keepingCapacity: false); break }
                }
                if pending.count > 8192 { failProtocol(); pending.removeAll(keepingCapacity: false) }
            }
        }
        completeIfReady()
    }

    private func accept(_ line: Data) {
        let allowedKeys: Set<String> = [
            "event", "protocol_version", "request_id", "status", "phase", "user_code", "verification_url",
            "authorization_ui_disabled", "worker_reaped", "stage_home", "stage_saved_confirmed", "stage_cleanup_ok",
            "target_auth_present", "auth_header_present", "account_matches", "user_matches", "pending_cleanup_homes", "cleanup_journal"
        ]
        guard !line.isEmpty, line.count <= 8192, events.count < 4,
              !events.contains(where: { $0.event == "terminal" }),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              Set(object.keys).isSubset(of: allowedKeys),
              let event = try? JSONDecoder().decode(Event.self, from: line),
              event.protocolVersion == 1, event.requestID == requestID
        else { failProtocol(); return }
        switch event.event {
        case "ready":
            guard events.isEmpty, event.status == nil, event.phase == nil,
                  let code = event.userCode, !code.isEmpty, code.utf8.count <= 128,
                  code.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace || $0 == " " }),
                  !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  event.verificationURL == issuer + "/codex/device"
            else { failProtocol(); return }
        case "phase":
            guard events.first?.event == "ready", event.status == nil,
                  event.userCode == nil, event.verificationURL == nil,
                  let phase = event.phase, ["before_promotion", "after_promotion"].contains(phase),
                  !events.contains(where: { $0.phase == phase }),
                  phase != "after_promotion" || events.last?.phase == "before_promotion"
            else { failProtocol(); return }
        case "terminal":
            let statuses: Set<String> = [
                "signed_in", "cancelled", "timed_out", "invalid_control", "login_failed", "device_code_failed",
                "storage_unavailable", "already_signed_in", "target_changed", "staging_failed", "cleanup_required",
                "invalid_stored_auth", "unexpected_auth_method", "invalid_input", "invalid_operation",
                "environment_rejected", "identity_busy", "worker_failed", "ui_suppression_failed", "process_isolation_failed", "output_closed"
            ]
            guard let status = event.status, statuses.contains(status), event.phase == nil,
                  event.userCode == nil, event.verificationURL == nil,
                  status != "signed_in" || (events.last?.phase == "after_promotion"
                    && event.workerReaped == true && event.stageCleanupOK == true && event.targetAuthPresent == true)
            else { failProtocol(); return }
        default:
            failProtocol(); return
        }
        events.append(event)
        if event.event == "ready", !cancellationRequested { onReady?(event) }
    }

    private func failProtocol() {
        if failure == nil { failure = "protocol_failed" }
        finishInput()
    }

    private func forceStopOwnedHelper() {
        guard !finished else { return }
        // Foundation may already create a private group in the parent's session;
        // otherwise the helper creates it before starting any workers.
        if process.isRunning {
            let pid = process.processIdentifier
            if getpgid(pid) == pid {
                _ = Darwin.kill(-pid, SIGKILL)
            } else {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        // A dead helper may leave descendants holding inherited pipes. Do not
        // signal a reaped/reusable PID or wait forever for those pipe EOFs.
        stdoutEnded = true
        stderrEnded = true
        stopPipeReaders()
        // Interrupted persistence requires journal recovery; never claim cleanup.
        failure = "cleanup_required"
        completeIfReady()
    }

    private func completeIfReady() {
        guard !finished, exitStatus != nil, stdoutEnded, stderrEnded else { return }
        finishResult(helperReaped: true)
    }

    private func finishResult(helperReaped: Bool) {
        guard !finished else { return }
        finished = true
        watchdog?.cancel()
        watchdog = nil
        finishInput()
        stopPipeReaders()
        process.terminationHandler = nil
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let status = failure ?? ((exitStatus == 0 && events.last?.event == "terminal") ? "completed" : "protocol_failed")
        let result = Result(events: events, helperReaped: helperReaped, stderrEmpty: errorBytes == 0, hostStatus: status)
        let continuation = self.continuation
        self.continuation = nil
        self.onReady = nil
        continuation?.resume(returning: result)
    }
}
