import SwiftUI

// Search and keyboard navigation share the same visible order.
// Only keyboard navigation requests centering. Pointer focus must not move the
// pressed item before mouse-up, or the first click is swallowed after reopening.
struct TranslationServiceProviderPicker: View {
    @Environment(\.translateXTheme) private var theme
    let selected: TranslationServicePreset
    var includesAccount = true
    let choose: (TranslationServicePreset) -> Void
    let dismiss: () -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var focused: TranslationServicePreset?
    @State private var navigationRevision = 0

    private var groups: [(String, [TranslationServicePreset])] {
        let all = TranslationServicePreset.allCases.filter { includesAccount || $0.kind != .codex }
        let matches = all.filter {
            search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.rawValue.localizedCaseInsensitiveContains(search)
                || $0.searchKeywords.localizedCaseInsensitiveContains(search)
                || $0.defaultEndpoint.localizedCaseInsensitiveContains(search)
        }
        let gateways: Set<String> = ["custom", "newAPI", "siliconFlow", "openRouter"]
        return [
            ("AI models", matches.filter { !gateways.contains($0.rawValue) && $0.kind.allowsCustomModel && $0.kind != .ollama }),
            ("Gateways and custom services", matches.filter { gateways.contains($0.rawValue) }),
            ("Dedicated translation", matches.filter { !$0.kind.allowsCustomModel && $0.kind != .codex }),
            ("Local models", matches.filter { $0.kind == .ollama }),
            ("Account sign-in", matches.filter { $0.kind == .codex })
        ].filter { !$0.1.isEmpty }
    }
    private var visible: [TranslationServicePreset] { groups.flatMap(\.1) }
    private var rows: [[TranslationServicePreset]] {
        groups.flatMap { group in
            stride(from: 0, to: group.1.count, by: 2).map { Array(group.1[$0..<min($0 + 2, group.1.count)]) }
        }
    }

    var body: some View {
        let p = TranslationServicePalette(theme: theme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(p.muted)
                TextField(L10n.string("Search providers…"), text: $search)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onKeyPress(.downArrow) { focusFirst(); return .handled }
                    .onKeyPress(.return) { if let first = visible.first { choose(first) }; return .handled }
                    .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
                        cycle(backward: press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}")); return .handled
                    }
            }
            .font(.system(size: 11)).padding(.horizontal, 9).frame(height: 32)
            .background(p.fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay { if searchFocused { RoundedRectangle(cornerRadius: 7).stroke(p.accent.opacity(0.72), lineWidth: 2).padding(-1) } }
            if visible.isEmpty {
                Text(L10n.string("No matching providers.")).font(.system(size: 11)).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 13) {
                            ForEach(groups, id: \.0) { group in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(L10n.string(group.0)).font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(p.muted).padding(.horizontal, 6)
                                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 3) {
                                        ForEach(group.1) { preset in option(preset).id(preset) }
                                    }
                                }
                            }
                        }.padding(3).translateXScrollContent()
                    }
                    .frame(height: min(CGFloat(groups.reduce(0) { $0 + ($1.1.count + 1) / 2 }) * 39 + CGFloat(groups.count) * 30, 280))
                    .onChange(of: navigationRevision) { _, _ in if let focused { proxy.scrollTo(focused, anchor: .center) } }
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 11).fill(p.popover)
                .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.13), radius: 15, y: 7)
        }
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(p.line, lineWidth: 1).allowsHitTesting(false) }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
        .onChange(of: search) { _, _ in focused = nil }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.downArrow) { moveVertically(1); return .handled }
        .onKeyPress(.upArrow) { moveVertically(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.return) { if let focused { choose(focused) }; return .handled }
        .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
            cycle(backward: press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}")); return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Choose a provider"))
    }

    private func option(_ preset: TranslationServicePreset) -> some View {
        let p = TranslationServicePalette(theme: theme)
        return Button { choose(preset) } label: {
            HStack(spacing: 8) {
                TranslationServiceProviderMark(icon: TranslationServiceIcon(rawValue: preset.defaultIconID) ?? .network, size: 22)
                Text(preset.displayName).font(.system(size: 11)).lineLimit(2)
                Spacer(minLength: 1)
                if preset == selected { Image(systemName: "checkmark").font(.system(size: 11)) }
            }
            .foregroundStyle(preset == selected ? p.accent : p.ink)
            .padding(.horizontal, 7).frame(minHeight: 36)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(TranslationServicePickerOptionStyle(selected: preset == selected, focused: focused == preset))
        .focusable().focused($focused, equals: preset).focusEffectDisabled()
        .accessibilityAddTraits(preset == selected ? .isSelected : [])
    }
    private func focusFirst() {
        defer { navigationRevision &+= 1 }
        guard let first = visible.first else { return }
        searchFocused = false; focused = first
    }
    private func moveVertically(_ direction: Int) {
        defer { navigationRevision &+= 1 }
        guard let current = focused, let row = rows.firstIndex(where: { $0.contains(current) }),
              let column = rows[row].firstIndex(of: current) else { focusFirst(); return }
        let next = row + direction
        if next < 0 { searchFocused = true; focused = nil }
        else if next < rows.count { focused = rows[next][min(column, rows[next].count - 1)] }
    }
    private func move(_ offset: Int) {
        defer { navigationRevision &+= 1 }
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex(of: focused ?? selected) ?? 0
        searchFocused = false
        focused = visible[min(max(current + offset, 0), visible.count - 1)]
    }
    private func cycle(backward: Bool) {
        defer { navigationRevision &+= 1 }
        let index = focused.flatMap { visible.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let next = (index + (backward ? -1 : 1) + visible.count + 1) % (visible.count + 1)
        searchFocused = next == 0
        focused = next == 0 ? nil : visible[next - 1]
    }
}

struct TranslationServiceIconPicker: View {
    @Environment(\.translateXTheme) private var theme
    let configuration: TranslationServiceConfiguration
    let choose: (String?) -> Void
    let dismiss: () -> Void
    @FocusState private var focused: String?
    @State private var navigationRevision = 0
    private let defaultID = "default"
    private var selectedIconID: String? {
        configuration.iconID.flatMap { TranslationServiceIcon(rawValue: $0)?.rawValue }
    }
    private var rows: [[String]] {
        [[defaultID]] + [TranslationServiceIcon.brandIcons, TranslationServiceIcon.genericIcons].flatMap { icons in
            stride(from: 0, to: icons.count, by: 5).map { icons[$0..<min($0 + 5, icons.count)].map(\.rawValue) }
        }
    }
    private var order: [String] { rows.flatMap { $0 } }

    var body: some View {
        let p = TranslationServicePalette(theme: theme)
        VStack(alignment: .leading, spacing: 10) {
            Button { choose(nil) } label: {
                HStack(spacing: 8) {
                    TranslationServiceProviderMark(icon: TranslationServiceIcon(rawValue: configuration.providerPreset.defaultIconID) ?? .network, size: 26)
                    Text(L10n.string("Default provider icon"))
                    Spacer()
                    if selectedIconID == nil { Image(systemName: "checkmark") }
                }
                .font(.system(size: 11)).padding(6).contentShape(Rectangle())
            }
            .buttonStyle(TranslationServicePickerOptionStyle(selected: selectedIconID == nil, focused: focused == defaultID))
            .focusable().focused($focused, equals: defaultID).focusEffectDisabled()
            .accessibilityAddTraits(selectedIconID == nil ? .isSelected : [])
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        iconGroup("Brand icons", icons: TranslationServiceIcon.brandIcons)
                        iconGroup("General icons", icons: TranslationServiceIcon.genericIcons)
                    }.padding(3).translateXScrollContent()
                }
                .frame(height: 264)
                .onAppear {
                    if let selectedIconID { proxy.scrollTo(selectedIconID, anchor: .center) }
                }
                .onChange(of: navigationRevision) { _, _ in
                    if let focused, focused != defaultID { proxy.scrollTo(focused, anchor: .center) }
                }
            }
        }
        .padding(12)
        .foregroundStyle(p.ink)
        .background {
            RoundedRectangle(cornerRadius: 11).fill(p.popover)
                .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.13), radius: 15, y: 7)
        }
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(p.line, lineWidth: 1).allowsHitTesting(false) }
        .task {
            // The editor relinquishes focus as the overlay mounts. Restore it
            // after the selected lazy-grid item has joined the focus tree.
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = selectedIconID ?? defaultID
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.return) { if let focused { choose(focused == defaultID ? nil : focused) }; return .handled }
        .onKeyPress(.downArrow) { moveVertically(1); return .handled }
        .onKeyPress(.upArrow) { moveVertically(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
            move(press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}") ? -1 : 1, wrap: true); return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Change service icon"))
    }

    private func iconGroup(_ title: String, icons: [TranslationServiceIcon]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string(title)).font(.system(size: 10)).foregroundStyle(TranslationServicePalette(theme: theme).muted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 5), spacing: 5) {
                ForEach(icons) { icon in
                    Button { choose(icon.rawValue) } label: {
                        VStack(spacing: 4) {
                            TranslationServiceProviderMark(icon: icon, size: 30)
                            Text(icon.displayName).font(.system(size: 9)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(TranslationServicePickerOptionStyle(selected: selectedIconID == icon.rawValue, focused: focused == icon.rawValue))
                    .focusable().focused($focused, equals: icon.rawValue).focusEffectDisabled()
                    .accessibilityLabel(icon.displayName)
                    .accessibilityAddTraits(configuration.iconID == icon.rawValue ? .isSelected : [])
                    .id(icon.rawValue)
                }
            }
        }
    }
    private func move(_ offset: Int, wrap: Bool = false) {
        defer { navigationRevision &+= 1 }
        let index = order.firstIndex(of: focused ?? defaultID) ?? 0
        focused = order[wrap ? (index + offset + order.count) % order.count : min(max(index + offset, 0), order.count - 1)]
    }
    private func moveVertically(_ direction: Int) {
        defer { navigationRevision &+= 1 }
        let current = focused ?? defaultID
        guard let row = rows.firstIndex(where: { $0.contains(current) }),
              let column = rows[row].firstIndex(of: current) else { return }
        let next = min(max(row + direction, 0), rows.count - 1)
        focused = rows[next][min(column, rows[next].count - 1)]
    }
}

struct TranslationServiceModelPicker: View {
    @Environment(\.translateXTheme) private var theme
    let models: [TranslationServiceModel]
    let selected: String
    let account: Bool
    let choose: (String) -> Void
    let dismiss: () -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedModel: String?
    @State private var navigationRevision = 0

    private var filtered: [TranslationServiceModel] {
        guard !search.isEmpty else { return models }
        return models.filter { $0.id.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        let p = TranslationServicePalette(theme: theme)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(p.muted)
                TextField(L10n.string("Search models…"), text: $search)
                    .textFieldStyle(.plain).font(.system(size: 11)).focused($searchFocused)
                    .onKeyPress(.downArrow) { focusFirstModel(); return .handled }
                    .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
                        cycleFocus(backward: (press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}")))
                        return .handled
                    }
                    .onKeyPress(.return) { if let first = filtered.first { choose(first.id) }; return .handled }
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(p.fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay { if searchFocused { RoundedRectangle(cornerRadius: 7).stroke(p.accent.opacity(0.72), lineWidth: 2).padding(-1) } }

            if filtered.isEmpty {
                Text(L10n.string(models.isEmpty ? "No model list yet. Get models to choose from this service’s directory." : "No matching models.")).font(.system(size: 11)).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, minHeight: 43, alignment: .leading).padding(.horizontal, 7)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { model in
                                option(model).id(model.id)
                            }
                        }
                        .translateXScrollContent()
                    }
                    .frame(height: min(CGFloat(filtered.count) * (account ? 46 : 33), 139))
                    .onChange(of: navigationRevision) { _, _ in if let focusedModel { proxy.scrollTo(focusedModel, anchor: .center) } }
                }
            }
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 11).fill(p.popover)
                .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.13), radius: 15, y: 7)
        }
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(p.line, lineWidth: 1).allowsHitTesting(false) }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
        .onChange(of: search) { _, _ in focusedModel = nil }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            if let id = focusedModel { choose(id) }
            return .handled
        }
        .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
            cycleFocus(backward: (press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}")))
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Available models"))
    }

    private func option(_ model: TranslationServiceModel) -> some View {
        let p = TranslationServicePalette(theme: theme)
        return Button { choose(model.id) } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.system(size: 11)).lineLimit(2)
                    if account, model.name != model.id { Text(model.id).font(.system(size: 9)).foregroundStyle(p.muted).lineLimit(1) }
                }
                Spacer(minLength: 3)
                if model.id == selected { Image(systemName: "checkmark").font(.system(size: 11)) }
            }
            .foregroundStyle(model.id == selected ? p.accent : p.ink)
            .padding(.horizontal, 7).frame(minHeight: account ? 46 : 33)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(TranslationServicePickerOptionStyle(selected: model.id == selected, focused: focusedModel == model.id))
        .focusable()
        .focused($focusedModel, equals: model.id)
        .focusEffectDisabled()
        .accessibilityAddTraits(model.id == selected ? .isSelected : [])
    }

    private enum FocusTarget: Equatable { case search, model(String) }
    private func cycleFocus(backward: Bool) {
        defer { navigationRevision &+= 1 }
        let order: [FocusTarget] = [.search] + filtered.map { .model($0.id) }
        let current: FocusTarget = focusedModel.map(FocusTarget.model) ?? .search
        let index = order.firstIndex(of: current) ?? 0
        let next = order[(index + (backward ? -1 : 1) + order.count) % order.count]
        searchFocused = next == .search
        if case .model(let id) = next { focusedModel = id } else { focusedModel = nil }
    }

    private func move(_ offset: Int) {
        defer { navigationRevision &+= 1 }
        guard !filtered.isEmpty else { return }
        let current = filtered.firstIndex(where: { $0.id == focusedModel }) ?? -1
        let next = min(max(current + offset, 0), filtered.count - 1)
        searchFocused = false
        focusedModel = filtered[next].id
    }
    private func focusFirstModel() {
        defer { navigationRevision &+= 1 }
        guard let first = filtered.first else { return }
        searchFocused = false
        focusedModel = first.id
    }
}
