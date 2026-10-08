import Foundation
import Darwin
import Dispatch

/// A single operation against the bundled account helper. Wire content remains
/// in memory; diagnostics expose fixed host failures, never helper output.
@MainActor
final class CodexRuntimeSession {
    enum Operation: String, Codable, Sendable { case status, login, logout, models, translate }

    struct Request: Encodable, Sendable {
        let operation: Operation
        let requestID: String
        let model: String?
        let text: String?
        let sourceLanguage: String?
        let targetLanguage: String?
        let expectedGeneration: String?
        private let protocolVersion = 1

        init(operation: Operation, requestID: UUID = UUID(), model: String? = nil,
             text: String? = nil, sourceLanguage: String? = nil, targetLanguage: String? = nil,
             expectedGeneration: String? = nil) {
            self.operation = operation
            self.requestID = requestID.uuidString.lowercased()
            self.model = model
            self.text = text
            self.sourceLanguage = sourceLanguage
            self.targetLanguage = targetLanguage
            self.expectedGeneration = expectedGeneration
        }

        enum CodingKeys: String, CodingKey {
            case operation, model, text
            case protocolVersion = "protocol_version", requestID = "request_id"
            case sourceLanguage = "source_language", targetLanguage = "target_language"
            case expectedGeneration = "expected_generation"
        }

        fileprivate func encoded() throws -> Data {
            guard requestID != "00000000-0000-0000-0000-000000000000" else { throw HostFailure.invalidRequest }
            switch operation {
            case .models, .translate:
                guard let expectedGeneration, Self.canonicalGeneration(expectedGeneration) else { throw HostFailure.invalidRequest }
            case .status, .login:
                guard expectedGeneration == nil else { throw HostFailure.invalidRequest }
            case .logout:
                guard expectedGeneration.map(Self.canonicalGeneration) ?? true else { throw HostFailure.invalidRequest }
            }
            if operation == .translate {
                guard let model, Self.identifier(model, limit: 256),
                      let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= 64 * 1024,
                      let targetLanguage, Self.language(targetLanguage),
                      sourceLanguage.map(Self.language) ?? true else { throw HostFailure.invalidRequest }
            } else if model != nil || text != nil || sourceLanguage != nil || targetLanguage != nil {
                throw HostFailure.invalidRequest
            }
            let data = try JSONEncoder().encode(self)
            guard data.count <= 512 * 1024 else { throw HostFailure.invalidRequest }
            return data
        }

        fileprivate static func identifier(_ value: String, limit: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }

        static func canonicalGeneration(_ value: String) -> Bool {
            value != "00000000-0000-0000-0000-000000000000" && UUID(uuidString: value)?.uuidString.lowercased() == value
        }

        private static func language(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 63 && value.split(separator: "-", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) } }
        }
    }

    struct Model: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let reasoningEfforts: [String]
        let defaultReasoningEffort: String?

        enum CodingKeys: String, CodingKey {
            case id, name
            case reasoningEfforts = "reasoning_efforts", defaultReasoningEffort = "default_reasoning_effort"
        }
    }

    struct Event: Decodable, Sendable, Equatable {
        enum Kind: String, Decodable, Sendable { case ready, committing, terminal }
        let event: Kind
        let protocolVersion: Int
        let requestID: String
        let userCode: String?
        let verificationURL: String?
        let result: Outcome?

        enum CodingKeys: String, CodingKey {
            case event, result
            case protocolVersion = "protocol_version", requestID = "request_id"
            case userCode = "user_code", verificationURL = "verification_url"
        }
    }

    struct Outcome: Decodable, Sendable, Equatable {
        let status: String
        let text: String?
        let models: [Model]?
        let accountPlan: String?
        let generation: String?
        let remoteRevocation: String?

        enum CodingKeys: String, CodingKey {
            case status, text, models, generation
            case accountPlan = "account_plan", remoteRevocation = "remote_revocation"
        }
    }

    enum HostFailure: String, Error, Sendable { case invalidRequest, launchFailed, cancelledBeforeLaunch, protocolFailed, timedOut, cleanupRequired }
    struct Result: Sendable {
        let terminal: Event?
        let failure: HostFailure?
        let helperReaped: Bool
    }

    /// Shorter intervals are injectable for deterministic process tests. The
    /// production ceiling cannot be raised by callers.
    struct Timing {
        var login: Duration = .seconds(15 * 60)
        var operation: Duration = .seconds(90)
        var cleanup: Duration = .seconds(8)
        var terminate: Duration = .seconds(2)
        var reap: Duration = .seconds(2)
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let timing: Timing
    private var request: Request?
    private var continuation: CheckedContinuation<Result, Never>?
    private var onEvent: (@MainActor (Event) -> Void)?
    private var watchdog: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var writeTask: Task<Void, Never>?
    private var queuedInput = Data()
    private var pending = Data()
    private var outputBytes = 0
    private var stdoutEnded = false
    private var stderrEnded = false
    private var exitStatus: Int32?
    private var inputClosed = false
    private var closeAfterWrite = false
    private var cancellationRequested = false
    private var readyReceived = false
    private var committingReceived = false
    private var terminal: Event?
    private var failure: HostFailure?
    private var started = false
    private var finished = false
    private var launchAllowed = true

    init(helper: URL, timing: Timing = Timing()) {
        self.timing = timing
        guard helper.isFileURL, helper.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: helper.path),
              let temporaryDirectory = Self.systemTemporaryDirectory() else {
            launchAllowed = false
            return
        }
        process.executableURL = helper
        process.currentDirectoryURL = temporaryDirectory
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": temporaryDirectory.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Prevent unrelated later children from retaining either end of a pipe.
        for pipe in [input, output, errors] {
            for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
                let descriptor = handle.fileDescriptor
                let flags = fcntl(descriptor, F_GETFD)
                if flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) < 0 { launchAllowed = false }
            }
        }
    }

    private static func systemTemporaryDirectory() -> URL? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 1, size <= 4096 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &bytes, size) == size else { return nil }
        let path = String(decoding: bytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { return nil }
        return url
    }

    /// Returns only after a terminal event, both EOFs and process exit, or a
    /// bounded failure. Caller cancellation never rewrites a committed login.
    func run(_ request: Request, onEvent: @escaping @MainActor (Event) -> Void = { _ in }) async -> Result {
        guard !started else { return Result(terminal: nil, failure: .invalidRequest, helperReaped: !process.isRunning) }
        started = true
        guard launchAllowed else { return Result(terminal: nil, failure: .launchFailed, helperReaped: true) }
        guard let payload = try? request.encoded() else { return Result(terminal: nil, failure: .invalidRequest, helperReaped: true) }
        self.request = request
        self.onEvent = onEvent
        return await withTaskCancellationHandler {
            if Task.isCancelled || cancellationRequested {
                finished = true
                self.onEvent = nil
                return Result(terminal: nil, failure: .cancelledBeforeLaunch, helperReaped: true)
            }
            return await waitForProcess(payload)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func waitForProcess(_ payload: Data) async -> Result {
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
                try? input.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
                try? errors.fileHandleForWriting.close()
                let descriptor = input.fileHandleForWriting.fileDescriptor
                let flags = fcntl(descriptor, F_GETFL)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0,
                      fcntl(descriptor, F_SETNOSIGPIPE, 1) >= 0 else { throw HostFailure.launchFailed }
                var line = payload
                line.append(10)
                enqueue(line)
            } catch {
                failure = .launchFailed
                closeInput()
                if !process.isRunning {
                    exitStatus = -1
                    stdoutEnded = true
                    stderrEnded = true
                    completeIfReady()
                    return
                }
                beginCleanup()
            }
            let delay = request?.operation == .login ? min(timing.login, .seconds(900)) : min(timing.operation, .seconds(90))
            watchdog = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, !self.finished else { return }
                self.failure = self.failure ?? .timedOut
                self.finishInput()
            }
        }
    }

    func cancel() {
        guard !finished, !cancellationRequested, terminal == nil else { return }
        cancellationRequested = true
        guard started, let request, !inputClosed else { return }
        if let data = try? JSONSerialization.data(withJSONObject: [
            "protocol_version": 1, "request_id": request.requestID, "action": "cancel"
        ]) {
            closeAfterWrite = true
            enqueue(data + Data([10]))
        } else { closeInput() }
        beginCleanup()
    }

    /// Closing the owner closes the request pipe; the helper decides whether
    /// cancellation won the race with its durable commit.
    func finishInput() {
        cancellationRequested = true
        closeInput()
        if started, !finished { beginCleanup() }
    }

    private func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        writeTask?.cancel()
        writeTask = nil
        queuedInput.removeAll(keepingCapacity: false)
        try? input.fileHandleForWriting.close()
    }

    private func enqueue(_ data: Data) {
        guard !inputClosed else { return }
        queuedInput.append(data)
        guard writeTask == nil else { return }
        writeTask = Task { [weak self] in
            guard let self else { return }
            while !self.queuedInput.isEmpty, !self.inputClosed {
                let descriptor = self.input.fileHandleForWriting.fileDescriptor
                let written = self.queuedInput.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                if written > 0 { self.queuedInput.removeFirst(written) }
                else if written < 0, errno == EINTR { continue }
                else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                } else { self.closeInput(); self.beginCleanup(); break }
            }
            self.writeTask = nil
            if self.closeAfterWrite { self.closeInput() }
        }
    }

    private func readPipe(_ handle: FileHandle, stderr: Bool) throws -> DispatchSourceRead {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw HostFailure.launchFailed }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drainPipe(descriptor, stderr: stderr) }
        }
        source.setCancelHandler { try? handle.close() }
        source.resume()
        return source
    }

    private func drainPipe(_ descriptor: Int32, stderr: Bool) {
        guard !finished, !(stderr ? stderrEnded : stdoutEnded) else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<4 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { receive(Data(buffer.prefix(count)), stderr: stderr) }
            else if count < 0, errno == EINTR { continue }
            else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            else {
                if count < 0 { failProtocol() }
                (stderr ? errorSource : outputSource)?.cancel()
                receive(Data(), stderr: stderr)
                return
            }
            if finished { return }
        }
    }

    private func receive(_ data: Data, stderr: Bool) {
        guard !finished else { return }
        if stderr {
            if data.isEmpty { stderrEnded = true }
            else { failProtocol() } // Never retain or print a raw stderr byte.
        } else if data.isEmpty {
            stdoutEnded = true
            if !pending.isEmpty { failProtocol() }
        } else {
            outputBytes += data.count
            if outputBytes > 4 * 1024 * 1024 {
                failProtocol()
                pending.removeAll(keepingCapacity: false)
            } else if failure == nil {
                // The retained prefix was already searched for LF. Searching
                // it again per chunk makes a bounded long line quadratic work.
                var searchOffset = pending.count
                pending.append(data)
                while let newline = pending.dropFirst(searchOffset).firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    searchOffset = 0
                    accept(line)
                    if failure != nil { pending.removeAll(keepingCapacity: false); break }
                }
            }
        }
        completeIfReady()
    }

    private func accept(_ line: Data) {
        let common: Set<String> = ["event", "protocol_version", "request_id"]
        guard !line.isEmpty, terminal == nil, let request,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = try? JSONDecoder().decode(Event.self, from: line),
              event.protocolVersion == 1, event.requestID == request.requestID else { failProtocol(); return }
        var allowed = common
        switch event.event {
        case .ready:
            allowed.formUnion(["user_code", "verification_url"])
            guard request.operation == .login, !readyReceived, !committingReceived,
                  let code = event.userCode, Request.identifier(code, limit: 128),
                  code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 32 }),
                  event.verificationURL == "https://auth.openai.com/codex/device" else { failProtocol(); return }
        case .committing:
            guard request.operation == .login, readyReceived, !committingReceived else { failProtocol(); return }
        case .terminal:
            allowed.insert("result")
            guard let result = event.result, Self.statuses.contains(result.status),
                  let resultObject = object["result"] as? [String: Any] else { failProtocol(); return }
            let status = result.status
            var resultKeys: Set<String> = ["status"]
            if status == "ok" {
                if request.operation == .translate {
                    resultKeys.insert("text")
                    guard let text = result.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          text.utf8.count <= 512 * 1024 else { failProtocol(); return }
                } else if request.operation == .models {
                    resultKeys.insert("models")
                    guard let models = result.models, models.count <= 256,
                          Set(models.map(\.id)).count == models.count,
                          models.allSatisfy(Self.validModel), Self.validModelKeys(resultObject["models"]) else { failProtocol(); return }
                } else { failProtocol(); return }
            } else if status == "signed_in" {
                resultKeys.formUnion(["account_plan", "generation"])
                guard [.status, .login].contains(request.operation),
                      let generation = result.generation, UUID(uuidString: generation)?.uuidString.lowercased() == generation,
                      generation != "00000000-0000-0000-0000-000000000000",
                      result.accountPlan.map({ Request.identifier($0, limit: 128) }) ?? true,
                      request.operation != .login || committingReceived else { failProtocol(); return }
            } else if status == "signed_out" {
                guard [.status, .logout].contains(request.operation) else { failProtocol(); return }
                if request.operation == .logout {
                    resultKeys.insert("remote_revocation")
                    guard result.remoteRevocation == "unconfirmed" else { failProtocol(); return }
                }
            }
            guard Set(resultObject.keys).isSubset(of: resultKeys) else { failProtocol(); return }
        }
        guard Set(object.keys).isSubset(of: allowed) else { failProtocol(); return }
        switch event.event {
        case .ready: readyReceived = true
        case .committing: committingReceived = true
        case .terminal: terminal = event; closeInput(); beginCleanup()
        }
        // A terminal is trustworthy only after exit and both EOFs. Deliver it
        // through Result, so a later duplicate/invalid frame cannot undo UI state.
        if event.event != .terminal, !cancellationRequested || event.event != .ready { onEvent?(event) }
    }

    private static let statuses: Set<String> = [
        "ok", "signed_in", "signed_out", "cancelled", "timeout", "invalid_input", "environment_rejected", "account_changed",
        "storage_unavailable", "invalid_account_storage", "busy", "already_signed_in", "recovery_required",
        "cleanup_required", "login_unavailable", "login_failed", "authentication_failed", "network_unavailable",
        "managed_policy_denied", "model_unavailable", "request_failed", "rate_limited", "access_denied", "redirect_rejected"
    ]

    private static func validModel(_ model: Model) -> Bool {
        Request.identifier(model.id, limit: 256) && Request.identifier(model.name, limit: 256)
            && model.reasoningEfforts.count <= 16
            && Set(model.reasoningEfforts).count == model.reasoningEfforts.count
            && model.reasoningEfforts.allSatisfy { Request.identifier($0, limit: 128) }
            && (model.defaultReasoningEffort.map { model.reasoningEfforts.contains($0) } ?? true)
    }

    private static func validModelKeys(_ value: Any?) -> Bool {
        guard let models = value as? [[String: Any]] else { return false }
        let allowed: Set<String> = ["id", "name", "reasoning_efforts", "default_reasoning_effort"]
        return models.allSatisfy { Set($0.keys).isSubset(of: allowed) }
    }

    private func failProtocol() {
        if failure == nil { failure = .protocolFailed }
        closeInput()
        beginCleanup()
    }

    private func beginCleanup() {
        guard cleanupTask == nil, !finished else { return }
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: min(self.timing.cleanup, .seconds(8))) } catch { return }
            guard !self.finished else { return }
            self.failure = .cleanupRequired
            self.signalOwnedHelper(SIGTERM)
            do { try await Task.sleep(for: min(self.timing.terminate, .seconds(2))) } catch { return }
            guard !self.finished else { return }
            self.signalOwnedHelper(SIGKILL)
            // A dead helper with a descendant retaining pipes has no safe PID
            // to signal. Stop readers without touching that potentially reused ID.
            self.stopPipeReaders()
            self.stdoutEnded = true
            self.stderrEnded = true
            self.failure = .cleanupRequired
            self.completeIfReady()
            do { try await Task.sleep(for: min(self.timing.reap, .seconds(2))) } catch { return }
            if !self.finished { self.finishResult(helperReaped: self.exitStatus != nil) }
        }
    }

    private func signalOwnedHelper(_ signal: Int32) {
        guard exitStatus == nil, process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        _ = Darwin.kill(getpgid(pid) == pid ? -pid : pid, signal)
    }

    private func stopPipeReaders() {
        if let outputSource { outputSource.cancel() } else { try? output.fileHandleForReading.close() }
        if let errorSource { errorSource.cancel() } else { try? errors.fileHandleForReading.close() }
    }

    private func completeIfReady() {
        guard !finished, exitStatus != nil else { return }
        if stdoutEnded, stderrEnded { finishResult(helperReaped: true) }
        else { beginCleanup() }
    }

    private func finishResult(helperReaped: Bool) {
        guard !finished else { return }
        finished = true
        watchdog?.cancel()
        watchdog = nil
        cleanupTask?.cancel()
        cleanupTask = nil
        closeInput()
        stopPipeReaders()
        process.terminationHandler = nil
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let error = failure ?? ((exitStatus == 0 && terminal != nil) ? nil : .protocolFailed)
        let result = Result(terminal: error == nil ? terminal : nil, failure: error, helperReaped: helperReaped)
        let continuation = continuation
        self.continuation = nil
        onEvent = nil
        request = nil
        pending.removeAll(keepingCapacity: false)
        continuation?.resume(returning: result)
    }
}
