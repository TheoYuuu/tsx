import AppKit
import SwiftUI
import Translation

// Isolated visual fixture: the production views and window controller are compiled
// unchanged. External translation execution is replaced in this QA binary.
struct AppleTranslationHost: View {
    let model: TranslationModel
    var body: some View { EmptyView() }
}

/// The QA build excludes the production network provider. Even explicit Test or
/// Translate actions use this visibly synthetic output and cannot open a session.
@MainActor
struct RemoteTranslationProvider: TranslationProvider {
    let onPartial: @MainActor @Sendable (String) -> Void

    init(configuration: TranslationServiceConfiguration, apiKey: String?,
         onPartial: @escaping @MainActor @Sendable (String) -> Void = { _ in },
         session: URLSession? = nil) {
        self.onPartial = onPartial
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try Task.checkCancellation()
        let output = "构造译文，仅用于界面核查。未调用任何翻译服务。"
        onPartial(output)
        try await Task.sleep(for: .milliseconds(350))
        try Task.checkCancellation()
        return TranslationResult(text: output, source: request.source, target: request.target)
    }
}

typealias DedicatedTranslationProvider = RemoteTranslationProvider
typealias ClaudeTranslationProvider = RemoteTranslationProvider
typealias QwenMTTranslationProvider = RemoteTranslationProvider
typealias GoogleCloudTranslationProvider = RemoteTranslationProvider
typealias TencentTranslationProvider = RemoteTranslationProvider

/// Visual fixture credentials never touch the user's login Keychain.
@MainActor
final class VisualCredentialStore: TranslationCredentialStore {
    private var values: [UUID: TranslationServiceCredential] = [:]

    func credential(for id: UUID) throws -> TranslationServiceCredential? { values[id] }
    func containsCredential(for id: UUID) throws -> Bool? { values[id] != nil }
    func setCredential(_ credential: TranslationServiceCredential, for id: UUID) throws { values[id] = credential }
    func removeCredential(for id: UUID) throws { values[id] = nil }
}

/// Every Codex operation in this application is an in-memory fixture. The
/// production account controller and settings view run unchanged; no helper is
/// created and no system account storage is read.
@MainActor
final class VisualCodexAccount {
    enum Scene { case signedOut, deviceCode, committing, signedIn, failure }
    let scene: Scene
    let generation = "4a0b47f8-b46c-46d6-89e7-742c563f7cc7"
    private var pending: [VisualCodexSession] = []

    init(_ scene: Scene = .signedOut) { self.scene = scene }

    func session(_ request: CodexRuntimeSession.Request) -> CodexAccountController.SessionHandle {
        let session = VisualCodexSession(request: request, scene: scene, generation: generation)
        pending.append(session)
        return .init(run: { callback in await session.run(callback) }, cancel: { session.cancel() })
    }

    func cancelAll() { pending.forEach { $0.cancel() }; pending.removeAll() }
}

@MainActor
private final class VisualCodexSession {
    let request: CodexRuntimeSession.Request
    let scene: VisualCodexAccount.Scene
    let generation: String
    private var cancelled = false
    private var continuation: CheckedContinuation<CodexRuntimeSession.Result, Never>?

    init(request: CodexRuntimeSession.Request, scene: VisualCodexAccount.Scene, generation: String) {
        self.request = request; self.scene = scene; self.generation = generation
    }

    func run(_ callback: (CodexRuntimeSession.Event) -> Void) async -> CodexRuntimeSession.Result {
        if cancelled { return result("cancelled") }
        if scene == .failure { return result("managed_policy_denied") }
        switch request.operation {
        case .status: return result(scene == .signedIn ? "signed_in" : "signed_out")
        case .login:
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                callback(.init(event: .ready, protocolVersion: 1, requestID: request.requestID,
                    userCode: "DEMO-CODE", verificationURL: "https://auth.openai.com/codex/device", result: nil))
                if scene == .committing {
                    callback(.init(event: .committing, protocolVersion: 1, requestID: request.requestID,
                        userCode: nil, verificationURL: nil, result: nil))
                }
            }
        case .logout: return result("signed_out", remote: "unconfirmed")
        case .models:
            return result("ok", models: [
                .init(id: "fixture-model-a", name: "构造模型 · 日常翻译", reasoningEfforts: ["low"], defaultReasoningEffort: "low"),
                .init(id: "fixture-model-b", name: "Constructed model with a longer display name", reasoningEfforts: [], defaultReasoningEffort: nil)
            ])
        case .translate: return result("ok", text: "构造译文，仅用于 Codex 界面核查。未登录或调用 OpenAI。")
        }
    }

    func cancel() {
        cancelled = true
        let continuation = continuation
        self.continuation = nil
        // Demonstrate that a committing operation may retain a completed
        // account even when its editor is dismissed.
        continuation?.resume(returning: result(scene == .committing ? "signed_in" : "cancelled"))
    }

    private func result(_ status: String, models: [CodexRuntimeSession.Model]? = nil,
                        text: String? = nil, remote: String? = nil) -> CodexRuntimeSession.Result {
        let outcome = CodexRuntimeSession.Outcome(status: status, text: text, models: models,
            accountPlan: status == "signed_in" ? "plus" : nil,
            generation: status == "signed_in" ? generation : nil, remoteRevocation: remote)
        let terminal = CodexRuntimeSession.Event(event: .terminal, protocolVersion: 1,
            requestID: request.requestID, userCode: nil, verificationURL: nil, result: outcome)
        return .init(terminal: terminal, failure: nil, helperReaped: true)
    }
}

@MainActor
struct FixtureProvider: TranslationProvider {
    let output: String
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        TranslationResult(text: output, source: "en", target: "zh-Hans")
    }
}

@main @MainActor
final class VisualCatalog: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = VisualCatalog()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
    let defaults = UserDefaults(suiteName: "Lumax.VisualCatalog.Ephemeral")!
    lazy var preferences = AppPreferences(defaults: defaults)
    private let credentials = VisualCredentialStore()
    private let defaultCodexFixture = VisualCodexAccount()
    lazy var services = TranslationServiceStore(defaults: defaults, credentials: credentials,
        codex: CodexAccountController(sessionFactory: { [defaultCodexFixture] request in defaultCodexFixture.session(request) }))
    private let codexDefaults = UserDefaults(suiteName: "Lumax.VisualCatalog.Codex.Ephemeral")!
    private var codexFixture: VisualCodexAccount?
    private var codexEditor: TranslationServiceEditor?
    private var codexWindow: NSWindow?
    lazy var windows: WindowCoordinator = {
        let windows = WindowCoordinator(preferences: preferences, services: services)
        // Layout only: construction never starts Sparkle or changes preferences.
        windows.updates = AppUpdateController(bundleIdentifier: "com.lumax.tsx", isTesting: false)
        return windows
    }()
    lazy var shortcuts = ShortcutSettings(preferences: preferences, manager: ShortcutManager(), onAction: { _ in }, onBindingsChanged: {})
    var backdrop: NSWindow?
    var scene = "主窗口"
    var comparisonWindow: NSWindow?
    var comparisonContent: NSView?
    var comparisonFrame: NSRect?
    let original = "Good design gives you room to think. It brings clarity to the things that matter, and quietly gets out of the way.\n\nSmall details make every day feel a little easier."
    let translated = "好的设计，为思考留出空间。它让重要的事物变得清晰，然后悄然退到一旁。\n\n细微之处，让每一天都更轻松一些。"
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--translation-services-review") {
            TranslationServiceVisualReview.start()
            return
        }
        defaults.removePersistentDomain(forName: "Lumax.VisualCatalog.Ephemeral")
        preferences.appearance = .light
        windows.applyAppearance()
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = appMenu.addItem(withTitle: "退出视觉核查", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let item = NSMenuItem(title: "场景", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "场景")
        for name in ["主窗口", "空白输入", "取词结果", "长文本", "设置", "翻译服务 · 配置列表", "翻译服务 · 空白列表", "Codex · 未登录", "Codex · 设备码", "Codex · 正在完成", "Codex · 账号模型", "Codex · 固定错误", "关于", "辅助功能说明", "屏幕录制说明", "正在识别", "语言准备", "复制内容变化", "翻译取消", "同语言", "未识别文字", "截图提示", "最小主窗口", "最小浮窗", "纯浅色", "通透玻璃", "深色外观", "浅色外观", "窗口内布局对照", "桌面构造背景", "设计构造背景", "彩色条纹背景", "浅色桌面背景", "深色桌面背景", "主窗与设置 · 设置激活", "主窗与设置 · 翻译激活", "屏幕底部下拉核查"] {
            let row = menu.addItem(withTitle: name, action: #selector(selectScene(_:)), keyEquivalent: "")
            row.target = self
        }
        item.submenu = menu
        bar.addItem(item)
        NSApp.mainMenu = bar
        if let screen = NSScreen.main {
            let frame = NSRect(x: screen.visibleFrame.midX - 600, y: screen.visibleFrame.midY - 370, width: 1200, height: 740)
            let background = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            background.isReleasedWhenClosed = false
            background.level = .normal
            background.contentView = NSHostingView(rootView: Wallpaper())
            background.orderFrontRegardless()
            backdrop = background
        }
        windows.onSettings = { [weak self] in guard let self else { return }; windows.showSettings(shortcuts: shortcuts) }
        Task { await show("主窗口") }
    }
    @objc func selectScene(_ sender: NSMenuItem) {
        switch sender.title {
        case "窗口内布局对照": presentMaterialComparison()
        case "桌面构造背景": presentDesktopComparison()
        case "设计构造背景": backdrop?.contentView = NSHostingView(rootView: Wallpaper())
        case "彩色条纹背景", "浅色桌面背景", "深色桌面背景":
            backdrop?.contentView = ContrastBackdrop(kind: sender.title)
        case "纯浅色": preferences.material = .light
        case "通透玻璃": preferences.material = .glass
        case "深色外观": preferences.appearance = .dark; windows.applyAppearance()
        case "浅色外观": preferences.appearance = .light; windows.applyAppearance()
        case "屏幕底部下拉核查":
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue == "lumax.settings" }),
                  let screen = window.screen else { return }
            // Put the language row just above the bottom edge, and its trailing
            // button near the right edge. This only moves the isolated QA window.
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - window.frame.width,
                                          y: screen.visibleFrame.minY - window.frame.height + 330))
            window.makeKeyAndOrderFront(nil)
        case "主窗与设置 · 设置激活", "主窗与设置 · 翻译激活":
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                await presentWindowPair(settingsActive: sender.title == "主窗与设置 · 设置激活")
            }
        default: Task { try? await Task.sleep(for: .milliseconds(150)); await show(sender.title) }
        }
    }
    func completed(_ model: TranslationModel, text: String, output: String) async {
        let donor = TranslationModel(services: services)
        donor.source = "auto"
        donor.text = text
        donor.submit()
        await donor.run(donor.request!, provider: FixtureProvider(output: output))
        model.acceptHandoff(donor.makeHandoff())
        model.sourceName = "Google Chrome"
    }
    func show(_ name: String) async {
        restoreComparison()
        codexEditor?.close()
        codexEditor = nil
        codexFixture?.cancelAll()
        codexFixture = nil
        codexWindow?.close()
        codexWindow = nil
        backdrop?.level = .normal
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("lumax.") == true {
            window.level = window is NSPanel ? .floating : .normal
        }
        scene = name
        backdrop?.orderFrontRegardless()
        for window in NSApp.windows where window !== backdrop { window.orderOut(nil) }
        NotificationCenter.default.post(name: .lumaxTranslationSettingsClosed, object: nil)
        windows.closeQuick(restoreFocus: false)
        try? services.select(nil)
        windows.inputModel.clear()
        windows.prepareQuickTranslation()
        switch name {
        case "主窗口", "最小主窗口":
            await completed(windows.inputModel, text: original, output: translated)
            windows.showMain()
            NSApp.windows.first { $0.identifier?.rawValue == "lumax.main" }?.setFrame(NSRect(x: 220, y: 170, width: name == "最小主窗口" ? 660 : 980, height: name == "最小主窗口" ? 440 : 598), display: true)
        case "空白输入": windows.showMain()
        case "取词结果", "长文本", "最小浮窗":
            await completed(windows.quickModel, text: name == "长文本" ? String(repeating: original + "\n", count: 10) : original.components(separatedBy: "\n\n")[0], output: name == "长文本" ? String(repeating: translated + "\n", count: 10) : translated.components(separatedBy: "\n\n")[0])
            windows.showQuick(source: nil)
            if name == "最小浮窗" { NSApp.windows.first { $0.identifier?.rawValue == "lumax.quick" }?.setFrame(NSRect(x: 520, y: 250, width: 600, height: 340), display: true) }
        case "设置": windows.showSettings(shortcuts: shortcuts)
        case "Codex · 未登录", "Codex · 设备码", "Codex · 正在完成", "Codex · 账号模型", "Codex · 固定错误":
            await showCodex(name)
        case "翻译服务 · 配置列表", "翻译服务 · 空白列表":
            do {
                try prepareTranslationServices(includeExamples: name == "翻译服务 · 配置列表")
                windows.showSettings(shortcuts: shortcuts)
            } catch {
                let alert = NSAlert()
                alert.messageText = "无法准备翻译服务构造场景"
                alert.informativeText = "请重新启动视觉核查应用。未访问真实用户的服务配置或密钥。"
                alert.runModal()
            }
        case "关于": windows.showAbout()
        case "辅助功能说明", "屏幕录制说明": windows.showQuick(source: nil, permission: name == "辅助功能说明" ? .accessibility : .screenCapture)
        case "正在识别": windows.quickModel.beginRecognition(); windows.showQuick(source: nil)
        case "语言准备":
            windows.quickModel.text = original
            windows.quickModel.submit()
            windows.quickModel.markPreparing(windows.quickModel.request!)
            windows.showQuick(source: nil)
        case "复制内容变化":
            windows.quickModel.fail(L10n.string("The selection or clipboard changed. Select your text and try again."))
            windows.showQuick(source: nil)
        case "翻译取消": windows.quickModel.beginRecognition(); windows.quickModel.cancel(); windows.showQuick(source: nil)
        case "同语言": windows.quickModel.text = translated; windows.quickModel.source = "zh-Hans"; windows.quickModel.submit(); windows.showQuick(source: nil)
        case "未识别文字":
            windows.quickModel.text = original; windows.quickModel.submit()
            await windows.quickModel.run(windows.quickModel.request!, provider: EmptyProvider())
            windows.showQuick(source: nil)
        case "截图提示":
            guard let backdrop else { return }
            let panel = VisualCaptureWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.title = "截图覆盖层核查"
            panel.identifier = NSUserInterfaceItemIdentifier("qa.capture")
            panel.isReleasedWhenClosed = false; panel.backgroundColor = .clear; panel.isOpaque = false
            let content = RegionSelectionOverlayView(frame: NSRect(origin: .zero, size: backdrop.frame.size), screenFrame: backdrop.frame, preferences: preferences)
            content.selection = CGRect(x: backdrop.frame.minX + 280, y: backdrop.frame.minY + 230, width: 618, height: 184)
            panel.contentView = content; panel.makeKeyAndOrderFront(nil)
        default: break
        }
        if let backdrop, let front = NSApp.windows.first(where: {
            $0.isVisible && ($0.identifier?.rawValue.hasPrefix("lumax.") == true || $0.identifier?.rawValue == "qa.capture")
        }) {
            let origin = NSPoint(x: backdrop.frame.midX - front.frame.width / 2,
                                 y: backdrop.frame.midY - front.frame.height / 2)
            front.setFrameOrigin(origin)
            backdrop.orderFrontRegardless()
            front.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// A dedicated QA window hosts the exact production editor and material at
    /// the settings minimum width. The normal Settings scene still exercises
    /// real tab navigation and the Add service entry point.
    private func showCodex(_ name: String) async {
        let scene: VisualCodexAccount.Scene = switch name {
        case "Codex · 设备码": .deviceCode
        case "Codex · 正在完成": .committing
        case "Codex · 账号模型": .signedIn
        case "Codex · 固定错误": .failure
        default: .signedOut
        }
        codexDefaults.removePersistentDomain(forName: "Lumax.VisualCatalog.Codex.Ephemeral")
        let fixture = VisualCodexAccount(scene)
        codexFixture = fixture
        let controller = CodexAccountController(sessionFactory: { fixture.session($0) })
        let store = TranslationServiceStore(defaults: codexDefaults, credentials: VisualCredentialStore(), codex: controller)
        await controller.refreshStatus(owner: UUID())
        if scene == .signedIn { await controller.loadModels(owner: UUID()) }
        let editor = TranslationServiceEditor(configuration: .init(kind: .codex), services: store)
        codexEditor = editor
        if scene == .deviceCode || scene == .committing { editor.signInCodex() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        LumaxWindowChrome.configure(window)
        window.minSize = NSSize(width: 620, height: 540)
        window.title = "Codex 构造界面核查"
        window.identifier = NSUserInterfaceItemIdentifier("lumax.codex-visual")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = WindowSurface(preferences: preferences, content:
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    WindowTrafficLights().frame(width: 58, height: 14)
                    Text("Settings").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("构造场景 · 未连接 OpenAI").font(.system(size: 10))
                }
                .padding(.horizontal, 22).frame(height: 64)
                ScrollView {
                    CodexAccountSettingsView(editor: editor)
                        .padding(.horizontal, 36).padding(.top, 10).padding(.bottom, 24)
                }
            }
        )
        codexWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === codexWindow else { return }
        codexEditor?.close()
        codexFixture?.cancelAll()
    }

    /// These deliberately invalid external domains identify examples. Transport
    /// is also replaced above, so entering another address in this fixture still
    /// cannot send text or credentials outside the process.
    private func prepareTranslationServices(includeExamples: Bool) throws {
        for configuration in services.configurations { try services.remove(configuration.id) }
        guard includeExamples else { return }
        let examples: [(TranslationServiceKind, String, String, String)] = [
            (.openAI, "OpenAI · 构造示例", "https://openai.example.invalid/v1", "gpt-4.1-mini"),
            (.deepSeek, "DeepSeek · 构造示例", "https://deepseek.example.invalid", "deepseek-flash"),
            (.openAICompatible, "自定义翻译服务 · 长名称与多模型配置示例", "https://compatible.example.invalid/team/v1", "example-translation-model"),
            (.ollama, "Ollama · 本地构造示例", "http://localhost:11434/v1", "example-local-model"),
            (.deepL, "DeepL · 构造示例", "https://deepl.example.invalid", ""),
            (.azureTranslator, "Azure · 构造示例", "https://azure.example.invalid", ""),
            (.claude, "Claude · 构造示例", "https://claude.example.invalid/v1", "claude-haiku-4-5-20251001"),
            (.qwenMT, "Qwen-MT · 构造示例", "https://qwen.example.invalid/compatible-mode/v1", "qwen-mt-flash"),
            (.googleCloud, "Google Cloud · 构造示例", "https://google.example.invalid/language/translate/v2", ""),
            (.tencentTranslation, "腾讯翻译 · 构造示例", "https://tencent.example.invalid", "hy-mt2-plus")
        ]
        for (kind, name, endpoint, model) in examples {
            let configuration = TranslationServiceConfiguration(name: name, kind: kind, endpoint: endpoint, model: model,
                additionalInstructions: kind == .openAICompatible ? "保留原文的段落、列表和代码块。此内容只用于设置界面布局核查。" : "")
            try services.save(configuration, apiKey: kind == .ollama ? nil : "visual-fixture-not-a-real-key")
        }
    }
    // Geometry-only comparison: behind-window blur does not sample this image.
    // Optical and focus checks require the independent desktop backdrop below.
    func presentMaterialComparison() {
        guard comparisonWindow == nil,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("lumax.") == true }),
              let surface = window.contentView else { return }
        comparisonWindow = window
        comparisonContent = surface
        comparisonFrame = window.frame
        let size = surface.bounds.size
        let comparisonSize = NSSize(width: size.width + 100, height: size.height + 100)
        let background = MaterialComparisonBackdrop(frame: NSRect(origin: .zero, size: comparisonSize))
        window.contentView = background
        window.setFrame(NSRect(origin: window.frame.origin, size: comparisonSize), display: true)
        surface.frame = NSRect(origin: NSPoint(x: 50, y: 50), size: size)
        surface.autoresizingMask = []
        background.addSubview(surface)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Explicitly brought forward by the QA menu so a system-composited capture
    // can show the independent background window, even while another app is active.
    func presentDesktopComparison() {
        guard let backdrop, let screen = backdrop.screen,
              let front = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("lumax.") == true }) else { return }
        restoreComparison()
        backdrop.setFrame(screen.frame, display: true)
        backdrop.level = .floating
        backdrop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        front.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        front.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        front.setFrameOrigin(NSPoint(x: screen.frame.midX - front.frame.width / 2, y: screen.frame.midY - front.frame.height / 2))
        backdrop.orderFrontRegardless()
        front.orderFrontRegardless()
    }

    func restoreComparison() {
        if let window = comparisonWindow, let surface = comparisonContent, let frame = comparisonFrame {
            surface.removeFromSuperview()
            window.contentView = surface
            window.setFrame(frame, display: false)
        }
        comparisonWindow = nil
        comparisonContent = nil
        comparisonFrame = nil
    }

    func presentWindowPair(settingsActive: Bool) async {
        await show("主窗口")
        windows.showSettings(shortcuts: shortcuts)
        guard let backdrop, let screen = backdrop.screen,
              let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "lumax.main" }),
              let settings = NSApp.windows.first(where: { $0.identifier?.rawValue == "lumax.settings" }) else { return }
        backdrop.setFrame(screen.frame, display: true)
        backdrop.level = .floating
        backdrop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let mainWidth = min(980, max(660, screen.frame.width - 756))
        let left = screen.frame.midX - (mainWidth + 724) / 2
        main.setFrame(NSRect(x: left, y: screen.frame.midY - 299, width: mainWidth, height: 598), display: true)
        settings.setFrameOrigin(NSPoint(x: left + mainWidth + 24, y: screen.frame.midY - 305))
        backdrop.orderFrontRegardless()
        for window in [main, settings] {
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.orderFrontRegardless()
        }
        (settingsActive ? settings : main).makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        codexEditor?.close()
        codexFixture?.cancelAll()
        defaultCodexFixture.cancelAll()
        windows.shutdown()
        defaults.removePersistentDomain(forName: "Lumax.VisualCatalog.Ephemeral")
        codexDefaults.removePersistentDomain(forName: "Lumax.VisualCatalog.Codex.Ephemeral")
    }
}

// Independent QA-only window content. Strong edges and neutral extremes expose
// flattened backdrops and unreadable controls that a pastel image can conceal.
@MainActor private final class ContrastBackdrop: NSView {
    let kind: String
    init(kind: String) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor]
        switch kind {
        case "浅色桌面背景": colors = [NSColor(white: 0.98, alpha: 1), NSColor(white: 0.85, alpha: 1)]
        case "深色桌面背景": colors = [NSColor(white: 0.04, alpha: 1), NSColor(white: 0.16, alpha: 1)]
        default: colors = [.systemCyan, .systemBlue, .systemPink, .white]
        }
        let width = bounds.width / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height).fill()
        }
        let ribbon = NSBezierPath()
        ribbon.move(to: NSPoint(x: 0, y: bounds.height * 0.1))
        ribbon.line(to: NSPoint(x: bounds.width, y: bounds.height * 0.9))
        ribbon.lineWidth = 48
        NSColor.white.withAlphaComponent(0.65).setStroke()
        ribbon.stroke()
    }
}
@MainActor private final class VisualCaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
@MainActor private struct EmptyProvider: TranslationProvider {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult { throw TranslationError.nothingToTranslate }
}
private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red:0.76,green:0.92,blue:0.96), Color(red:0.56,green:0.7,blue:0.89), Color(red:0.91,green:0.78,blue:0.88)], startPoint:.topLeading,endPoint:.bottomTrailing)
            Ellipse().fill(LinearGradient(colors:[.white.opacity(0.7),.blue.opacity(0.07)], startPoint:.top,endPoint:.bottom)).frame(width:1400,height:400).rotationEffect(.degrees(-24)).offset(x:-90,y:40).blur(radius:4)
            Ellipse().fill(.white.opacity(0.28)).frame(width:1000,height:300).rotationEffect(.degrees(-32)).offset(x:250,y:310)
        }.ignoresSafeArea()
    }
}

@MainActor private final class MaterialComparisonBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(red: 0.72, green: 0.95, blue: 0.97, alpha: 1),
                            NSColor(red: 0.56, green: 0.70, blue: 0.89, alpha: 1),
                            NSColor(red: 0.93, green: 0.77, blue: 0.87, alpha: 1)])?.draw(in: bounds, angle: -28)
        let ribbon = NSBezierPath()
        ribbon.move(to: NSPoint(x: -100, y: 70))
        ribbon.curve(to: NSPoint(x: bounds.width + 100, y: bounds.height - 80),
                     controlPoint1: NSPoint(x: bounds.width * 0.4, y: 280),
                     controlPoint2: NSPoint(x: bounds.width * 0.75, y: bounds.height - 180))
        ribbon.lineWidth = 80
        NSColor.white.withAlphaComponent(0.34).setStroke()
        ribbon.stroke()
        let note = "构造背景 · 原生材质合成对照 · 非桌面取样验收"
        note.draw(at: NSPoint(x: 52, y: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray])
    }
}
