import AppKit
import SwiftUI

// The visual binary excludes the real catalog implementation. These matching
// interfaces ensure no review action can contact an API, including new drafts.
nonisolated struct TranslationServiceModel: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
}
nonisolated protocol TranslationServiceModelLoading: Sendable {
    func models(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> [TranslationServiceModel]
}
nonisolated enum TranslationServiceModelCatalogError: String, Error, LocalizedError, Sendable {
    case unsupportedService, catalogUnavailable, invalidCatalog, catalogTooLarge
    var errorDescription: String? { L10n.string("translationService.catalogError.\(rawValue)") }
}
nonisolated struct TranslationServiceModelCatalog: TranslationServiceModelLoading {
    var scene = "normal"
    static func supports(_ kind: TranslationServiceKind) -> Bool {
        [.openAI, .deepSeek, .claude, .openAICompatible, .ollama].contains(kind)
    }
    func models(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> [TranslationServiceModel] {
        try await Task.sleep(for: scene == "catalog-loading" ? .seconds(60) : .milliseconds(500))
        try Task.checkCancellation()
        if scene == "catalog-error" { throw TranslationServiceModelCatalogError.catalogUnavailable }
        if scene == "catalog-empty" { return [] }
        return [configuration.model, "constructed-model-a", "constructed-model-b"].filter { !$0.isEmpty }
            .map { .init(id: $0, name: $0) }
    }
}

// The isolated binary excludes the production account loader as well. Even a
// manual Refresh click remains entirely in memory and never opens a URLSession.
nonisolated struct TranslationAccountUsageLoader: TranslationAccountUsageLoading {
    static func supports(_ configuration: TranslationServiceConfiguration) -> Bool {
        [.deepSeek, .deepL].contains(configuration.kind)
    }
    func usage(configuration: TranslationServiceConfiguration, apiKey: String?) async throws -> TranslationAccountUsageSnapshot {
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        guard Self.supports(configuration) else { throw TranslationAccountUsageError.unsupportedService }
        return VisualAccountUsageFixture.snapshot(kind: configuration.kind)
    }
}

nonisolated private enum VisualAccountUsageFixture {
    static func snapshot(kind: TranslationServiceKind) -> TranslationAccountUsageSnapshot {
        if kind == .deepL {
            return .init(fetchedAt: Date().addingTimeInterval(-120), usedCharacters: 128_460, characterLimit: 500_000)
        }
        return .init(fetchedAt: Date().addingTimeInterval(-120), balances: [
            .init(currency: "CNY", total: Decimal(string: "19.64")!, granted: 4, toppedUp: Decimal(string: "15.64")!)
        ])
    }
}

/// Hosts the shipping SettingsView and WindowSurface. Only service dependencies
/// and preferences are isolated; layout, controls and native material are real.
@MainActor
final class TranslationServiceVisualReview: NSObject {
    private static var retained: TranslationServiceVisualReview?
    private var window: NSWindow?
    private var backdrop: NSWindow?
    private var session: TranslationServiceDraftSession?
    private var frames: [String: CGRect] = [:]
    private var defaults: UserDefaults?
    private var fixture: VisualCodexAccount?
    private var quickModel: TranslationModel?
    private var reviewWindows: WindowCoordinator?

    static func start() {
        let review = TranslationServiceVisualReview()
        retained = review
        review.configureMenu()
        Task { await review.run() }
    }

    private func configureMenu() {
        let bar = NSMenu()
        let item = NSMenuItem()
        let menu = NSMenu()
        let quit = menu.addItem(withTitle: "退出视觉核查", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        item.submenu = menu
        bar.addItem(item)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let reopen = fileMenu.addItem(withTitle: "打开翻译窗口", action: #selector(reopenWorkspace), keyEquivalent: "n")
        reopen.target = self
        fileItem.submenu = fileMenu
        bar.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        bar.addItem(editItem)
        NSApp.mainMenu = bar
    }

    private func argument(_ key: String, fallback: String) -> String {
        guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { return fallback }
        return CommandLine.arguments[i + 1]
    }

    @objc private func reopenWorkspace() { reviewWindows?.showTranslationWindow() }

    /// Real window lifecycle with constructed pixels/results, for leaving the
    /// app, dismissing the panel and reopening it through the shipping entry.
    private func presentResumeFixture() async {
        let domain = "Lumax.TranslationServiceVisualReview.Resume.Ephemeral"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        self.defaults = defaults
        let preferences = AppPreferences(defaults: defaults)
        preferences.appearance = .light
        let services = TranslationServiceStore(defaults: defaults, credentials: VisualCredentialStore())
        let windows = WindowCoordinator(preferences: preferences, services: services)
        reviewWindows = windows
        windows.showMain()
        windows.inputModel.text = "An independent main-window draft."
        guard let document = try? await ScreenshotReviewFixture.document(dense: true) else { return }
        windows.quickModel.source = "en"
        windows.quickModel.submitCapturedDocument(document, serviceRevision: windows.quickModel.serviceRevision)
        if let request = windows.quickModel.request {
            await windows.quickModel.run(request, provider: ScreenshotReviewProvider())
        }
        windows.quickModel.cancel()
        windows.showQuick(source: nil)
    }

    private func run() async {
        let output = URL(fileURLWithPath: argument("--review-output", fallback: "/tmp/LumaxTranslationServiceReview"))
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--review-resume") {
            await presentResumeFixture()
            return
        }
        let languageSettingsReview = CommandLine.arguments.contains("--review-language-settings")
        let languageReview = CommandLine.arguments.contains("--review-language")
        let serviceListReview = CommandLine.arguments.contains("--review-service-list")
        let serviceEditorReview = CommandLine.arguments.contains("--review-service-editor")
        let serviceUsageChartsReview = CommandLine.arguments.contains("--review-service-usage-charts")
        let serviceUsageReview = serviceUsageChartsReview || CommandLine.arguments.contains("--review-service-usage")
        let interactions = CommandLine.arguments.contains("--review-interactions")
        let layouts = CommandLine.arguments.contains("--review-layouts")
        let brand = CommandLine.arguments.contains("--review-brand")
        let workspace = CommandLine.arguments.contains("--review-workspace")
        let inputFeedback = CommandLine.arguments.contains("--review-input-feedback")
        let toolbar = CommandLine.arguments.contains("--review-toolbar")
        let captureReview = CommandLine.arguments.contains("--review-capture")
        let toolbarMotion = CommandLine.arguments.contains("--review-toolbar-motion")
        let localSync = CommandLine.arguments.contains("--review-local-sync")
        let allProviders = CommandLine.arguments.contains("--review-all-providers")
        let states = CommandLine.arguments.contains("--review-states")
        let batch = serviceEditorReview || serviceUsageReview || languageSettingsReview || serviceListReview || languageReview || CommandLine.arguments.contains("--review-batch") || allProviders || states || interactions || layouts || brand || workspace || inputFeedback || localSync || toolbar || toolbarMotion || captureReview
        let scenes = serviceEditorReview ? ["edit", "edit-minimum"] : serviceUsageChartsReview ? ["usage-7", "usage-30-minimum", "usage-samples-minimum"] : serviceUsageReview ? ["usage-card", "usage-card-hover-minimum", "usage-7", "usage-30-minimum", "usage-day-minimum", "usage-samples-minimum", "usage-empty-minimum", "usage-account-empty", "usage-account-deepseek-minimum", "usage-account-deepl-minimum"] : languageSettingsReview ? ["general", "general-minimum"] : serviceListReview ? ["list-untested", "list-selected", "list-history", "list-long-name", "list-empty"] : languageReview ? ["general", "general-controls", "shortcuts", "privacy", "main-minimum", "quick-stacked-minimum", "main-failed", "test-error"] : captureReview ? ["main-capture-dense-text", "main-capture-dense-image", "main-capture-text", "main-capture-menu-image", "main-capture-menu-original", "main-capture-stacked-minimum", "main-capture-recognizing", "main-capture-failed", "quick-capture-minimum", "quick-capture-menu-image"] : toolbarMotion ? ["main-motion", "main-motion-reduced", "main-motion-off", "quick-motion", "quick-motion-reduced", "quick-motion-off"] : toolbar ? ["main", "main-failed", "main-stopped-empty", "main-requesting", "main-empty", "main-minimum", "main-stacked-minimum", "main-manual-minimum", "quick", "quick-failed", "quick-stacked-minimum", "quick-stacked-minimum-manual-long-name", "list", "list-history"] : localSync ? ["main-numeric", "main-same-language", "main-swapped", "main-swapped-stacked-minimum", "main-manual-minimum", "main-uncertain", "quick-numeric-minimum", "quick-same-language-stacked-minimum", "quick-swapped", "quick-swapped-stacked-minimum"] : inputFeedback ? ["main-numeric", "main-uncertain", "main-manual-minimum", "main-requesting", "main-partial", "quick-numeric-minimum", "quick-uncertain-stacked-minimum", "quick-stacked-minimum-manual-long-name"] : workspace ? ["main-edited", "main-stopped-empty", "main-partial", "main-manual", "main-minimum", "main-stacked-minimum", "quick-edited", "quick-stopped-empty", "quick-partial", "quick-minimum", "quick-stacked-minimum", "quick-stacked-minimum-manual-long-name", "quick-long"] : brand ? ["main", "main-stacked", "main-stacked-minimum"] : layouts ? ["general", "general-controls", "main", "main-stacked", "main-stacked-minimum", "quick", "quick-stacked", "quick-stacked-long", "quick-stacked-minimum"] : interactions ? ["general", "shortcuts", "privacy", "list", "add", "edit", "quick", "quick-long", "quick-minimum"] : allProviders ? TranslationServiceKind.allCases.map(\.rawValue) : states ?
            ["catalog-loading", "catalog-empty", "catalog-error", "test-running", "test-success", "test-error", "validation", "account-code", "account-committing", "account-ready"] :
            batch ? ["list", "add", "edit", "deepl", "codex"] : [argument("--review-scene", fallback: "edit")]
        let themes = batch && !states ? ["light", "dark", "glass"] : [argument("--review-theme", fallback: "light")]
        var all: [String: [String: [String: CGFloat]]] = [:]
        for theme in themes {
            for scene in scenes {
                await present(scene: scene, theme: theme)
                try? await Task.sleep(for: .milliseconds(900))
                guard let window else { continue }
                window.contentView?.layoutSubtreeIfNeeded()
                if scene == "general-controls", let content = window.contentView, let scroll = findScrollView(content) {
                    scroll.documentView?.scroll(NSPoint(x: 0, y: max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                if scene.hasPrefix("usage-") { await scrollUsageIntoView(scene: scene, window: window) }
                // Compare the idle state, with no field selected or focused.
                window.makeFirstResponder(nil)
                try? await Task.sleep(for: .milliseconds(200))
                let key = "\(scene)-\(theme)"
                all[key] = frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
                await capture(window, key: key, output: output)
                if toolbarMotion {
                    // Compare actual native pixels over time, not just the presence
                    // of a Canvas or a particle at one frozen instant.
                    try? await Task.sleep(for: .milliseconds(800))
                    await capture(window, key: key + "-later", output: output)
                }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("metrics.json"))
        }
        try? Data("Ready: native production views; constructed credentials, accounts and results only.\n".utf8)
            .write(to: output.appendingPathComponent("ready.txt"))
        if batch { NSApp.terminate(nil) }
    }

    private func capture(_ window: NSWindow, key: String, output: URL) async {
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let captureRect = [window.frame.minX, screenTop - window.frame.maxY, window.frame.width, window.frame.height]
        let job: [String: Any] = ["windowID": window.windowNumber, "region": captureRect, "scene": key,
            "output": output.appendingPathComponent("\(key).png").path]
        if let data = try? JSONSerialization.data(withJSONObject: job) {
            try? data.write(to: output.appendingPathComponent("capture-job.json"), options: .atomic)
        }
        if CommandLine.arguments.contains("--review-external-capture") {
            for _ in 0..<200 {
                let acknowledgement = try? String(contentsOf: output.appendingPathComponent("capture-done.txt"), encoding: .utf8)
                if acknowledgement == key { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func findScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap(findScrollView).first
    }

    private func scrollUsageIntoView(scene: String, window: NSWindow) async {
        guard scene.contains("day") else { return }
        guard let content = window.contentView, let scroll = findScrollView(content), let document = scroll.documentView,
              let viewport = frames["usage.scroll"] else { return }
        // Lazy request rows below the initial viewport need to be realized
        // before the expanded request can supply its geometry preference.
        if let table = frames["usage.requests"] {
            let proposed = scroll.contentView.bounds.minY + table.minY - viewport.minY
            document.scroll(NSPoint(x: 0, y: min(max(0, proposed), max(0, document.frame.height - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
            try? await Task.sleep(for: .milliseconds(250))
        }
        let targetKey = "usage.details"
        guard let target = frames[targetKey] else { return }
        let currentViewport = frames["usage.scroll"] ?? viewport
        let proposed = scroll.contentView.bounds.minY + target.minY - currentViewport.minY - 8
        let maximum = max(0, document.frame.height - scroll.contentSize.height)
        document.scroll(NSPoint(x: 0, y: min(max(0, proposed), maximum)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func seedUsage(_ store: TranslationUsageStore, configuration: TranslationServiceConfiguration) {
        let now = Date()
        for offset in (0..<29).reversed() {
            let count = [3, 5, 2, 7, 4, 6, 8][offset % 7]
            for index in (0..<count).reversed() {
                let completed = Calendar.current.date(byAdding: .day, value: -offset, to: now)!
                    .addingTimeInterval(-600 - Double(index * 83))
                let outcome: TranslationUsageOutcome = index == 0 && offset % 4 == 0 ? .failed
                    : index == 1 && offset % 6 == 0 ? .cancelled : .succeeded
                let ticket = store.begin(configurationID: configuration.id, model: configuration.model,
                    purpose: .translation, now: completed.addingTimeInterval(-0.7 - Double(index) * 0.2))
                let usage = outcome == .succeeded && index % 3 != 1
                    ? TranslationUsage(inputTokens: 180 + index * 32, outputTokens: 90 + offset * 4,
                                       totalTokens: 270 + index * 32 + offset * 4) : nil
                store.finish(ticket, outcome: outcome, usage: usage, now: completed)
            }
            if offset % 3 == 0 {
                let completed = Calendar.current.date(byAdding: .day, value: -offset, to: now)!.addingTimeInterval(-300)
                let ticket = store.begin(configurationID: configuration.id, model: configuration.model,
                                         purpose: .sampleTest, now: completed.addingTimeInterval(-0.9))
                store.finish(ticket, outcome: .succeeded, usage: TranslationUsage(inputTokens: 24, outputTokens: 11, totalTokens: 35), now: completed)
            }
        }
        store.flush()
    }

    private func present(scene: String, theme: String) async {
        quickModel?.cancel()
        session?.close()
        fixture?.cancelAll()
        window?.close()
        frames = [:]
        let domain = "Lumax.TranslationServiceVisualReview.Ephemeral"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        self.defaults = defaults
        let preferences = AppPreferences(defaults: defaults)
        let languageArgument = argument("--review-interface-language", fallback: "system")
        let interfaceLanguage: AppInterfaceLanguage = languageArgument == "en" ? .english : languageArgument == "zh-Hans" ? .simplifiedChinese : .system
        preferences.interfaceLanguage = interfaceLanguage
        L10n.apply(interfaceLanguage)
        preferences.translationLayout = scene.contains("stacked") ? .stacked : .sideBySide
        preferences.appearance = theme.hasPrefix("dark") ? .dark : .light
        preferences.material = theme.contains("glass") ? .glass : .light
        let fixture = VisualCodexAccount(scene == "account-code" ? .deviceCode : scene == "account-committing" ? .committing : scene == "account-ready" ? .signedIn : .signedOut)
        self.fixture = fixture
        let services = TranslationServiceStore(defaults: defaults, credentials: VisualCredentialStore(),
            codex: CodexAccountController(sessionFactory: { request in fixture.session(request) }))
        var deepSeek = TranslationServiceConfiguration(kind: .deepSeek)
        deepSeek.name = scene.contains("long-name") ? "My translation service with a long name" : "DeepSeek"
        var openAI = TranslationServiceConfiguration(kind: .openAI)
        openAI.name = "英文阅读"
        let singleExternalService = ["list-untested", "list-selected"].contains(scene)
        if singleExternalService { deepSeek.model = "deepseek-flash" }
        if scene != "list-empty" {
            try? services.save(deepSeek, apiKey: "constructed-visual-key-never-valid")
            if !singleExternalService { try? services.save(openAI, apiKey: "constructed-visual-key-never-valid") }
        }
        if scene == "list-selected" { try? services.select(deepSeek.id) }
        var usageState: TranslationServiceReviewUsageState?
        if scene.hasPrefix("usage-") {
            let reviewed: TranslationServiceConfiguration
            if scene.contains("deepl") {
                reviewed = TranslationServiceConfiguration(kind: .deepL)
                try? services.save(reviewed, apiKey: "constructed-visual-key-never-valid")
            } else { reviewed = deepSeek }
            try? services.select(reviewed.id)
            if !scene.contains("empty") { seedUsage(services.usage, configuration: reviewed) }
            usageState = .init(configurationID: reviewed.id, accountTab: scene.contains("account"),
                days: scene.contains("30") ? 30 : 7,
                selectedDay: scene.contains("day") ? Calendar.current.startOfDay(for: Date().addingTimeInterval(-600)) : nil,
                sampleTests: scene.contains("samples"),
                snapshot: scene.contains("account") && !scene.contains("empty") ? VisualAccountUsageFixture.snapshot(kind: reviewed.kind) : nil)
            usageState?.opensUsagePage = !scene.contains("account") && scene != "usage-card" && scene != "usage-card-hover-minimum"
            usageState?.hoveredID = scene == "usage-card-hover-minimum" ? reviewed.id : nil
            if scene == "usage-card" || scene == "usage-card-hover-minimum" {
                usageState?.snapshot = VisualAccountUsageFixture.snapshot(kind: reviewed.kind)
                services.recordSampleTest(.succeeded, for: reviewed, revision: services.configurationRevision(for: reviewed.id), completedAt: Date())
            }
        }
        if scene.hasPrefix("list"), scene != "list-empty", !singleExternalService {
            services.recordSampleTest(.succeeded, for: deepSeek, revision: services.configurationRevision(for: deepSeek.id), completedAt: Date().addingTimeInterval(-1800))
            if scene == "list-history" {
                services.recordSampleTest(.failed, for: openAI, revision: services.configurationRevision(for: openAI.id), completedAt: Date().addingTimeInterval(-86400))
                var changed = TranslationServiceConfiguration(kind: .claude)
                try? services.save(changed, apiKey: "constructed-visual-key-never-valid")
                services.recordSampleTest(.succeeded, for: changed, revision: services.configurationRevision(for: changed.id), completedAt: Date().addingTimeInterval(-86400 * 3))
                changed.model = "constructed-new-model"
                try? services.save(changed, apiKey: nil)
            }
        }
        let kind = TranslationServiceKind(rawValue: scene) ?? (scene == "deepl" ? .deepL : scene == "codex" || scene.hasPrefix("account-") ? .codex : .openAI)
        let pageTabs = ["general": 0, "general-minimum": 0, "general-controls": 0, "shortcuts": 1, "privacy": 2]
        let isQuick = scene.hasPrefix("quick")
        let isMain = scene.hasPrefix("main")
        let session: TranslationServiceDraftSession? = scene.hasPrefix("list") || scene.hasPrefix("usage-") || pageTabs[scene] != nil || isQuick || isMain ? nil : .init(services: services,
            configuration: scene.hasPrefix("edit") ? openAI : nil, modelLoader: TranslationServiceModelCatalog(scene: scene))
        if !scene.hasPrefix("edit") { session?.selectKind(kind) }
        self.session = session
        let shortcuts = ShortcutSettings(preferences: preferences, manager: ShortcutManager(), onAction: { _ in }, onBindingsChanged: {})
        let navigation = TranslationServiceNavigationCoordinator()
        let content = SettingsView(preferences: preferences, shortcuts: shortcuts, permissions: PermissionStatus(),
            catalog: LanguageCatalog(), defaultTargetChanged: {}, appearanceChanged: {},
            interfaceLanguageChanged: { L10n.apply(preferences.interfaceLanguage) }, services: services,
            serviceNavigation: navigation, serviceSession: session, tab: pageTabs[scene] ?? 3)
        let size: NSSize = isQuick || isMain
            ? (scene.contains("minimum") ? preferences.translationLayout.minimumSize(for: isMain ? .main : .quick)
                : preferences.translationLayout.defaultSize(for: isMain ? .main : .quick))
            : (scene == "edit-minimum" || scene == "general-minimum" || scene.hasPrefix("usage-") && scene.contains("minimum") ? NSSize(width: 620, height: 540) : NSSize(width: 700, height: 610))
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect,
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        LumaxWindowChrome.configure(window)
        window.setFrame(rect, display: false)
        window.appearance = NSAppearance(named: theme.hasPrefix("dark") ? .darkAqua : .aqua)
        window.title = "翻译服务 · 原生视觉核查（构造数据）"
        // Keep the owned synthetic capture surface above unrelated desktop
        // windows. This affects only the review fixture, never shipping windows.
        window.level = .floating
        window.identifier = NSUserInterfaceItemIdentifier("lumax.service.visual-review")
        window.isReleasedWhenClosed = false
        if isQuick || isMain {
            let reviewSource = "Good design makes complex things feel effortless.\nKeep useful tools close to the text.\nSmall adjustments can bring noticeable improvements."
            let reviewTarget = "好的设计，让复杂的事情变得轻松。\n让常用工具贴近内容。\n小小的调整，也能带来明显的改善。"
            if scene.contains("partial") || scene.contains("long-name") || scene.contains("interactive") { try? services.select(deepSeek.id) }
            let model = TranslationModel(automaticallyTranslates: true, services: services, remoteProvider: { _, _, partial in
                WorkspaceReviewProvider(source: reviewSource, target: reviewTarget, partial: partial, fragment: scene.contains("partial"))
            })
            quickModel = model
            let unresolvedInput = scene.contains("numeric") || scene.contains("uncertain") || scene.contains("same-language")
            model.source = unresolvedInput ? "auto" : "en"
            model.target = "zh-Hans"
            model.sourceName = "Google Chrome"
            let source = scene.contains("numeric") ? "123\n456.78" : scene.contains("same-language") ? "123\n哈哈" : scene.contains("uncertain") ? "今日仕事" : reviewSource
            let translated = reviewTarget
            model.text = scene.contains("long") ? Array(repeating: source, count: 15).joined(separator: "\n\n") : source
            model.submit()
            if !scene.contains("stopped-empty"), !scene.contains("partial"), !scene.contains("requesting"), let request = model.request {
                await model.run(request, provider: FixtureProvider(output: scene.contains("long") ? Array(repeating: translated, count: 15).joined(separator: "\n\n") : translated))
            }
            if scene.contains("swapped") { model.swapLanguages() }
            if scene.contains("edited") || scene.contains("manual") {
                if scene.contains("manual") { model.setAutomaticTranslation(false) }
                model.editingChanged(reviewTarget, isComposing: false, side: .target)
                // Change one character to represent a genuine edit after completion.
                model.editingChanged(reviewTarget + "\n", isComposing: false, side: .target)
                if !scene.contains("manual") {
                    model.submit()
                    if let request = model.request {
                        await model.run(request, provider: WorkspaceReviewProvider(source: reviewSource, target: reviewTarget))
                    }
                }
            }
            if scene.contains("partial") {
                for _ in 0..<100 { if !model.partialText.isEmpty { break }; await Task.yield() }
                model.cancel()
            } else if scene.contains("stopped-empty") { model.cancel() }
            if scene.contains("failed") {
                model.submit()
                if let request = model.request { await model.run(request, provider: ServiceReviewTranslation(scene: "test-error")) }
            }
            if scene == "main-empty" { model.clear() }
            if scene.contains("motion-off") { model.setAutomaticTranslation(false) }
            if scene.contains("capture") {
                let document = try? await ScreenshotReviewFixture.document(menu: scene.contains("menu"), dense: scene.contains("dense"))
                if let document {
                    model.submitCapturedDocument(document, serviceRevision: model.serviceRevision)
                    if let request = model.request { await model.run(request, provider: ScreenshotReviewProvider()) }
                    if scene.contains("recognizing") { model.beginRecognition(image: document.image) }
                    if scene.contains("failed") { model.fail(L10n.string("Text recognition couldn’t finish. Try selecting the area again.")) }
                }
            }
            if isMain {
                let main = InputTranslationView(model: model, catalog: LanguageCatalog(), translateSelection: {}, translateScreenshot: {}, openSettings: {})
                if scene.contains("motion") {
                    window.contentView = WindowSurface(preferences: preferences, content: ServiceReviewSurface(content: main.environment(\.translationReviewReduceMotion, scene.contains("reduced")), report: { [weak self] in self?.frames = $0 }))
                } else {
                    window.contentView = WindowSurface(preferences: preferences, content: ServiceReviewSurface(content: main.environment(\.translationReviewCaptureMode, scene.contains("original") ? "original" : scene.contains("image") ? "image" : "text"), report: { [weak self] in self?.frames = $0 }))
                }
            } else {
                let quick = QuickTranslationView(model: model, close: {}, openInput: {}, canOpenInput: { true }, permission: nil,
                    requestPermission: {}, cancel: { model.cancel() }, retry: {}, catalog: LanguageCatalog())
                if scene.contains("motion") {
                    window.contentView = WindowSurface(preferences: preferences, content: ServiceReviewSurface(content: quick.environment(\.translationReviewReduceMotion, scene.contains("reduced")), report: { [weak self] in self?.frames = $0 }))
                } else {
                    window.contentView = WindowSurface(preferences: preferences, content: ServiceReviewSurface(content: quick.environment(\.translationReviewCaptureMode, scene.contains("original") ? "original" : scene.contains("image") ? "image" : "text"), report: { [weak self] in self?.frames = $0 }))
                }
            }
        } else {
            window.contentView = WindowSurface(preferences: preferences, content: ServiceReviewSurface(
                content: content.environment(\.translationServiceReviewUsageState, usageState), report: { [weak self] in self?.frames = $0 }))
        }
        if backdrop == nil, let screen = NSScreen.main {
            let background = NSWindow(contentRect: screen.visibleFrame, styleMask: [.borderless], backing: .buffered, defer: false)
            background.isReleasedWhenClosed = false
            background.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            background.contentView = NSHostingView(rootView: ReviewWallpaper())
            background.orderFrontRegardless()
            backdrop = background
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        if let editor = session?.editor {
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                if scene.hasPrefix("catalog-") || scene.hasPrefix("test-") {
                    editor.replacementKey = "constructed-visual-key-never-valid"
                }
                if scene.hasPrefix("catalog-") { editor.fetchModels() }
                if scene.hasPrefix("test-") { editor.configuration.model = "constructed-model-a"; editor.test(using: ServiceReviewTranslation(scene: scene)) }
                if scene == "validation" {
                    editor.configuration.name = ""
                    _ = editor.save()
                }
                if scene == "account-code" || scene == "account-committing" { editor.signInCodex() }
                if scene == "account-ready" { editor.refreshCodexModels() }
            }
        }
    }
}

@MainActor
private struct WorkspaceReviewProvider: TranslationProvider {
    let source: String
    let target: String
    var partial: (@MainActor @Sendable (String) -> Void)? = nil
    var fragment = false
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        if fragment {
            partial?("好的设计，让复杂的事情变得轻松。")
            try await Task.sleep(for: .seconds(60))
        }
        try await Task.sleep(for: .milliseconds(400))
        try Task.checkCancellation()
        return TranslationResult(text: request.target == "en" ? source : target, source: request.source, target: request.target)
    }
}

private struct ReviewWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.76, green: 0.92, blue: 0.96), Color(red: 0.56, green: 0.7, blue: 0.89),
            Color(red: 0.91, green: 0.78, blue: 0.88)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct ServiceReviewSurface<Content: View>: View {
    let content: Content
    let report: @MainActor ([String: CGRect]) -> Void
    var body: some View {
        content.coordinateSpace(name: "service-design.window")
            .onPreferenceChange(TranslationServiceLayoutFrames.self) { frames in report(frames) }
    }
}

@MainActor
private struct ServiceReviewTranslation: TranslationProvider {
    let scene: String
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try await Task.sleep(for: scene == "test-running" ? .seconds(60) : .milliseconds(200))
        if scene == "test-error" { throw RemoteTranslationError.invalidKey }
        return .init(text: "清晰的句子很容易理解。", source: "en", target: "zh-Hans")
    }
}
