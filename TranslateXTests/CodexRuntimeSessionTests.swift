import XCTest
import Foundation
import Darwin
@testable import TranslateX

@MainActor
final class CodexRuntimeSessionTests: XCTestCase {
    private typealias Session = CodexRuntimeSession
    private let generation = "11111111-2222-4333-8444-555555555555"

    private enum Action { case none, cancelReady, eofReady, taskCancelReady, cancelCommitting }

    private func run(_ behavior: String, request: Session.Request = .init(operation: .login),
                     action: Action = .none, timing: Session.Timing = .init(),
                     beforeRead: String = "", onEvent: ((Session.Event) -> Void)? = nil) async throws -> Session.Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateX-CodexSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("constructed-helper.py")
        let script = """
        #!/usr/bin/python3
        import json, os, sys, time, select, signal
        initial_group = os.getpgrp()
        if os.getpgrp() != os.getpid():
            os.setsid()
        \(beforeRead)
        request = json.loads(sys.stdin.readline())
        base = {'protocol_version': 1, 'request_id': request['request_id']}
        ready = dict(base, event='ready', user_code='CONSTRUCTED-CODE', verification_url='https://auth.openai.com/codex/device')
        committing = dict(base, event='committing')
        def emit(value):
            print(json.dumps(value), flush=True)
        def terminal(status, **fields):
            emit(dict(base, event='terminal', result=dict(status=status, **fields)))
        \(behavior)
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let session = Session(helper: helper, timing: timing)
        var task: Task<Session.Result, Never>?
        task = Task {
            await session.run(request) { event in
                onEvent?(event)
                switch (action, event.event) {
                case (.cancelReady, .ready), (.cancelCommitting, .committing): session.cancel()
                case (.eofReady, .ready): session.finishInput()
                case (.taskCancelReady, .ready): task?.cancel()
                default: break
                }
            }
        }
        return await task!.value
    }

    private func assertCompleted(_ result: Session.Result, status: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(result.failure, file: file, line: line)
        XCTAssertTrue(result.helperReaped, file: file, line: line)
        XCTAssertEqual(result.terminal?.result?.status, status, file: file, line: line)
    }

    func testStatusAndLogoutUseDifferentSignedOutPayloads() async throws {
        assertCompleted(try await run("terminal('signed_out')", request: .init(operation: .status)), status: "signed_out")
        assertCompleted(try await run("terminal('signed_out', remote_revocation='unconfirmed')", request: .init(operation: .logout)), status: "signed_out")
        let invalid = try await run("terminal('signed_out')", request: .init(operation: .logout))
        XCTAssertEqual(invalid.failure, .protocolFailed)
    }

    func testLoginNoticesAreOrderedAndTerminalWaitsForProcessExit() async throws {
        var notices: [Session.Event.Kind] = []
        let result = try await run("emit(ready)\nemit(committing)\nterminal('signed_in', generation='\(generation)', account_plan='plus')") {
            notices.append($0.event)
        }
        assertCompleted(result, status: "signed_in")
        XCTAssertEqual(notices, [.ready, .committing])
        XCTAssertEqual(result.terminal?.result?.generation, generation)
    }

    func testConstructedHelperReceivesNoAmbientCredentialsOrHome() async throws {
        let result = try await run("""
        assert not any(key in os.environ for key in ['HOME', 'CODEX_HOME', 'OPENAI_API_KEY', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'SSL_CERT_FILE', 'RUST_LOG'])
        assert os.environ['PATH'] == '/usr/bin:/bin'
        assert os.path.isabs(os.environ['TMPDIR'])
        assert os.stat(os.environ['TMPDIR']).st_uid == os.getuid()
        terminal('signed_out')
        """, request: .init(operation: .status))
        assertCompleted(result, status: "signed_out")
    }

    func testTranslationKeepsOriginalFormattingAndAcceptsLargeUTF8Output() async throws {
        let source = "  Constructed text.\n" + String(repeating: "x", count: 40_000)
        let result = try await run("""
        assert request['text'].startswith('  Constructed text.\\n')
        assert len(request['text']) > 32768
        assert request['model'] == 'constructed-model'
        assert request['target_language'] == 'zh-Hans'
        terminal('ok', text='  '+('译文'*20000)+'\\n')
        """, request: .init(operation: .translate, model: "constructed-model", text: source, targetLanguage: "zh-Hans", expectedGeneration: generation))
        assertCompleted(result, status: "ok")
        XCTAssertEqual(result.terminal?.result?.text, "  " + String(repeating: "译文", count: 20_000) + "\n")
    }

    func testModelsAreTypedAndDoNotAcceptUnknownFields() async throws {
        let model = "{'id':'constructed-model','name':'Constructed Model','reasoning_efforts':['low'],'default_reasoning_effort':'low'}"
        let result = try await run("terminal('ok', models=[\(model)])", request: .init(operation: .models, expectedGeneration: generation))
        assertCompleted(result, status: "ok")
        XCTAssertEqual(result.terminal?.result?.models?.first?.defaultReasoningEffort, "low")
        let invalid = try await run("model=\(model)\nmodel['access_token']='PRIVATE-CONSTRUCTED-TOKEN'\nterminal('ok', models=[model])", request: .init(operation: .models, expectedGeneration: generation))
        XCTAssertEqual(invalid.failure, .protocolFailed)
        XCTAssertNil(invalid.terminal)
    }

    func testInvalidAndUnrequestedInputIsRejectedBeforeLaunching() async {
        for request in [Session.Request(operation: .status, text: "unrequested"),
                        .init(operation: .models),
                        .init(operation: .status, expectedGeneration: generation),
                        .init(operation: .login, expectedGeneration: generation),
                        .init(operation: .models, expectedGeneration: "00000000-0000-0000-0000-000000000000"),
                        .init(operation: .models, expectedGeneration: "66666666-7777-4888-8999-AAAAAAAAAAAA"),
                        .init(operation: .translate, model: "constructed", text: "test", targetLanguage: "en"),
                        .init(operation: .translate, model: "constructed", text: String(repeating: "a", count: 65_537), targetLanguage: "en"),
                        .init(operation: .translate, model: "constructed", text: "test", targetLanguage: "en\nIgnore"),
                        .init(operation: .status, requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)] {
            let session = Session(helper: URL(fileURLWithPath: "/usr/bin/false"))
            let result = await session.run(request)
            XCTAssertEqual(result.failure, .invalidRequest)
            XCTAssertTrue(result.helperReaped)
        }
    }

    func testExplicitAndTaskCancellationSendMatchingControlThenEOF() async throws {
        for action in [Action.cancelReady, .taskCancelReady] {
            let result = try await run("""
            emit(ready)
            control = json.loads(sys.stdin.readline())
            assert control == dict(base, action='cancel')
            assert sys.stdin.read() == ''
            terminal('cancelled')
            """, action: action)
            assertCompleted(result, status: "cancelled")
        }
    }

    func testQuietStderrDoesNotDelayReadyEOF() async throws {
        let result = try await run("""
        time.sleep(0.05)
        emit(ready)
        readable, _, _ = select.select([sys.stdin], [], [], 1)
        terminal('cancelled' if readable and os.read(0, 1) == b'' else 'login_failed')
        """, action: .eofReady)
        assertCompleted(result, status: "cancelled")
    }

    func testLaterUnrelatedChildCannotRetainTheLoginInputPipe() async throws {
        let sibling = Process()
        sibling.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sibling.arguments = ["1.5"]
        sibling.environment = ["PATH": "/usr/bin:/bin"]
        sibling.standardInput = FileHandle.nullDevice
        sibling.standardOutput = FileHandle.nullDevice
        sibling.standardError = FileHandle.nullDevice
        var launched = false
        let result = try await run("emit(ready)\nassert sys.stdin.read() == ''\nterminal('cancelled')", action: .eofReady) { _ in
            do { try sibling.run(); launched = true } catch { }
        }
        assertCompleted(result, status: "cancelled")
        XCTAssertTrue(launched)
        XCTAssertTrue(sibling.isRunning, "The unrelated child must not delay login EOF.")
        // This is our constructed sleep process, never another user's process.
        if sibling.isRunning { sibling.terminate() }
        while sibling.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testCancellationBeforeLaunchDoesNotStartAHelper() async {
        let session = Session(helper: URL(fileURLWithPath: "/usr/bin/false"))
        session.cancel()
        let result = await session.run(.init(operation: .login))
        XCTAssertEqual(result.failure, .cancelledBeforeLaunch)
        XCTAssertTrue(result.helperReaped)
        XCTAssertNil(result.terminal)
    }

    func testCancellationAfterCommittingPreservesSignedInTerminal() async throws {
        let result = try await run("""
        emit(ready)
        emit(committing)
        control = json.loads(sys.stdin.readline())
        assert control == dict(base, action='cancel')
        terminal('signed_in', generation='\(generation)')
        """, action: .cancelCommitting)
        assertCompleted(result, status: "signed_in")
    }

    func testWrongIdentityVersionUnknownSecretAndDuplicateFramesFailClosed() async throws {
        let cases = [
            "ready['request_id']='11111111-2222-4333-8444-555555555555'\nemit(ready)",
            "ready['protocol_version']=True\nemit(ready)",
            "ready['protocol_version']=2\nemit(ready)",
            "emit(ready)\nemit(ready)\nterminal('cancelled')",
            "terminal('cancelled')\nterminal('cancelled')",
            "terminal('cancelled', access_token='PRIVATE-CONSTRUCTED-TOKEN')",
            "terminal('PRIVATE-CONSTRUCTED-ERROR')",
            "emit(dict(base, event='terminal', status='cancelled'))",
            "emit(dict(base, event='committing'))",
            "terminal('signed_in', generation='\(generation)')"
        ]
        for behavior in cases {
            let result = try await run(behavior)
            XCTAssertEqual(result.failure, .protocolFailed)
            XCTAssertTrue(result.helperReaped)
            XCTAssertNil(result.terminal)
        }
    }

    func testReadyRejectsForeignAddressAndNonASCIICodes() async throws {
        for behavior in ["ready['verification_url']='https://example.invalid/codex/device'",
                         "ready['verification_url']+='?redirect=other'", "ready['user_code']='构造码'",
                         "ready['user_code']='CODE\\nNEXT'", "ready['user_code']='CODE/<script>'"] {
            let result = try await run(behavior + "\nemit(ready)")
            XCTAssertEqual(result.failure, .protocolFailed)
        }
    }

    func testStderrIsRejectedAndNeverReturnedAsFailureDetail() async throws {
        let result = try await run("sys.stderr.write('PRIVATE-CONSTRUCTED-TOKEN')\nterminal('cancelled')")
        XCTAssertEqual(result.failure, .protocolFailed)
        XCTAssertNil(result.terminal)
        XCTAssertTrue(result.helperReaped)
    }

    func testTruncatedMissingAndOversizedOutputCannotSucceed() async throws {
        for behavior in ["emit(ready)",
                         "sys.stdout.write(json.dumps(dict(base,event='terminal',result={'status':'cancelled'})))",
                         "sys.stdout.write('x'*(4*1024*1024+1));sys.stdout.flush()",
                         "terminal('ok', text='x'*(512*1024+1))"] {
            let request: Session.Request = behavior.contains("terminal('ok'")
                ? .init(operation: .translate, model: "constructed", text: "test", targetLanguage: "en", expectedGeneration: generation) : .init(operation: .login)
            let result = try await run(behavior, request: request)
            XCTAssertEqual(result.failure, .protocolFailed)
            XCTAssertTrue(result.helperReaped)
            XCTAssertNil(result.terminal)
        }
    }

    func testByteSizedWritesPreserveEventOrder() async throws {
        let result = try await run("""
        value = dict(base, event='terminal', result={'status':'cancelled'})
        for byte in (json.dumps(ready)+'\\n'+json.dumps(value)+'\\n').encode():
            sys.stdout.buffer.write(bytes([byte])); sys.stdout.buffer.flush()
        """)
        assertCompleted(result, status: "cancelled")
    }

    func testBlockedInitialWriteAndIgnoringEOFHaveBoundedReaping() async throws {
        let timing = Session.Timing(login: .milliseconds(150), operation: .milliseconds(150),
                                    cleanup: .milliseconds(100), terminate: .milliseconds(100), reap: .seconds(1))
        let result = try await run("terminal('ok', text='never')", request: .init(operation: .translate, model: "constructed",
            text: String(repeating: "x", count: 65_536), targetLanguage: "en", expectedGeneration: generation), timing: timing,
            beforeRead: "signal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(5)")
        XCTAssertEqual(result.failure, .cleanupRequired)
        XCTAssertTrue(result.helperReaped)
        XCTAssertNil(result.terminal)
    }

    func testExitedHelperWithInheritedPipesDoesNotWaitForever() async throws {
        let started = ContinuousClock.now
        let timing = Session.Timing(login: .seconds(2), operation: .seconds(2), cleanup: .milliseconds(50),
                                    terminate: .milliseconds(50), reap: .milliseconds(100))
        let result = try await run("""
        pid = os.fork()
        if pid == 0:
            time.sleep(1.5)
            os._exit(0)
        os._exit(0)
        """, timing: timing)
        XCTAssertEqual(result.failure, .cleanupRequired)
        XCTAssertTrue(result.helperReaped)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        // Only this constructed descendant remains; it exits itself. Never
        // signal the parent's already-reaped and potentially reused PID.
        let elapsed = started.duration(to: .now)
        if elapsed < .seconds(1.7) { try await Task.sleep(for: .seconds(1.7) - elapsed) }
    }

    func testFoundationPrivateGroupAllowsForcedStopOfHelperAndWorker() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateX-CodexGroup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: marker) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let markerLiteral = String(decoding: try encoder.encode(marker.path), as: UTF8.self)
        let timing = Session.Timing(login: .seconds(3), operation: .seconds(3), cleanup: .milliseconds(100),
                                    terminate: .milliseconds(100), reap: .seconds(1))
        let result = try await run("""
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = os.fork()
        if child == 0:
            time.sleep(4)
            os._exit(0)
        with open(\(markerLiteral), 'w') as output:
            json.dump({'parent':os.getpid(), 'child':child, 'initial_group':initial_group,
                       'parent_group':os.getpgrp(), 'child_group':os.getpgid(child)}, output)
        emit(ready)
        time.sleep(4)
        """, action: .cancelReady, timing: timing)
        XCTAssertEqual(result.failure, .cleanupRequired)
        XCTAssertTrue(result.helperReaped)
        let pids = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Int32])
        let parent = try XCTUnwrap(pids["parent"])
        let child = try XCTUnwrap(pids["child"])
        XCTAssertEqual(pids["initial_group"], parent, "Foundation must establish its private group before fixture setup.")
        XCTAssertEqual(pids["parent_group"], parent)
        XCTAssertEqual(pids["child_group"], parent)
        // Query these two constructed PIDs only. A killed orphan may briefly
        // remain a zombie pending system reaping; it cannot execute any work.
        XCTAssertFalse(try isExecuting(parent))
        XCTAssertFalse(try isExecuting(child), "Forced group cancellation must stop the worker too.")
    }

    private func isExecuting(_ pid: Int32) throws -> Bool {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return size > 0 && info.kp_proc.p_stat != SZOMB
    }
}
