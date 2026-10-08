import SwiftUI

// AppKit emits the back-tab character (U+0019) for Shift-Tab in text fields;
// matching only KeyEquivalent.tab misses reverse navigation out of search.
struct TranslationServiceProviderPicker: View {
    @Environment(\.translateXTheme) private var theme
    let selected: TranslationServiceKind
    let choose: (TranslationServiceKind) -> Void
    let dismiss: () -> Void
    @FocusState private var focused: TranslationServiceKind?
    private let ai: [TranslationServiceKind] = [.openAI, .deepSeek, .claude, .openAICompatible, .ollama]
    private let dedicated: [TranslationServiceKind] = [.deepL, .azureTranslator, .qwenMT, .googleCloud, .tencentTranslation]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("AI models", kinds: ai)
            TranslationServiceDivider()
            group("Dedicated translation", kinds: dedicated)
            TranslationServiceDivider()
            group("Account sign-in", kinds: [.codex])
        }
        .padding(12)
        .background(TranslationServicePalette(theme: theme).popover, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(TranslationServicePalette(theme: theme).line, lineWidth: 1) }
        .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.13), radius: 15, y: 7)
        .task { focused = selected }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.downArrow) { move(2); return .handled }
        .onKeyPress(.upArrow) { move(-2); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.return) { choose(focused ?? selected); return .handled }
        .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in move((press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}")) ? -1 : 1, wrap: true); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Choose a provider"))
    }

    private func group(_ title: String, kinds: [TranslationServiceKind]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.string(title)).font(.system(size: 10, weight: .medium))
                .foregroundStyle(TranslationServicePalette(theme: theme).muted).padding(.horizontal, 6)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 2) {
                ForEach(kinds) { option($0) }
            }
        }
    }

    private func option(_ kind: TranslationServiceKind) -> some View {
        let p = TranslationServicePalette(theme: theme)
        return Button { choose(kind) } label: {
            HStack(spacing: 8) {
                TranslationServiceProviderMark(kind: kind, size: 22)
                Text(kind.settingsName).font(.system(size: 11)).lineLimit(2)
                Spacer(minLength: 1)
                if kind == selected { Image(systemName: "checkmark").font(.system(size: 11)) }
            }
            .foregroundStyle(kind == selected ? p.accent : p.ink)
            .padding(.horizontal, 7).frame(minHeight: 34)
            .background(kind == selected ? p.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay { if focused == kind { RoundedRectangle(cornerRadius: 8).stroke(p.accent.opacity(0.72), lineWidth: 2).padding(-1) } }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(TranslateXHoverButtonStyle())
        .focusable()
        .focused($focused, equals: kind)
        .focusEffectDisabled()
        .accessibilityAddTraits(kind == selected ? .isSelected : [])
    }

    private func move(_ offset: Int, wrap: Bool = false) {
        let kinds = ai + dedicated + [.codex]
        let current = kinds.firstIndex(of: focused ?? selected) ?? 0
        let next = current + offset
        focused = kinds[wrap ? (next + kinds.count) % kinds.count : min(max(next, 0), kinds.count - 1)]
    }
}

struct TranslationServiceModelPicker: View {
    @Environment(\.translateXTheme) private var theme
    let models: [TranslationServiceModel]
    let selected: String
    let account: Bool
    let choose: (String) -> Void
    let dismiss: () -> Void
    var manualEntry: (() -> Void)? = nil
    var loadModels: (() -> Void)? = nil
    @State private var search = ""
    @FocusState private var loadFocused: Bool
    @FocusState private var manualFocused: Bool
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedModel: String?

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
                Text(L10n.string(models.isEmpty ? "Get models to browse this service’s directory, or enter an ID manually." : "No matching models.")).font(.system(size: 11)).foregroundStyle(p.muted)
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
                    .onChange(of: focusedModel) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            if models.isEmpty, let loadModels {
                Button(L10n.string("Get models"), action: loadModels)
                    .buttonStyle(TranslationServiceButtonStyle(kind: .soft))
                    .focusable().focused($loadFocused)
                    .padding(.horizontal, 7).padding(.bottom, 3)
            }
            if let manualEntry {
                TranslationServiceDivider().padding(.top, 3)
                Button(action: manualEntry) {
                    Label(L10n.string("Enter model ID manually"), systemImage: "square.and.pencil")
                        .font(.system(size: 11)).foregroundStyle(p.accent)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).padding(.horizontal, 7)
                }
                .buttonStyle(TranslateXHoverButtonStyle()).focusable().focused($manualFocused).focusEffectDisabled()
                .overlay { if manualFocused { RoundedRectangle(cornerRadius: 6).stroke(p.accent.opacity(0.72), lineWidth: 2) } }
            }
            TranslationServiceDivider().padding(.top, 3)
            Text(L10n.string("A model list does not guarantee translation suitability. Check with a sample test."))
                .font(.system(size: 10)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                .padding(.horizontal, 7).padding(.top, 2)
        }
        .padding(8)
        .background(p.popover, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(p.line, lineWidth: 1) }
        .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.13), radius: 15, y: 7)
        .task {
            if models.isEmpty && loadModels != nil { loadFocused = true }
            else if models.isEmpty && manualEntry != nil { manualFocused = true }
            else { searchFocused = true }
        }
        .onChange(of: search) { _, _ in focusedModel = nil }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            if loadFocused { loadModels?() } else if manualFocused { manualEntry?() } else if let id = focusedModel { choose(id) }
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
            .background(model.id == selected ? p.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { if focusedModel == model.id { RoundedRectangle(cornerRadius: 6).stroke(p.accent.opacity(0.72), lineWidth: 2).padding(1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(TranslateXHoverButtonStyle())
        .focusable()
        .focused($focusedModel, equals: model.id)
        .focusEffectDisabled()
        .accessibilityAddTraits(model.id == selected ? .isSelected : [])
    }

    private enum FocusTarget: Equatable { case search, model(String), load, manual }
    private func cycleFocus(backward: Bool) {
        var order: [FocusTarget] = [.search] + filtered.map { .model($0.id) }
        if models.isEmpty && loadModels != nil { order.append(.load) }
        if manualEntry != nil { order.append(.manual) }
        let current: FocusTarget = loadFocused ? .load : manualFocused ? .manual : focusedModel.map(FocusTarget.model) ?? .search
        let index = order.firstIndex(of: current) ?? 0
        let next = order[(index + (backward ? -1 : 1) + order.count) % order.count]
        searchFocused = next == .search
        manualFocused = next == .manual
        loadFocused = next == .load
        if case .model(let id) = next { focusedModel = id } else { focusedModel = nil }
    }

    private func move(_ offset: Int) {
        guard !filtered.isEmpty else { return }
        let current = filtered.firstIndex(where: { $0.id == focusedModel }) ?? -1
        let next = min(max(current + offset, 0), filtered.count - 1)
        searchFocused = false
        focusedModel = filtered[next].id
    }
    private func focusFirstModel() {
        guard let first = filtered.first else { return }
        searchFocused = false
        focusedModel = first.id
    }
}
