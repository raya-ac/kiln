import AppKit
import SwiftUI

struct AccountSettingsView: View {
    @ObservedObject var account: KilnAccountService = .shared
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var avatars: AvatarStore = .shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: AuthMode = .signIn
    @State private var handle = ""
    @State private var displayName = ""
    @State private var bio = ""
    @State private var location = ""
    @State private var website = ""
    @State private var accent = ""
    @State private var password = ""
    @State private var newPassword = ""
    @State private var passwordConfirmation = ""
    @State private var recoveryCode = ""
    @State private var confirmSharing = false
    @State private var confirmPublicUsage = false
    @State private var confirmChatSharing = false
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
                    readmes
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
            await account.refreshReadmes()
        }
        .onChange(of: account.account) { _, _ in syncProfile() }
        .onChange(of: mode) { _, _ in clearSecrets(); account.clearError(); savedMessage = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await account.refresh()
                    await account.flushOutbox()
                    await account.refreshHistory()
                    await account.refreshReadmes()
                }
            }
        }
        .onDisappear { clearSecrets() }
        .confirmationDialog("Share private token usage with your Kiln account?", isPresented: $confirmSharing) {
            Button("Enable usage sharing") { Task { await account.setShareUsage(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only future measured token counts, provider and model identifiers, opaque event/session IDs, and timestamps are sent. No conversations, names, file paths, or API keys. Usage stays private to your account. Turning this off discards unsent events; already shared history remains private.")
        }
        .confirmationDialog("Show measured usage on your public profile?", isPresented: $confirmPublicUsage) {
            Button("Show usage publicly") { Task { await account.setPublicUsage(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Aggregate token counts and model names become visible at kiln.raya.ac/u/\(account.account?.handle ?? ""). No conversations, file paths, or credentials are shown. You can turn this off at any time.")
        }
        .confirmationDialog("Share chats from the start?", isPresented: $confirmChatSharing) {
            Button("Enable") { Task { await account.setChatSharingDefault(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only defaults the share choice on; every chat still needs an explicit share. Sharing uploads the chat to kiln.raya.ac and grants Kiln access to it for Ash's training.")
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
            field("Photo") { profilePhoto(identity) }
            field("Handle") { Text("@\(identity.handle)").textSelection(.enabled) }
            field("Display name") { TextField("Display name", text: $displayName) }
            field("Bio") { TextField("Bio", text: $bio, axis: .vertical).lineLimit(2...5) }
            field("Location") { TextField("Optional", text: $location) }
            field("Website") { TextField("https://", text: $website) }
            field("Accent") { accentPicker }
            HStack {
                if let url = identity.publicProfileURL {
                    Link(destination: url) { Label("kiln.raya.ac/u/\(identity.handle)", systemImage: "arrow.up.right") }
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Save profile") {
                    Task {
                        if await account.updateProfile(displayName: displayName, bio: bio, location: location,
                                                       website: website, accent: accent) {
                            savedMessage = "Profile saved."
                        }
                    }
                }
                .disabled(account.isLoading || !validProfile)
            }
        }
    }

    @ViewBuilder private func profilePhoto(_ identity: KilnAccount) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Color.kilnSurfaceElevated).frame(width: 44, height: 44)
                if let url = identity.avatarURL.flatMap(URL.init(string:)) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ProgressView().controlSize(.small)
                    }
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 7))
                } else if let img = avatars.avatar {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Image(systemName: "person.fill").foregroundStyle(Color.kilnTextSecondary)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.kilnBorder, lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Button("Upload my Kiln photo") { Task { await uploadAppAvatar() } }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.kilnAccent)
                    .disabled(account.isLoading || avatars.avatar == nil)
                if identity.avatarURL != nil {
                    Button("Remove photo", role: .destructive) {
                        Task { if await account.clearAvatar() { savedMessage = "Profile photo removed." } }
                    }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.kilnError).disabled(account.isLoading)
                }
            }
            Spacer(minLength: 8)
        }
    }

    private var accentPicker: some View {
        HStack(spacing: 8) {
            ForEach(Self.profileAccents, id: \.0) { hex, name in
                Button {
                    applyAccent(hex)
                } label: {
                    Circle().fill(Color(hexString: hex)).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(accent.lowercased() == "#" + hex.lowercased() ? Color.kilnText : Color.kilnBorder, lineWidth: 2))
                }
                .buttonStyle(.plain).help(name)
            }
            Button("Match app accent") { applyAccent(store.settings.accentHex) }
                .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.kilnAccent)
            Spacer(minLength: 4)
        }
    }

    private static let profileAccents: [(String, String)] = [
        ("f97316", "Orange"), ("ef4444", "Red"), ("eab308", "Yellow"), ("22c55e", "Green"),
        ("3b82f6", "Blue"), ("a855f7", "Purple"), ("ec4899", "Pink"), ("14b8a6", "Teal"), ("64748b", "Slate"),
    ]

    private func applyAccent(_ hex: String) {
        let clean = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        accent = "#" + clean.lowercased()
        Task {
            if await account.updateProfile(displayName: displayName, bio: bio, location: location,
                                           website: website, accent: accent) {
                savedMessage = "Accent updated."
            }
        }
    }

    private func uploadAppAvatar() async {
        guard let image = avatars.avatar, let (data, mediaType) = Self.encodedAvatar(image) else {
            savedMessage = "Choose a Kiln photo in Appearance first."
            return
        }
        if await account.uploadAvatar(data, mediaType: mediaType) {
            savedMessage = "Profile photo updated."
        }
    }

    private static func encodedAvatar(_ image: NSImage) -> (Data, String)? {
        let maxSide: CGFloat = 512
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = NSSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let scaled = NSImage(size: target)
        scaled.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        scaled.unlockFocus()
        guard let tiff = scaled.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]), jpeg.count <= 524_288 {
            return (jpeg, "image/jpeg")
        }
        if let png = rep.representation(using: .png, properties: [:]), png.count <= 524_288 {
            return (png, "image/png")
        }
        if let small = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) {
            return (small, "image/jpeg")
        }
        return nil
    }

    private var sharing: some View {
        section("Usage") {
            Toggle("Share usage with this account", isOn: Binding(
                get: { account.shareUsageEnabled },
                set: { enabled in
                    if enabled { confirmSharing = true }
                    else { Task { await account.setShareUsage(false) } }
                }
            ))
            .toggleStyle(.switch).controlSize(.small).disabled(account.isLoading)
            Toggle("Show my usage publicly on my profile", isOn: Binding(
                get: { account.account?.publicUsageEnabled == true },
                set: { enabled in
                    if enabled { confirmPublicUsage = true }
                    else { Task { await account.setPublicUsage(false) } }
                }
            ))
            .toggleStyle(.switch).controlSize(.small).disabled(account.isLoading)
            Text("Private reporting and public display are separate choices. Turning off display never deletes history.")
                .foregroundStyle(Color.kilnTextTertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(account.shareUsageEnabled ? "Reporting enabled" : "Reporting off", systemImage: "lock")
                Spacer()
                if account.isSyncing { ProgressView().controlSize(.small).accessibilityLabel("Syncing usage") }
                Text("\(account.pendingCount) pending").monospacedDigit()
            }
            .foregroundStyle(Color.kilnTextSecondary)
        }
    }

    private var readmes: some View {
        section("Shared READMEs") {
            Toggle("Share chats from the start", isOn: Binding(
                get: { account.chatSharingDefault },
                set: { enabled in
                    if enabled { confirmChatSharing = true }
                    else { Task { await account.setChatSharingDefault(false) } }
                }
            ))
            .toggleStyle(.switch).controlSize(.small).disabled(account.isLoading)
            Text("A default only — every chat still needs an explicit share. Sharing uploads the chat to kiln.raya.ac and grants Kiln access to it for Ash's training.")
                .foregroundStyle(Color.kilnTextTertiary).fixedSize(horizontal: false, vertical: true)
            if account.readmes.isEmpty {
                Text("No shared chats.").foregroundStyle(Color.kilnTextSecondary)
            }
            ForEach(account.readmes) { readme in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(readme.title).fontWeight(.medium).lineLimit(1).help(readme.title)
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { readme.enabled },
                            set: { value in Task { await account.setReadme(readme.id, enabled: value) } }
                        ))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(account.isLoading)
                    }
                    HStack(spacing: 12) {
                        Button("Copy link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(readme.url, forType: .string)
                        }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.kilnAccent)
                        if let url = URL(string: readme.url) {
                            Link("Open", destination: url).font(.system(size: 10, weight: .medium))
                        }
                        Button("Delete", role: .destructive) { Task { await account.deleteReadme(readme.id) } }
                            .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.kilnError)
                        Spacer()
                        Text(readme.enabled ? "public" : "disabled")
                            .font(.system(size: 10)).foregroundStyle(Color.kilnTextTertiary)
                    }
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
    }

    private var usage: some View {
        section("Usage history") {
            if account.isLoadingHistory && account.history.isEmpty {
                ProgressView("Loading usage...").controlSize(.small)
            } else if let totals = account.aggregate {
                Text("\(totals.eventCount.formatted()) measured events").foregroundStyle(Color.kilnTextSecondary)
                if let spend = totals.estimatedSpend {
                    HStack {
                        Text("Est. spend").frame(minWidth: 105, alignment: .leading)
                        Text(spend, format: .currency(code: "USD")).monospacedDigit()
                        Spacer(minLength: 8)
                        if let unpriced = totals.unpricedModels, unpriced > 0 {
                            Text("\(unpriced) unpriced").foregroundStyle(Color.kilnTextTertiary)
                        }
                    }
                }
                if let noncached = totals.noncachedSpend {
                    HStack {
                        Text("Non-cached").frame(minWidth: 105, alignment: .leading)
                        Text(noncached, format: .currency(code: "USD")).monospacedDigit()
                        Spacer(minLength: 8)
                    }
                }
                if let cached = totals.cachedSpend {
                    HStack {
                        Text("Cached").frame(minWidth: 105, alignment: .leading)
                        Text(cached, format: .currency(code: "USD")).monospacedDigit()
                        Spacer(minLength: 8)
                    }
                }
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
            location = identity.location ?? ""
            website = identity.website ?? ""
            accent = identity.accent ?? ""
        } else {
            handle = ""; displayName = ""; bio = ""; location = ""; website = ""; accent = ""; savedMessage = nil
        }
    }

    private var validProfile: Bool {
        !displayName.isEmpty && displayName.count <= 80 && bio.count <= 500
            && location.count <= 80 && website.count <= 200
            && (website.isEmpty || website.lowercased().hasPrefix("http://") || website.lowercased().hasPrefix("https://"))
    }

    private func clearSecrets() { password = ""; newPassword = ""; passwordConfirmation = ""; recoveryCode = "" }
}
