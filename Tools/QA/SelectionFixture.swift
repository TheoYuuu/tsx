import AppKit

/// A source app with deliberately distinct AX and Copy contracts. It never sends
/// events to another process or reads its UI. Clipboard access is explicit and bounded.
enum SelectionFixtureMode: String, CaseIterable {
    case direct, copy, empty, secure, timeout, interference
    var title: String {
        switch self {
        case .direct: "1 · 直接取词"
        case .copy: "2 · 复制兜底与恢复"
        case .empty: "3 · 空选区"
        case .secure: "4 · 受保护角色"
        case .timeout: "5 · 复制无响应"
        case .interference: "6 · 新复制内容保护"
        }
    }
    var expected: String {
        switch self {
        case .direct: "Lumax 原文应为 AX 开头的句子；复制次数 0，标记保持。"
        case .copy: "Lumax 原文应为 COPY 开头的句子；复制次数 1，标记恢复。"
        case .empty: "Lumax 应提示未选中文字；复制次数 0，标记保持。"
        case .secure: "Lumax 应提示受保护字段；复制次数 0，标记保持。"
        case .timeout: "Lumax 应提示无法取词；复制次数 1，标记保持，不能翻译旧标记。"
        case .interference: "应保留 NEW 标记，不被旧备份覆盖；若检测到竞争，Lumax 提示内容变化。"
        }
    }
}

@MainActor
final class SelectionFixtureView: NSView {
    static let base = "LUMAX-QA-BASE-20260923"
    static let newer = "LUMAX-QA-NEW-20260923"
    static let directText = "AX: A quiet window helps you focus."
    static let copyText = "COPY: A bright window helps you focus."
    var mode = SelectionFixtureMode.direct
    var board = NSPasteboard.general
    var copies = 0
    var didCopy: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        mode == .secure ? .secureTextField : nil
    }
    override func accessibilityLabel() -> String? { "Lumax 构造选区" }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func accessibilitySelectedText() -> String? {
        switch mode {
        case .direct: Self.directText
        case .empty: ""
        default: nil
        }
    }
    override func accessibilitySelectedTextRange() -> NSRange {
        NSRange(location: 0, length: mode == .empty ? 0 : Self.directText.utf16.count)
    }
    override func accessibilityString(for range: NSRange) -> String? {
        mode == .direct ? Self.directText : nil
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let sample = mode == .direct ? Self.directText : Self.copyText
        let visible = mode == .secure ? "Protected sample · no real password" : sample
        (visible as NSString).draw(in: bounds.insetBy(dx: 18, dy: 30), withAttributes: [
            .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.textColor
        ])
        NSColor.controlAccentColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)).stroke()
    }
    @objc func copy(_ sender: Any?) {
        copies += 1
        // No normal Copy operation is accepted for the explicit empty/secure cases.
        guard mode != .empty, mode != .secure else { didCopy?(); return }
        if mode != .timeout {
            write(mode == .direct ? Self.directText : Self.copyText)
            if mode == .interference { write(Self.newer) }
        }
        didCopy?()
    }
    func prepare(_ mode: SelectionFixtureMode) {
        self.mode = mode
        copies = 0
        write(Self.base)
        needsDisplay = true
        window?.makeFirstResponder(self)
    }
    func write(_ value: String) {
        board.clearContents()
        board.setString(value, forType: .string)
    }
    func clipboardState() -> String {
        // Never display or persist arbitrary clipboard text.
        switch board.string(forType: .string) {
        case Self.base: "BASE 标记保持/恢复"
        case Self.newer: "NEW 标记保持"
        case Self.copyText, Self.directText: "仍是临时选区文本"
        default: "已是其他内容（不显示正文）"
        }
    }
}

@MainActor
final class SelectionFixtureApp: NSObject, NSApplicationDelegate {
    private let view = SelectionFixtureView(frame: .zero)
    private let picker = NSPopUpButton()
    private let expected = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "尚未准备样例。")
    private var window: NSWindow!
    private var statusTask: Task<Void, Never>?
    private var prepared = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 730, height: 430),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Lumax 取词验证 · 构造样例"
        let title = NSTextField(labelWithString: "取词路径与剪贴板检查")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let instructions = NSTextField(wrappingLabelWithString:
            "选择场景 → 准备样例 → 在本窗口按 Lumax 取词快捷键 → 核对结果。\n准备按钮会把测试标记复制到剪贴板；请在完成日常复制工作后再测试。")
        picker.addItems(withTitles: SelectionFixtureMode.allCases.map(\.title))
        let prepare = NSButton(title: "准备样例（复制测试标记）", target: self, action: #selector(prepareSample))
        let check = NSButton(title: "检查一次结果", target: self, action: #selector(checkResult))
        let row = NSStackView(views: [picker, prepare, check])
        row.orientation = .horizontal
        let content = NSStackView(views: [title, instructions, row, view, expected, status])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            view.widthAnchor.constraint(equalTo: content.widthAnchor),
            view.heightAnchor.constraint(equalToConstant: 105)
        ])
        expected.stringValue = SelectionFixtureMode.direct.expected
        status.setAccessibilityIdentifier("fixture.result")
        view.didCopy = { [weak self] in self?.status.stringValue = "收到复制命令；等待 Lumax 收尾后点击检查。" }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出验证窗口", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "复制", action: #selector(SelectionFixtureView.copy(_:)), keyEquivalent: "c")
        editItem.submenu = edit
        NSApp.mainMenu = menu
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func prepareSample() {
        statusTask?.cancel()
        prepared = true
        let mode = SelectionFixtureMode.allCases[picker.indexOfSelectedItem]
        view.prepare(mode)
        expected.stringValue = mode.expected
        status.stringValue = "已准备：请在样例保持焦点时按 ⌃⌥⌘T（或你的取词快捷键）。"
        // One delayed read, not a background clipboard monitor.
        statusTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.checkResult()
        }
    }
    @objc private func checkResult() {
        statusTask?.cancel()
        let state = prepared ? view.clipboardState() : "未准备，不检查剪贴板"
        // A UI tool can deliver local activation events without changing the real
        // frontmost process. Use the same system identity check as SelectionService.
        let isSystemFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        status.stringValue = "复制次数：\(view.copies)；\(state)。\n系统前台应用：\(isSystemFrontmost ? "本样例" : "其他应用")。请同时核对 Lumax 原文/提示。"
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { statusTask?.cancel() }
}

@main
struct SelectionFixtureMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--self-test") {
            let view = SelectionFixtureView(frame: .zero)
            let board = NSPasteboard(name: .init("LumaxFixtureSelfTest-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            view.board = board
            var passed = 0
            for mode in SelectionFixtureMode.allCases {
                view.prepare(mode)
                let expectedSelection: String? = mode == .direct ? SelectionFixtureView.directText : mode == .empty ? "" : nil
                precondition(view.accessibilitySelectedText() == expectedSelection)
                precondition(view.accessibilityString(for: NSRange(location: 0, length: 1)) == (mode == .direct ? SelectionFixtureView.directText : nil))
                precondition((view.accessibilitySelectedTextRange().length == 0) == (mode == .empty))
                precondition((view.accessibilitySubrole() == .secureTextField) == (mode == .secure))
                view.copy(nil)
                let expectedText: String
                switch mode {
                case .direct: expectedText = SelectionFixtureView.directText
                case .copy: expectedText = SelectionFixtureView.copyText
                case .interference: expectedText = SelectionFixtureView.newer
                default: expectedText = SelectionFixtureView.base
                }
                precondition(board.string(forType: .string) == expectedText)
                precondition(view.copies == 1, "Count even rejected Copy commands")
                passed += 1
            }
            print("PASS: \(passed) fixture contracts on a private pasteboard; not a cross-app result")
            return
        }
        let delegate = SelectionFixtureApp()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
