import SwiftUI

struct ModelPickerButton: View {
    @EnvironmentObject var store: AppStore
    @Binding var selection: AgentModel
    @State private var presented = false
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 6) {
                ModelBrandIcon(brand: selection.brand, size: 16)
                Text(selection.label).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.kilnText)
            .padding(.horizontal, 8).frame(minHeight: 28)
            .background(Color.kilnSurface).clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(WorkspaceButtonStyle())
        .help(selection.helpText)
        .popover(isPresented: $presented) {
            ModelPickerView(selection: $selection) { presented = false }
                .environmentObject(store)
        }
    }
}

private struct ModelPickerView: View {
    @EnvironmentObject var store: AppStore
    @Binding var selection: AgentModel
    let onSelect: () -> Void
    @State private var query = ""
    @State private var tab: ModelTab = .codex
    @State private var refreshing = false

    private enum ModelTab: String, CaseIterable, Identifiable {
        case codex = "Codex", opencode = "OpenCode", grok = "Grok"
        var id: String { rawValue }
    }

    private func shows(_ group: AgentModel.Group) -> Bool {
        switch tab {
        case .codex: return group.provider == .codex
        case .opencode: return group.provider == .opencode
        case .grok: return group.provider == .grok
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
                Button {
                    refreshing = true
                    Task { await store.refreshModelCatalog(); refreshing = false }
                } label: {
                    if refreshing || store.refreshingCodexModels { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(refreshing || store.refreshingCodexModels || store.refreshingGrokModels)
                .help("Refresh model catalogs")
            }.padding(14)
            Picker("Backend", selection: $tab) {
                Text("Codex").tag(ModelTab.codex)
                Text("OpenCode").tag(ModelTab.opencode)
                Text("Grok").tag(ModelTab.grok)
            }
            .pickerStyle(.segmented).padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            if let warning = store.codexCatalogWarning, tab == .codex {
                Text(warning).font(.system(size: 11)).foregroundStyle(Color.kilnWarning).padding(12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(AgentModel.groupedByProvider.filter(shows)) { group in
                        let matches = group.models.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.rawValue.localizedCaseInsensitiveContains(query) }
                        if !matches.isEmpty {
                            Text(group.label).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.kilnTextSecondary)
                                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                            ForEach(matches) { model in
                                Button {
                                    selection = model
                                    onSelect()
                                } label: {
                                    HStack(spacing: 10) {
                                        ModelBrandIcon(brand: model.brand, size: 20)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(model.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            let subtitle = model.provider == .codex ? model.tier : model.cliModel
                                            if !subtitle.isEmpty {
                                                Text(subtitle)
                                                    .font(.system(size: 10)).foregroundStyle(Color.kilnTextSecondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.kilnAccent)
                                            .opacity(selection == model ? 1 : 0)
                                            .frame(width: 14)
                                    }
                                    .foregroundStyle(Color.kilnText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(selection == model ? Color.kilnAccentMuted : Color.clear)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if tab == .opencode && OpenCodeModels.shared.models.isEmpty {
                        Text(refreshing ? "Loading models..." : "Refresh to load OpenCode models.")
                            .font(.system(size: 12)).foregroundStyle(Color.kilnTextSecondary).padding(16)
                    }
                    if let error = store.modelCatalogError, tab == .opencode {
                        Text(error).font(.system(size: 11)).foregroundStyle(Color.kilnError).padding(14)
                    }
                    if tab == .grok {
                        if store.refreshingGrokModels {
                            ProgressView().controlSize(.small).padding(16)
                        } else if let error = store.grokCatalogError {
                            Text(error).font(.system(size: 11)).foregroundStyle(Color.kilnError).padding(14)
                        } else if GrokModels.shared.models.isEmpty {
                            Text("No Grok models available.").font(.system(size: 12)).foregroundStyle(Color.kilnTextSecondary).padding(16)
                        }
                    }
                }
            }
        }
        .frame(width: 460, height: 460)
        .background(Color.kilnBg)
        .onExitCommand(perform: onSelect)
        .onAppear {
            switch selection.provider {
            case .codex: tab = .codex
            case .opencode: tab = .opencode
            case .grok: tab = .grok
            }
        }
        .task {
            await store.refreshCodexModelCatalog()
            if selection.provider == .grok { await store.refreshGrokModelCatalog() }
        }
        .onChange(of: tab) {
            if tab == .opencode && OpenCodeModels.shared.models.isEmpty {
                refreshing = true
                Task { await store.refreshModelCatalog(); refreshing = false }
            }
            if tab == .grok && GrokModels.shared.models.isEmpty {
                Task { await store.refreshGrokModelCatalog() }
            }
        }
    }
}
