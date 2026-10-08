import AppKit

/// All pasteboard IPC stays off MainActor, including lazy data-provider fulfillment.
/// AppKit offers no cancellable read or custom IPC timeout: a slow provider may still
/// delay this actor. Cancellation prevents subsequent Copy; it cannot kill that read.
actor SelectionClipboard {
    private let pasteboardName: String?
    private var cachedPasteboard: NSPasteboard?

    /// Named boards are used by tests; production uses the general pasteboard.
    init(pasteboardName: String? = nil) {
        self.pasteboardName = pasteboardName
    }

    func backup() throws -> ClipboardBackup {
        try ClipboardBackup(pasteboard: pasteboard)
    }

    func changeCount() -> Int {
        pasteboard.changeCount
    }

    func readText(expectedChangeCount: Int) throws -> String? {
        let board = pasteboard
        guard board.changeCount == expectedChangeCount else { throw SelectionError.clipboardChanged }
        let text = board.string(forType: .string)
        guard board.changeCount == expectedChangeCount else { throw SelectionError.clipboardChanged }
        return text
    }

    /// Returns false when another operation changed the board or the source lost focus.
    /// NSPasteboard has no atomic compare-and-swap; the final check minimizes that gap.
    func restore(
        _ backup: ClipboardBackup,
        expectedChangeCount: Int,
        sourceIsActive: @MainActor @Sendable () -> Bool
    ) async throws -> Bool {
        let restoredItems = try backup.materializedItems()
        guard await sourceIsActive() else { return false }
        let board = pasteboard
        guard board.changeCount == expectedChangeCount else { return false }
        board.clearContents()
        guard restoredItems.isEmpty || board.writeObjects(restoredItems) else { throw SelectionError.clipboardRestoreFailed }
        return true
    }

    private var pasteboard: NSPasteboard {
        if let cachedPasteboard { return cachedPasteboard }
        let board = pasteboardName.map { NSPasteboard(name: .init($0)) } ?? NSPasteboard.general
        cachedPasteboard = board
        return board
    }
}

/// A bounded in-memory value snapshot. No NSPasteboard or NSPasteboardItem instances
/// leave SelectionClipboard. The size limit applies after each representation arrives;
/// AppKit cannot tell us a promised representation's eventual size before reading it.
struct ClipboardBackup: Sendable {
    struct Representation: Sendable {
        let type: String
        let data: Data
    }

    let changeCount: Int
    private let items: [[Representation]]

    fileprivate init(pasteboard: NSPasteboard) throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        changeCount = pasteboard.changeCount
        let sourceItems = pasteboard.pasteboardItems ?? []
        guard sourceItems.count <= 64 else { throw SelectionError.clipboardUnavailable }
        guard !sourceItems.isEmpty || (pasteboard.types ?? []).isEmpty else { throw SelectionError.clipboardUnavailable }
        var byteCount = 0
        var snapshots: [[Representation]] = []
        for item in sourceItems {
            guard item.types.count <= 64 else { throw SelectionError.clipboardUnavailable }
            var representations: [Representation] = []
            for type in item.types {
                guard clock.now < deadline else { throw SelectionError.clipboardUnavailable }
                guard let data = item.data(forType: type) else { throw SelectionError.clipboardUnavailable }
                guard clock.now < deadline else { throw SelectionError.clipboardUnavailable }
                byteCount += data.count
                guard byteCount <= 8 * 1_024 * 1_024 else { throw SelectionError.clipboardUnavailable }
                representations.append(Representation(type: type.rawValue, data: data))
            }
            guard !representations.isEmpty else { throw SelectionError.clipboardUnavailable }
            snapshots.append(representations)
        }
        guard clock.now < deadline else { throw SelectionError.clipboardUnavailable }
        guard pasteboard.changeCount == changeCount else { throw SelectionError.clipboardChanged }
        items = snapshots
    }

    fileprivate func materializedItems() throws -> [NSPasteboardItem] {
        var restoredItems: [NSPasteboardItem] = []
        for representations in items {
            let item = NSPasteboardItem()
            for representation in representations {
                guard item.setData(representation.data, forType: .init(representation.type)) else {
                    throw SelectionError.clipboardRestoreFailed
                }
            }
            restoredItems.append(item)
        }
        return restoredItems
    }
}
