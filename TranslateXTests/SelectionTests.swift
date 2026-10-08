import AppKit
import XCTest
@testable import TranslateX

final class SelectionTests: XCTestCase {
    func testCopyEventsEndWithNoSynthesizedModifierHeld() throws {
        // Inspect the production events; do not post them or touch the clipboard.
        let copy = try SelectionCopyEvents()
        XCTAssertEqual(copy.keyDown.type, .keyDown)
        XCTAssertEqual(copy.keyUp.type, .keyUp)
        XCTAssertEqual(copy.keyDown.getIntegerValueField(.keyboardEventKeycode), 8)
        XCTAssertEqual(copy.keyUp.getIntegerValueField(.keyboardEventKeycode), 8)
        XCTAssertEqual(copy.keyDown.flags, .maskCommand, "Copy must remain Command-C")
        XCTAssertTrue(copy.keyUp.flags.isEmpty, "Copy must release its own Command flag")
        XCTAssertEqual(copy.keyDown.getIntegerValueField(.eventSourceStateID),
                       copy.keyUp.getIntegerValueField(.eventSourceStateID))
        XCTAssertNotEqual(copy.keyDown.getIntegerValueField(.eventSourceStateID),
                          Int64(CGEventSourceStateID.combinedSessionState.rawValue))
        XCTAssertNotEqual(copy.keyDown.getIntegerValueField(.eventSourceStateID),
                          Int64(CGEventSourceStateID.hidSystemState.rawValue))
    }

    func testOldClipboardNeverBecomesAResult() {
        var observation = CopyObservation(initialChangeCount: 10)
        XCTAssertEqual(observation.observe(10), .waiting)
        XCTAssertNil(observation.copiedChangeCount)
        XCTAssertFalse(observation.mayRestore(currentChangeCount: 10, sourceIsStillActive: true))
    }

    func testFreshCopyCanBeRestoredOnlyWhileStillOwned() {
        var observation = CopyObservation(initialChangeCount: 10)
        XCTAssertEqual(observation.observe(11), .candidate)
        XCTAssertTrue(observation.mayRestore(currentChangeCount: 11, sourceIsStillActive: true))
        XCTAssertFalse(observation.mayRestore(currentChangeCount: 12, sourceIsStillActive: true))
        XCTAssertFalse(observation.mayRestore(currentChangeCount: 11, sourceIsStillActive: false))
    }

    func testLaterWriteInvalidatesRatherThanBecomingNewCandidate() {
        var observation = CopyObservation(initialChangeCount: 10)
        XCTAssertEqual(observation.observe(11), .candidate)
        XCTAssertEqual(observation.observe(12), .interference)
        XCTAssertEqual(observation.copiedChangeCount, 11)
        XCTAssertEqual(observation.observe(11), .interference)
        XCTAssertFalse(observation.mayRestore(currentChangeCount: 11, sourceIsStillActive: true))
    }

    func testFirstPollRejectsMultipleOwnerChangesAndCannotRestoreThem() {
        var observation = CopyObservation(initialChangeCount: 10)
        XCTAssertEqual(observation.observe(12), .interference)
        XCTAssertTrue(observation.hasInterference)
        XCTAssertNil(observation.copiedChangeCount)
        XCTAssertFalse(observation.mayRestore(currentChangeCount: 12, sourceIsStillActive: true))
        XCTAssertEqual(observation.observe(11), .interference)
    }

    func testFirstPollAfterWaitingStillRejectsSkippedCopyGeneration() {
        var observation = CopyObservation(initialChangeCount: 10)
        XCTAssertEqual(observation.observe(10), .waiting)
        XCTAssertEqual(observation.observe(10), .waiting)
        XCTAssertEqual(observation.observe(13), .interference)
        XCTAssertNil(observation.copiedChangeCount)
        XCTAssertFalse(observation.mayRestore(currentChangeCount: 13, sourceIsStillActive: true))
    }

    func testSingleOwnershipChangeHandlesCounterWraparound() {
        var observation = CopyObservation(initialChangeCount: Int.max)
        XCTAssertEqual(observation.observe(Int.min), .candidate)
        XCTAssertTrue(observation.mayRestore(currentChangeCount: Int.min, sourceIsStillActive: true))
    }

    func testMultipleOwnershipChangesAcrossCounterWraparoundAreRejected() {
        var observation = CopyObservation(initialChangeCount: Int.max)
        XCTAssertEqual(observation.observe(Int.min + 1), .interference)
        XCTAssertNil(observation.copiedChangeCount)
        XCTAssertFalse(observation.mayRestore(currentChangeCount: Int.min + 1, sourceIsStillActive: true))
    }

    func testWhitespaceIsNotASelectionAndParagraphsArePreserved() throws {
        XCTAssertThrowsError(try SelectionText.validated(" \n\t ")) { error in
            XCTAssertEqual(error as? SelectionError, .noSelection)
        }
        XCTAssertEqual(try SelectionText.validated("  First line.\n第二行。  "), "First line.\n第二行。")
    }

    func testOversizedSelectionIsRejectedRatherThanTruncated() {
        XCTAssertThrowsError(try SelectionText.validated(String(repeating: "a", count: SelectionText.maximumLength + 1))) { error in
            XCTAssertEqual(error as? SelectionError, .textTooLong)
        }
    }

    @MainActor
    func testClipboardBackupRestoresAllRepresentationsOnPrivatePasteboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let original = NSPasteboardItem()
        original.setString("Public test text", forType: .string)
        let customType = NSPasteboard.PasteboardType("com.lumax.tsx.test-format")
        let customData = Data([0, 1, 2, 3])
        original.setData(customData, forType: customType)
        pasteboard.writeObjects([original])
        let clipboard = SelectionClipboard(pasteboardName: pasteboard.name.rawValue)
        let backup = try await clipboard.backup()
        pasteboard.clearContents()
        pasteboard.setString("Temporary copied text", forType: .string)
        let copyGeneration = pasteboard.changeCount
        let copiedText = try await clipboard.readText(expectedChangeCount: copyGeneration)
        XCTAssertEqual(copiedText, "Temporary copied text")
        let restored = try await clipboard.restore(backup, expectedChangeCount: copyGeneration) { true }
        XCTAssertTrue(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "Public test text")
        XCTAssertEqual(pasteboard.data(forType: customType), customData)
    }

    @MainActor
    func testClipboardBackupRestoresMultipleItemsWithoutMergingFormatsOrChangingOrder() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = NSPasteboardItem()
        let firstHTML = Data("<p>First public passage.</p>".utf8)
        XCTAssertTrue(first.setString("First public passage.", forType: .string))
        XCTAssertTrue(first.setData(firstHTML, forType: .html))
        let second = NSPasteboardItem()
        let secondRTF = Data(#"{\rtf1\ansi Second public passage.}"#.utf8)
        XCTAssertTrue(second.setString("Second public passage.", forType: .string))
        XCTAssertTrue(second.setData(secondRTF, forType: .rtf))
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
        let originalTypes = try XCTUnwrap(pasteboard.pasteboardItems).map { Set($0.types) }
        let clipboard = SelectionClipboard(pasteboardName: pasteboard.name.rawValue)
        let backup = try await clipboard.backup()

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Temporary copied selection", forType: .string))
        let restored = try await clipboard.restore(backup, expectedChangeCount: pasteboard.changeCount) { true }

        XCTAssertTrue(restored)
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        guard items.count == 2 else {
            XCTFail("Restoring must preserve each original pasteboard item")
            return
        }
        XCTAssertEqual(items.map { Set($0.types) }, originalTypes)
        XCTAssertEqual(items[0].string(forType: .string), "First public passage.")
        XCTAssertEqual(items[0].data(forType: .html), firstHTML)
        XCTAssertEqual(items[1].string(forType: .string), "Second public passage.")
        XCTAssertEqual(items[1].data(forType: .rtf), secondRTF)
    }

    @MainActor
    func testRestoringInitiallyEmptyClipboardRemovesTemporaryCopy() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let clipboard = SelectionClipboard(pasteboardName: pasteboard.name.rawValue)
        let backup = try await clipboard.backup()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Temporary copied selection", forType: .string))

        let restored = try await clipboard.restore(backup, expectedChangeCount: pasteboard.changeCount) { true }

        XCTAssertTrue(restored)
        XCTAssertTrue((pasteboard.pasteboardItems ?? []).isEmpty)
        XCTAssertTrue((pasteboard.types ?? []).isEmpty)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    @MainActor
    func testBackupCapacityLimitIncludesEveryItemAndLeavesOriginalsUntouched() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("com.lumax.tsx.test-format")
        let firstData = Data(repeating: 0x12, count: 4 * 1_024 * 1_024 + 1)
        let secondData = Data(repeating: 0x34, count: 4 * 1_024 * 1_024 + 1)
        let first = NSPasteboardItem()
        let second = NSPasteboardItem()
        XCTAssertTrue(first.setData(firstData, forType: customType))
        XCTAssertTrue(second.setData(secondData, forType: customType))
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
        let generation = pasteboard.changeCount
        let clipboard = SelectionClipboard(pasteboardName: pasteboard.name.rawValue)

        do {
            _ = try await clipboard.backup()
            XCTFail("Individually small items must not bypass the total backup limit")
        } catch {
            XCTAssertEqual(error as? SelectionError, .clipboardUnavailable)
        }

        XCTAssertEqual(pasteboard.changeCount, generation)
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        guard items.count == 2 else {
            XCTFail("Failed backup must leave every original item intact")
            return
        }
        XCTAssertTrue(items[0].data(forType: customType) == firstData)
        XCTAssertTrue(items[1].data(forType: customType) == secondData)
    }

    @MainActor
    func testOversizedBackupLeavesPrivatePasteboardUntouched() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(Data(count: 8 * 1_024 * 1_024 + 1), forType: .png)
        let generation = pasteboard.changeCount
        let clipboard = SelectionClipboard(pasteboardName: pasteboard.name.rawValue)
        do {
            _ = try await clipboard.backup()
            XCTFail("An oversized clipboard must not be copied automatically")
        } catch {
            XCTAssertEqual(error as? SelectionError, .clipboardUnavailable)
        }
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.data(forType: .png)?.count, 8 * 1_024 * 1_024 + 1)
    }

    @MainActor
    func testActorRestorePreservesNewerClipboardWrite() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Original", forType: .string)
        let clipboard = SelectionClipboard(pasteboardName: pasteboard.name.rawValue)
        let backup = try await clipboard.backup()
        pasteboard.clearContents()
        pasteboard.setString("Copied selection", forType: .string)
        let copyGeneration = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("A newer deliberate copy", forType: .string)
        let restored = try await clipboard.restore(backup, expectedChangeCount: copyGeneration) { true }
        XCTAssertFalse(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "A newer deliberate copy")
    }

    @MainActor
    func testActorRestoreDoesNotWriteAfterSourceLosesFocus() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Original", forType: .string)
        let clipboard = SelectionClipboard(pasteboardName: pasteboard.name.rawValue)
        let backup = try await clipboard.backup()
        pasteboard.clearContents()
        pasteboard.setString("Copied selection", forType: .string)
        let generation = pasteboard.changeCount
        let restored = try await clipboard.restore(backup, expectedChangeCount: generation) { false }
        XCTAssertFalse(restored)
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.string(forType: .string), "Copied selection")
    }

    @MainActor
    func testActorRejectsReadingAChangedCopyGeneration() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Original", forType: .string)
        let generation = pasteboard.changeCount
        let clipboard = SelectionClipboard(pasteboardName: pasteboard.name.rawValue)
        pasteboard.clearContents()
        pasteboard.setString("Different content", forType: .string)
        do {
            _ = try await clipboard.readText(expectedChangeCount: generation)
            XCTFail("Content from a different copy operation must be rejected")
        } catch {
            XCTAssertEqual(error as? SelectionError, .clipboardChanged)
        }
    }
}

/// Full production transaction, private pasteboard, controlled system boundaries.
/// No cross-app AX calls or key events are sent by these tests.
@MainActor
final class SelectionWorkflowTests: XCTestCase {
    func testCopyWaitsForDeliberateShortcutReleaseBeyondHalfASecond() async throws {
        let f = fixture()
        f.modifiersPressed = true
        let release = Task {
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertEqual(f.copies, 0, "Do not Copy while the shortcut is held")
            f.modifiersPressed = false
        }
        defer { release.cancel() }
        let selected = try await f.service.capture(from: f.source())
        try await release.value
        XCTAssertEqual(selected.text, "Copied sample")
        XCTAssertEqual(f.copies, 1)
        XCTAssertEqual(f.board.string(forType: .string), "ORIGINAL")
    }

    func testHeldShortcutTimesOutWithoutCopyOrClipboardMutation() async {
        let f = fixture()
        f.modifiersPressed = true
        let generation = f.board.changeCount
        await expect(.shortcutStillPressed, f)
        XCTAssertEqual(f.copies, 0)
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertFalse(f.service.hasActiveCapture)
    }

    func testCancellationWhileWaitingForShortcutReleaseNeverCopies() async throws {
        let f = fixture()
        f.modifiersPressed = true
        let source = try f.source()
        let generation = f.board.changeCount
        let capture = Task { try await f.service.capture(from: source) }
        defer { capture.cancel() }
        try await f.waitUntilWaitingForRelease()
        await f.service.cancelAndWait()
        f.modifiersPressed = false
        do { _ = try await capture.value; XCTFail("Cancelled capture must stop before Copy") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(f.copies, 0)
        XCTAssertEqual(f.board.changeCount, generation)
        XCTAssertFalse(f.service.hasActiveCapture)
    }

    func testChangingSourceWhileHoldingShortcutNeverCopies() async throws {
        let f = fixture()
        f.modifiersPressed = true
        let source = try f.source()
        let generation = f.board.changeCount
        let capture = Task { try await f.service.capture(from: source) }
        defer { capture.cancel() }
        try await f.waitUntilWaitingForRelease()
        f.active = false
        do { _ = try await capture.value; XCTFail("Must not copy after source changes") }
        catch { XCTAssertEqual(error as? SelectionError, .sourceChanged) }
        XCTAssertEqual(f.copies, 0)
        XCTAssertEqual(f.board.changeCount, generation)
    }

    func testClipboardInterferenceStillPreservesNewCopyAfterSlowShortcutRelease() async throws {
        let f = fixture()
        f.modifiersPressed = true
        f.afterCopy = { [unowned f] in f.write("NEW USER COPY") }
        let release = Task {
            try await Task.sleep(for: .milliseconds(700))
            f.modifiersPressed = false
        }
        defer { release.cancel() }
        await expect(.clipboardChanged, f)
        try await release.value
        XCTAssertEqual(f.copies, 1)
        XCTAssertEqual(f.board.string(forType: .string), "NEW USER COPY")
    }

    func testDirectAXResultNeverCopiesOrChangesClipboard() async throws {
        let f = fixture()
        f.readResult = .text("Direct sample", bounds: nil)
        let result = try await f.service.capture(from: f.source())
        XCTAssertEqual(result.text, "Direct sample")
        if case .accessibility = result.method {} else { XCTFail("Expected AX") }
        XCTAssertEqual(f.copies, 0)
        XCTAssertEqual(f.board.string(forType: .string), "ORIGINAL")
    }

    func testCopyReturnsFreshTextAndRestoresOriginal() async throws {
        let f = fixture()
        let result = try await f.service.capture(from: f.source())
        XCTAssertEqual(result.text, "Copied sample")
        if case .copy = result.method {} else { XCTFail("Expected copy") }
        XCTAssertEqual(f.copies, 1)
        XCTAssertEqual(f.board.string(forType: .string), "ORIGINAL")
        XCTAssertFalse(f.service.hasActiveCapture)
    }

    func testPermissionFailureNeverReadsOrCopies() async {
        let f = fixture()
        f.trusted = false
        await expect(.accessibilityPermissionRequired, f)
        XCTAssertEqual(f.reads, 0)
        XCTAssertEqual(f.copies, 0)
    }

    func testEmptySecureAndUnavailableSelectionsNeverCopy() async {
        for error in [SelectionError.noSelection, .secureInput, .sourceUnavailable] {
            let f = fixture()
            f.readError = error
            await expect(error, f)
            XCTAssertEqual(f.copies, 0)
            XCTAssertEqual(f.board.string(forType: .string), "ORIGINAL")
        }
    }

    func testChangedSourceAfterAXReadCannotPostCopy() async {
        let f = fixture()
        f.afterRead = { [unowned f] in f.active = false }
        await expect(.sourceChanged, f)
        XCTAssertEqual(f.copies, 0)
    }

    func testNewClipboardWriteBeforePostingPreventsCopy() async {
        let f = fixture()
        f.beforeCopy = { [unowned f] in f.write("NEW USER COPY") }
        await expect(.clipboardChanged, f)
        XCTAssertEqual(f.copies, 0)
        XCTAssertEqual(f.board.string(forType: .string), "NEW USER COPY")
    }

    func testMultipleWritesBeforeFirstObservationKeepNewestClipboard() async {
        let f = fixture()
        f.afterCopy = { [unowned f] in f.write("NEW USER COPY") }
        await expect(.clipboardChanged, f)
        XCTAssertEqual(f.copies, 1)
        XCTAssertEqual(f.board.string(forType: .string), "NEW USER COPY")
    }

    func testNoClipboardChangeTimesOutRatherThanReadingOldText() async {
        let f = fixture()
        f.writesCopy = false
        await expect(.copyTimedOut, f)
        XCTAssertEqual(f.board.string(forType: .string), "ORIGINAL")
    }

    func testCancelledPostedCopyRestoresBeforeReleasingBusyState() async throws {
        let f = fixture()
        f.holdAfterCopy = true
        let source = try f.source()
        let capture = Task { try await f.service.capture(from: source) }
        defer { capture.cancel(); f.release() }
        try await f.waitUntilHeld()
        capture.cancel()
        f.service.cancel()
        await expect(.busy, f)
        XCTAssertTrue(f.service.hasActiveCapture)
        f.release()
        do { _ = try await capture.value; XCTFail("Cancelled text must be discarded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(f.board.string(forType: .string), "ORIGINAL")
        XCTAssertFalse(f.service.hasActiveCapture)
    }

    func testNormalQuitWaitsForPostedCopyCleanup() async throws {
        let f = fixture()
        f.holdAfterCopy = true
        let source = try f.source()
        let capture = Task { try await f.service.capture(from: source) }
        defer { capture.cancel(); f.release() }
        try await f.waitUntilHeld()
        var quitStarted = false
        var quitFinished = false
        let quit = Task {
            quitStarted = true
            await f.service.cancelAndWait()
            quitFinished = true
        }
        while !quitStarted { await Task.yield() }
        XCTAssertFalse(quitFinished)
        XCTAssertTrue(f.service.hasActiveCapture)
        f.release()
        await quit.value
        do { _ = try await capture.value; XCTFail("Quit must discard selection") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(quitFinished)
        XCTAssertEqual(f.board.string(forType: .string), "ORIGINAL")
    }

    func testFocusLossDuringCopyPreservesOtherWork() async {
        let f = fixture()
        f.afterCopy = { [unowned f] in f.active = false; f.write("OTHER WORK") }
        await expect(.sourceChanged, f)
        XCTAssertEqual(f.board.string(forType: .string), "OTHER WORK")
    }

    private func expect(_ expected: SelectionError, _ f: SelectionWorkflowFixture) async {
        do { _ = try await f.service.capture(from: f.source()); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? SelectionError, expected) }
    }

    private func fixture() -> SelectionWorkflowFixture {
        let f = SelectionWorkflowFixture()
        addTeardownBlock { await MainActor.run { f.release(); f.board.releaseGlobally() } }
        return f
    }
}

@MainActor
private final class SelectionWorkflowFixture {
    let board = NSPasteboard(name: .init("TranslateXWorkflow-\(UUID().uuidString)"))
    var trusted = true
    var active = true
    var reads = 0
    var copies = 0
    var writesCopy = true
    var modifiersPressed = false
    var modifierChecks = 0
    var holdAfterCopy = false
    var readResult: AXSelectionReader.Result = .copyCandidate(UUID())
    var readError: SelectionError?
    var afterRead: (() -> Void)?
    var beforeCopy: (() -> Void)?
    var afterCopy: (() -> Void)?
    private var held: CheckedContinuation<Void, Never>?
    lazy var service = SelectionService(
        environment: SelectionEnvironment(
            isTrusted: { [unowned self] in trusted },
            sourceIsActive: { [unowned self] _ in active },
            modifiersArePressed: { [unowned self] in
                modifierChecks += 1
                return modifiersPressed
            },
            read: { [unowned self] _ in try await read() },
            copy: { [unowned self] _, _, before in try await copy(before: before) }
        ), clipboard: SelectionClipboard(pasteboardName: board.name.rawValue)
    )

    init() { write("ORIGINAL") }

    // Only public process identity; all system boundaries above are controlled.
    func source() throws -> NSRunningApplication {
        try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        })
    }

    func write(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func read() throws -> AXSelectionReader.Result {
        reads += 1
        if let readError { throw readError }
        afterRead?()
        return readResult
    }

    func copy(before: SelectionEnvironment.BeforeCopy) async throws {
        beforeCopy?()
        try await before()
        copies += 1
        if writesCopy { write("Copied sample") }
        afterCopy?()
        if holdAfterCopy { await withCheckedContinuation { held = $0 } }
    }

    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while held == nil {
            guard ContinuousClock.now < deadline else { throw SelectionError.copyTimedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func waitUntilWaitingForRelease() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while modifierChecks == 0 {
            guard ContinuousClock.now < deadline else { throw SelectionError.copyTimedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func release() { held?.resume(); held = nil }
}
