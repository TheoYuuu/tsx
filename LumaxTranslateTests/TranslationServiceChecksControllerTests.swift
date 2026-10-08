import Foundation
import XCTest
@testable import LumaxTranslate

@MainActor
final class TranslationServiceChecksControllerTests: XCTestCase {
    func testRepeatedClickCancelsAndCannotOverlapWhileSampleIsDraining() async throws {
        let fixture = try ChecksFixture()
        defer { fixture.cleanup() }
        let provider = HeldCheckProvider()
        let controller = TranslationServiceChecksController(services: fixture.services, testProvider: { _ in provider })
        controller.toggle(fixture.first)
        try await waitUntil { provider.requests.count == 1 }
        XCTAssertEqual(controller.editor(for: fixture.first.id)?.testState, .running)
        controller.toggle(fixture.first)
        XCTAssertEqual(controller.editor(for: fixture.first.id)?.testState, .stopping)
        for _ in 0..<5 { controller.toggle(fixture.first) }
        await settle()
        XCTAssertEqual(provider.requests.count, 1)
        provider.completeAll()
        try await waitUntil { controller.editor(for: fixture.first.id)?.testState == .stopped }
        XCTAssertEqual(provider.cancellations, [true])
        XCTAssertNil(fixture.services.sampleTestRecord(for: fixture.first.id))
        controller.toggle(fixture.first)
        try await waitUntil { provider.requests.count == 2 }
        provider.completeAll()
        try await waitUntil { controller.editor(for: fixture.first.id)?.testState == .succeeded }
        XCTAssertEqual(fixture.services.sampleTestOutcome(for: fixture.first), .succeeded)
    }

    func testListKeepsOnlyOneSampleInFlightAndOnlyUsesFixedSampleText() async throws {
        let fixture = try ChecksFixture()
        defer { fixture.cleanup() }
        let provider = HeldCheckProvider()
        var configurations: [UUID] = []
        let controller = TranslationServiceChecksController(services: fixture.services) {
            configurations.append($0.id)
            return provider
        }
        controller.toggle(fixture.first)
        try await waitUntil { provider.requests.count == 1 }
        XCTAssertFalse(controller.canStart(fixture.second.id))
        controller.toggle(fixture.second)
        await settle()
        XCTAssertEqual(configurations, [fixture.first.id])
        XCTAssertEqual(provider.requests.map(\.text), [TranslationServiceEditor.testSample])
        XCTAssertEqual(provider.requests.first?.source, "en")
        XCTAssertEqual(provider.requests.first?.target, "zh-Hans")
        provider.completeAll()
        try await waitUntil { controller.canStart(fixture.second.id) }
        controller.toggle(fixture.second)
        try await waitUntil { provider.requests.count == 2 }
        provider.completeAll()
        try await waitUntil { controller.editor(for: fixture.second.id)?.testState == .succeeded }
        XCTAssertEqual(configurations, [fixture.first.id, fixture.second.id])
    }

    func testClosingChecksDoesNotCancelAnActualTranslationModelRequest() async throws {
        let fixture = try ChecksFixture()
        defer { fixture.cleanup() }
        let translation = HeldCheckProvider()
        let model = TranslationModel(services: fixture.services, remoteProvider: { _, _, _ in translation })
        model.source = "en"
        model.target = "zh-Hans"
        model.text = "A separate, constructed translation request."
        model.submit()
        try await waitUntil { translation.requests.count == 1 }
        let sample = HeldCheckProvider()
        let controller = TranslationServiceChecksController(services: fixture.services, testProvider: { _ in sample })
        let selected = fixture.services.selectedID
        let revision = fixture.services.revision
        let automaticRevision = fixture.services.automaticTranslationRevision
        controller.toggle(fixture.second)
        try await waitUntil { sample.requests.count == 1 }
        controller.cancelAll()
        XCTAssertNil(controller.editor(for: fixture.second.id))
        sample.completeAll()
        try await waitUntil { sample.cancellations.count == 1 }
        XCTAssertEqual(sample.cancellations, [true])
        XCTAssertEqual(model.phase, .translating)
        XCTAssertEqual(translation.cancellations, [])
        XCTAssertEqual(fixture.services.selectedID, selected)
        XCTAssertEqual(fixture.services.revision, revision)
        XCTAssertEqual(fixture.services.automaticTranslationRevision, automaticRevision)
        XCTAssertNil(fixture.services.sampleTestRecord(for: fixture.second.id))
        translation.completeAll()
        try await waitUntil { model.phase == .completed }
        XCTAssertEqual(model.result?.text, "构造译文")
        XCTAssertEqual(translation.cancellations, [false])
        XCTAssertEqual(fixture.services.usage.records.filter { $0.purpose == .translation }.count, 1)
        XCTAssertEqual(fixture.services.usage.records.filter { $0.purpose == .sampleTest }.first?.outcome, .cancelled)
    }

    func testKeyAndModelChangesHideCompletedFeedbackUntilRetested() async throws {
        for replaceKey in [true, false] {
            let fixture = try ChecksFixture()
            defer { fixture.cleanup() }
            let provider = HeldCheckProvider()
            let controller = TranslationServiceChecksController(services: fixture.services, testProvider: { _ in provider })
            controller.toggle(fixture.first)
            try await waitUntil { provider.requests.count == 1 }
            provider.completeAll(error: replaceKey ? nil : RemoteTranslationError.invalidKey)
            try await waitUntil { controller.editor(for: fixture.first.id)?.isTesting == false }
            let oldRecord = try XCTUnwrap(fixture.services.sampleTestRecord(for: fixture.first.id))
            var changed = fixture.first
            if !replaceKey { changed.model = "changed-fixture-model" }
            try fixture.services.save(changed, apiKey: replaceKey ? "new-fixture-key" : nil)
            XCTAssertNil(controller.editor(for: changed.id), "Old success and error feedback belong to the prior generation")
            XCTAssertNil(fixture.services.sampleTestOutcome(for: changed))
            XCTAssertEqual(fixture.services.sampleTestRecord(for: changed.id), oldRecord)
            controller.toggle(changed)
            try await waitUntil { provider.requests.count == 2 }
            provider.completeAll()
            try await waitUntil { controller.editor(for: changed.id)?.testState == .succeeded }
            XCTAssertEqual(fixture.services.sampleTestOutcome(for: changed), .succeeded)
        }
    }

    func testLateSampleCannotCertifyChangedKeyOrModel() async throws {
        for replaceKey in [true, false] {
            let fixture = try ChecksFixture()
            defer { fixture.cleanup() }
            let provider = HeldCheckProvider()
            let controller = TranslationServiceChecksController(services: fixture.services, testProvider: { _ in provider })
            controller.toggle(fixture.first)
            try await waitUntil { provider.requests.count == 1 }
            var changed = fixture.first
            if !replaceKey { changed.model = "changed-fixture-model" }
            try fixture.services.save(changed, apiKey: replaceKey ? "new-fixture-key" : nil)
            XCTAssertNil(controller.editor(for: changed.id))
            provider.completeAll()
            try await waitUntil { provider.cancellations.count == 1 }
            await settle()
            XCTAssertNil(controller.editor(for: changed.id))
            XCTAssertNil(fixture.services.sampleTestRecord(for: changed.id))
            controller.cancelAll()
        }
    }

    func testDeleteAndCloseDiscardLateFeedbackWithoutChangingSelectedService() async throws {
        let fixture = try ChecksFixture()
        defer { fixture.cleanup() }
        let provider = HeldCheckProvider()
        let controller = TranslationServiceChecksController(services: fixture.services, testProvider: { _ in provider })
        controller.toggle(fixture.second)
        try await waitUntil { provider.requests.count == 1 }
        try fixture.services.remove(fixture.second.id)
        let revision = fixture.services.revision
        let selected = fixture.services.selectedID
        controller.cancelAll()
        controller.cancelAll()
        provider.completeAll()
        try await waitUntil { provider.cancellations.count == 1 }
        await settle()
        XCTAssertNil(fixture.services.sampleTestRecord(for: fixture.second.id))
        XCTAssertTrue(fixture.services.usage.records(for: fixture.second.id, days: 30).isEmpty)
        XCTAssertEqual(fixture.services.revision, revision)
        XCTAssertEqual(fixture.services.selectedID, selected)
        XCTAssertTrue(controller.editors.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Service check did not reach its expected state")
        throw URLError(.timedOut)
    }
    private func settle() async { for _ in 0..<30 { await Task.yield() } }
}

@MainActor
private final class ChecksFixture {
    let suite = "TranslationServiceChecksTests." + UUID().uuidString
    let defaults: UserDefaults
    let credentials = ChecksCredentials()
    let services: TranslationServiceStore
    let first: TranslationServiceConfiguration
    let second: TranslationServiceConfiguration

    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        services = TranslationServiceStore(defaults: defaults, credentials: credentials)
        var first = TranslationServiceConfiguration(kind: .deepSeek)
        first.automaticallyTranslates = false
        var second = TranslationServiceConfiguration(kind: .deepSeek)
        second.name = "Second fixture service"
        second.automaticallyTranslates = false
        self.first = first
        self.second = second
        try services.save(first, apiKey: "first-fixture-key")
        try services.save(second, apiKey: "second-fixture-key")
        try services.select(first.id)
    }
    func cleanup() {
        services.usage.flush()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class ChecksCredentials: TranslationCredentialStore {
    private var values: [UUID: TranslationServiceCredential] = [:]
    func credential(for id: UUID) throws -> TranslationServiceCredential? { values[id] }
    func containsCredential(for id: UUID) throws -> Bool? { values[id] != nil }
    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws { values[id] = credential }
    func removeCredential(for id: UUID) throws { values[id] = nil }
}

@MainActor
private final class HeldCheckProvider: TranslationProvider {
    private(set) var requests: [TranslationRequest] = []
    private(set) var cancellations: [Bool] = []
    private var pending: [(TranslationRequest, CheckedContinuation<TranslationResult, any Error>)] = []

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        requests.append(request)
        defer { cancellations.append(Task.isCancelled) }
        // Deliberately finish after cancellation to exercise stale-result guards.
        return try await withCheckedThrowingContinuation { pending.append((request, $0)) }
    }
    func completeAll(error: (any Error)? = nil) {
        let work = pending
        pending = []
        for (request, continuation) in work {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: .init(text: "构造译文", source: request.source, target: request.target)) }
        }
    }
}
