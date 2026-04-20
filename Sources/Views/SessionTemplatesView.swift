import SwiftUI

// MARK: - Session Templates Picker
//
// Shown as a sheet from the sidebar's new-session menu. Each template is
// a preset bundle of model/mode/permissions/instructions/tags that spins
// up a new session with those defaults baked in. Replaces the manual
// new-session sheet for repeat workflows.

struct SessionTemplatesView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var templates: SessionTemplateStore = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SessionTemplate?
    @State private var showNewSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(Color.kilnAccent)
                Text("Session Templates")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                Spacer()
                Button {
                    editing = SessionTemplate(
                        name: "New template",
                        model: store.settings.defaultModel.rawValue,
                        kind: "code"
                    )
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.kilnAccent)
                        .frame(width: 26, height: 26)
                        .background(Color.kilnAccentMuted)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("New template")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            // Grid of templates
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(templates.templates) { t in
                        TemplateCard(template: t, onUse: {
                            store.createSessionFromTemplate(t)
                            dismiss()
                        }, onEdit: { editing = t })
                    }
                }
                .padding(20)
            }

            // Footer — "save current session as template"
            HStack {
                Button {
                    saveCurrentAsTemplate()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10))
                        Text("Save current session as template")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.kilnTextSecondary)
                }
                .buttonStyle(.plain)
                .disabled(store.activeSession == nil)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            .background(Color.kilnSurface)
        }
        .frame(width: 560, height: 480)
        .background(Color.kilnBg)
        .sheet(item: $editing) { template in
            TemplateEditor(
                template: template,
                isNew: !templates.templates.contains(where: { $0.id == template.id }),
                onSave: { updated in
                    if templates.templates.contains(where: { $0.id == updated.id }) {
                        templates.update(updated)
                    } else {
                        templates.add(updated)
                    }
                },
                onDelete: { templates.remove(template.id) }
            )
            .preferredColorScheme(Color.kilnPreferredColorScheme)
        }
    }

    private func saveCurrentAsTemplate() {
        guard let s = store.activeSession else { return }
        let name = "\(s.name) template"
        store.saveActiveSessionAsTemplate(named: name)
        // Immediately open the editor on the new one so the user can rename it.
        if let latest = templates.templates.last {
            editing = latest
        }
    }
}

private struct TemplateCard: View {
    let template: SessionTemplate
    let onUse: () -> Void
    let onEdit: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: template.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.kilnAccent)
                    .frame(width: 28, height: 28)
                    .background(Color.kilnAccentMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(template.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.kilnText)
                        .lineLimit(1)
                    Text(template.kind.capitalized + (template.mode.map { " · " + $0 } ?? ""))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
                Spacer()
                if hovering {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.kilnTextTertiary)
                            .frame(width: 22, height: 22)
                            .background(Color.kilnSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(template.model)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.kilnTextTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !template.sessionInstructions.isEmpty {
                Text(template.sessionInstructions)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .lineLimit(2)
            }
            if !template.tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(template.tags.prefix(4), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.kilnAccent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.kilnAccentMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kilnSurface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kilnBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture { onUse() }
        .help("Create a session from this template")
    }
}

private struct TemplateEditor: View {
    @State var template: SessionTemplate
    let isNew: Bool
    let onSave: (SessionTemplate) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Template" : "Edit Template")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.kilnText)

            labelled("Name") {
                TextField("Template name", text: $template.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(8)
                    .background(Color.kilnSurface)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 10) {
                labelled("Icon") {
                    TextField("SF Symbol", text: $template.icon)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .background(Color.kilnSurface)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                labelled("Kind") {
                    Picker("", selection: $template.kind) {
                        Text("Code").tag("code")
                        Text("Chat").tag("chat")
                    }
                    .pickerStyle(.segmented)
                }
            }

            labelled("Model") {
                Picker("", selection: $template.model) {
                    ForEach(ClaudeModel.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            HStack(spacing: 10) {
                labelled("Mode") {
                    Picker("", selection: Binding(
                        get: { template.mode ?? "" },
                        set: { template.mode = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("(default)").tag("")
                        Text("build").tag("build")
                        Text("plan").tag("plan")
                    }
                    .pickerStyle(.segmented)
                }
                labelled("Perms") {
                    Picker("", selection: Binding(
                        get: { template.permissions ?? "" },
                        set: { template.permissions = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("(default)").tag("")
                        Text("bypass").tag("bypass")
                        Text("ask").tag("ask")
                        Text("deny").tag("deny")
                    }
                    .pickerStyle(.segmented)
                }
            }

            labelled("Session instructions (optional)") {
                TextEditor(text: $template.sessionInstructions)
                    .font(.system(size: 11))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 80)
                    .background(Color.kilnSurface)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        onDelete(); dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.kilnError)
                    .font(.system(size: 11, weight: .medium))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .keyboardShortcut(.cancelAction)
                Button {
                    onSave(template); dismiss()
                } label: {
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.kilnBg)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.kilnAccent)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .keyboardShortcut(.defaultAction)
                .disabled(template.name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Color.kilnBg)
    }

    @ViewBuilder
    private func labelled<Content: View>(_ text: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.kilnTextTertiary)
                .tracking(0.5)
            content()
        }
    }
}
