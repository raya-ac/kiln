import SwiftUI

struct AccountSettingsView: View {
    @ObservedObject var account: KilnAccountService = .shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: AuthMode = .signIn
    @State private var handle = ""
    @State private var displayName = ""
    @State private var bio = ""
    @State private var password = ""
    @State private var newPassword = ""
    @State private var passwordConfirmation = ""
    @State private var recoveryCode = ""
    @State private var confirmSharing = false
    @State private var confirmSignOut = false
    @State private var savedMessage: String?

    private enum AuthMode: String, CaseIterable, Identifiable {
        case signIn = "Sign in", register = "Register", recover = "Recover"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                status
                if !account.recoveryCodes.isEmpty { recoveryCodes }
                if let identity = account.account {
                    profile(identity)
                    sharing
                    usage
                    security
                } else if account.hasStoredSession {
                    message("Your saved session needs an online check before account access resumes.")
                    Button("Sign out on this Mac", role: .destructive) { confirmSignOut = true }
                        .disabled(account.isLoading)
                } else {
                    authentication
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .font(.system(size: 12))
        .textFieldStyle(.roundedBorder)
        .foregroundStyle(Color.kilnText)
        .task {
            syncProfile()
            await account.refreshHistory()
        }
        .onChange(of: account.account) { _, _ in syncProfile() }
        .onChange(of: mode) { _, _ in clearSecrets(); account.clearError(); savedMessage = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await account.refresh(); await account.flushOutbox(); await account.refreshHistory() }
            }
        }
        .onDisappear { clearSecrets() }
        .confirmationDialog("Share private token usage with your Kiln account?", isPresented: $confirmSharing) {
            Button("Enable usage sharing") { Task { await account.setShareUsage(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only future measured token counts, provider and model identifiers, opaque event/session IDs, and timestamps are sent. No conversations, names, file paths, or API keys. Usage stays private to your account. Turning this off discards unsent events; already shared history remains private.")
        }
        .confirmationDialog("Sign out of Kiln?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) {
                clearSecrets()
                Task { await account.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsent usage is discarded and sharing is disabled on this Mac. Your private server history is retained.")
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(account.account == nil ? "Kiln account" : "Signed in as @\(account.account!.handle)",
                      systemImage: "person.crop.circle")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                if account.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Loading account") }
                Button {
                    Task { await account.refresh(); await account.flushOutbox(); await account.refreshHistory() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh account and retry pending usage").accessibilityLabel("Refresh account")
                    .disabled(account.isLoading)
            }
            if let error = account.errorMessage { message(error, error: true) }
            if let error = account.syncError { message(error, error: true) }
            if let savedMessage { message(savedMessage) }
        }
    }

    private var authentication: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Account action", selection: $mode) {
                ForEach(AuthMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            field("Handle") { TextField("Handle", text: $handle).textContentType(.username) }
            if mode == .register {
                field("Display name") { TextField("Display name", text: $displayName) }
            }
            if mode == .recover {
                field("Recovery code") { SecureField("Recovery code", text: $recoveryCode) }
                field("New password") { SecureField("12 to 128 bytes", text: $newPassword).textContentType(.newPassword) }
            } else {
                field("Password") {
                    SecureField(mode == .register ? "12 to 128 bytes" : "Password", text: $password)
                        .textContentType(mode == .register ? .newPassword : .password)
                }
            }
            if mode != .signIn {
                field("Confirm password") { SecureField("Repeat password", text: $passwordConfirmation) }
                if !passwordConfirmation.isEmpty && passwordConfirmation != (mode == .recover ? newPassword : password) {
                    message("Passwords do not match.", error: true)
                }
            }
            HStack {
                Spacer()
                Button(mode.rawValue) { submitAuthentication() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!validAuthentication || account.isLoading)
            }
        }
    }

    private func profile(_ identity: KilnAccount) -> some View {
        section("Public profile") {
            field("Handle") { Text("@\(identity.handle)").textSelection(.enabled) }
            field("Display name") { TextField("Display name", text: $displayName) }
            field("Bio") { TextField("Bio", text: $bio, axis: .vertical).lineLimit(2...5) }
            HStack {
                if let url = identity.publicProfileURL {
                    Link(destination: url) { Label("kiln.raya.ac/u/\(identity.handle)", systemImage: "arrow.up.right") }
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Save profile") {
                    Task {
                        if await account.updateProfile(displayName: displayName, bio: bio) {
                            savedMessage = "Profile saved."
                        }
                    }
                }
                .disabled(account.isLoading || displayName.isEmpty || displayName.count > 80 || bio.count > 500)
            }
        }
    }

    private var sharing: some View {
        section("Private usage") {
            Toggle("Share usage with this account", isOn: Binding(
                get: { account.shareUsageEnabled },
                set: { enabled in
                    if enabled { confirmSharing = true }
                    else { Task { await account.setShareUsage(false) } }
                }
            ))
            .toggleStyle(.switch).controlSize(.small).disabled(account.isLoading)
            HStack {
                Label(account.shareUsageEnabled ? "Sharing enabled" : "Sharing off", systemImage: "lock")
                Spacer()
                if account.isSyncing { ProgressView().controlSize(.small).accessibilityLabel("Syncing usage") }
                Text("\(account.pendingCount) pending").monospacedDigit()
            }
            .foregroundStyle(Color.kilnTextSecondary)
        }
    }

    private var usage: some View {
        section("Usage history") {
            if account.isLoadingHistory && account.history.isEmpty {
                ProgressView("Loading usage...").controlSize(.small)
            } else if let totals = account.aggregate {
                Text("\(totals.eventCount.formatted()) measured events").foregroundStyle(Color.kilnTextSecondary)
                aggregateRow("Input", totals.counts.inputTokens)
                aggregateRow("Output", totals.counts.outputTokens)
                aggregateRow("Cached input", totals.counts.cachedInputTokens)
                aggregateRow("Reasoning output", totals.counts.reasoningOutputTokens)
            }
            if !account.isLoadingHistory && account.history.isEmpty {
                Text("No shared usage yet.").foregroundStyle(Color.kilnTextSecondary)
            }
            ForEach(account.history) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.model).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(entry.provider).foregroundStyle(Color.kilnTextSecondary)
                    }
                    Text(entry.timestamp).font(.system(size: 10)).foregroundStyle(Color.kilnTextTertiary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) { eventCounts(entry) }
                        VStack(alignment: .leading, spacing: 4) { eventCounts(entry) }
                    }
                    .font(.system(size: 11)).foregroundStyle(Color.kilnTextSecondary)
                }
                .padding(.vertical, 6)
                Divider()
            }
            if account.nextHistoryCursor != nil {
                Button("Load more") { Task { await account.refreshHistory(loadMore: true) } }
                    .disabled(account.isLoadingHistory)
            }
        }
    }

    @ViewBuilder private func eventCounts(_ entry: KilnUsageHistoryEntry) -> some View {
        Text("In: \(count(entry.inputTokens))")
        Text("Out: \(count(entry.outputTokens))")
        Text("Cached: \(count(entry.cachedInputTokens))")
        Text("Reasoning: \(count(entry.reasoningOutputTokens))")
    }

    private var security: some View {
        section("Security") {
            field("Current password") { SecureField("Current password", text: $password).textContentType(.password) }
            field("New password") { SecureField("12 to 128 bytes", text: $newPassword).textContentType(.newPassword) }
            field("Confirm password") { SecureField("Repeat new password", text: $passwordConfirmation) }
            HStack {
                Button("Sign out", role: .destructive) { confirmSignOut = true }
                    .disabled(account.isLoading)
                Spacer()
                Button("Change password") {
                    let current = password
                    let replacement = newPassword
                    clearSecrets()
                    Task {
                        if await account.changePassword(currentPassword: current, newPassword: replacement) {
                            savedMessage = "Password changed. Other sessions have been signed out."
                        }
                    }
                }
                .disabled(account.isLoading || password.isEmpty || !validNewPassword(newPassword) || newPassword != passwordConfirmation)
            }
        }
    }

    private var recoveryCodes: some View {
        section("Recovery code") {
            ForEach(account.recoveryCodes, id: \.self) { code in
                Text(code).font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled).privacySensitive().fixedSize(horizontal: false, vertical: true)
            }
            Text("Keep this code somewhere private. It is shown only once and replaces any earlier recovery code.")
                .foregroundStyle(Color.kilnTextSecondary).fixedSize(horizontal: false, vertical: true)
            Button("I saved my recovery code") { account.dismissRecoveryCodes() }
        }
    }

    private func aggregateRow(_ title: String, _ value: KilnTokenAggregate) -> some View {
        HStack {
            Text(title).frame(minWidth: 105, alignment: .leading)
            Text(value.formattedTotal).monospacedDigit()
            Spacer(minLength: 8)
            if value.unknownEvents > 0 {
                Text("\(value.unknownEvents.formatted()) unknown").foregroundStyle(Color.kilnTextTertiary)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.kilnTextTertiary)
            content()
            Divider().padding(.top, 8)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).foregroundStyle(Color.kilnTextSecondary)
            content()
        }
    }

    private func message(_ text: String, error: Bool = false) -> some View {
        Text(text).foregroundStyle(error ? Color.kilnError : Color.kilnTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var validAuthentication: Bool {
        guard KilnAccount.validHandle(handle) else { return false }
        switch mode {
        case .signIn: return !password.isEmpty
        case .register: return validNewPassword(password) && password == passwordConfirmation && displayName.count <= 80
        case .recover: return !recoveryCode.isEmpty && validNewPassword(newPassword) && newPassword == passwordConfirmation
        }
    }

    private func validNewPassword(_ value: String) -> Bool { value.count >= 12 && value.utf8.count <= 128 }
    private func count(_ value: Int?) -> String { value.map { $0.formatted() } ?? "Unknown" }

    private func submitAuthentication() {
        let password = password
        let newPassword = newPassword
        let recoveryCode = recoveryCode
        let mode = mode
        clearSecrets()
        Task {
            switch mode {
            case .signIn: await account.signIn(handle: handle, password: password)
            case .register: await account.register(handle: handle, password: password, displayName: displayName)
            case .recover: await account.recover(handle: handle, recoveryCode: recoveryCode, newPassword: newPassword)
            }
            await account.refreshHistory()
        }
    }

    private func syncProfile() {
        if let identity = account.account {
            handle = identity.handle
            displayName = identity.displayName
            bio = identity.bio
        } else {
            handle = ""; displayName = ""; bio = ""; savedMessage = nil
        }
    }

    private func clearSecrets() { password = ""; newPassword = ""; passwordConfirmation = ""; recoveryCode = "" }
}
