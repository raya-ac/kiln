import SwiftUI
import WebKit

struct RichLinkView: View {
    let link: RichLink
    @Environment(\.colorScheme) private var colorScheme
    @State private var metadata: LinkMetadata?
    @State private var thumbnail: NSImage?
    @State private var expanded = false
    @State private var retry = 0

    private var value: LinkMetadata { metadata ?? link.fallback }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let post = value.post {
                FixupXPostView(post: post).padding(12)
            } else if link.provider == .twitter {
                HStack { if metadata == nil { ProgressView().controlSize(.small) }; Text(metadata == nil ? "Loading post..." : "Post unavailable").font(.system(size: 12)); Spacer() }.padding(12)
            } else if expanded {
                RichEmbedWebView(link: link, dark: colorScheme == .dark)
                    .frame(height: CGFloat(link.height))
            } else {
                Button { expanded = true } label: {
                    ZStack {
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().scaledToFit()
                        } else { Color.kilnSurface }
                        Image(systemName: link.provider == .twitter ? "text.bubble.fill" : "play.circle.fill")
                            .font(.system(size: 36)).foregroundStyle(.white)
                            .padding(10).background(.black.opacity(0.6), in: Circle())
                    }.frame(maxWidth: .infinity).frame(height: link.provider == .twitter ? 100 : 220).clipped()
                }.buttonStyle(.plain).help("Load " + link.provider.rawValue + " embed")
                    .accessibilityLabel("Load " + link.provider.rawValue + " embed")
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(link.provider == .twitter ? "X via fixupx.com" : link.provider.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.kilnTextSecondary)
                    Spacer(minLength: 8)
                    if value.unavailable {
                        WorkspaceIconButton(icon: "arrow.clockwise", label: "Retry link preview") { retry += 1 }
                    }
                    if expanded {
                        WorkspaceIconButton(icon: "xmark", label: "Close embed") { expanded = false }
                    }
                    WorkspaceIconButton(icon: "arrow.up.right.square", label: "Open on " + (link.provider == .twitter ? "FixupX" : link.provider.rawValue)) { NSWorkspace.shared.open(link.url) }
                }
                if value.post == nil { Text(value.title).font(.system(size: 14, weight: .semibold)).lineLimit(3) }
                if value.post == nil && !value.author.isEmpty {
                    Text(value.author).font(.system(size: 12)).foregroundStyle(Color.kilnTextSecondary).lineLimit(2)
                }
                if value.unavailable {
                    Text("Metadata unavailable. The original link is still available.")
                        .font(.system(size: 11)).foregroundStyle(Color.kilnTextSecondary)
                }
            }.padding(12)
        }
        .background(Color.kilnSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.kilnBorder, lineWidth: 1))
        .task(id: link.url.absoluteString + String(retry)) {
            let metadata = await LinkMetadataService.shared.metadata(for: link, refresh: retry > 0)
            guard !Task.isCancelled else { return }
            self.metadata = metadata
            if let raw = metadata.thumbnail, let url = URL(string: raw),
               let data = try? await MediaDataLoader.shared.data(for: url),
               let prepared = try? await Task.detached(priority: .utility, operation: { try MediaImageDecoder.prepare(data) }).value,
               !Task.isCancelled { thumbnail = NSImage(data: prepared) }
        }
        .onDisappear { expanded = false }
    }
}

struct RichEmbedWebView: NSViewRepresentable {
    let link: RichLink
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let key = link.url.absoluteString + String(dark)
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        context.coordinator.loadingDocument = true
        // YouTube requires the installed app's identity as the embedding origin.
        let identity = (Bundle.main.bundleIdentifier ?? "li.raya.kiln").lowercased()
        view.loadHTMLString(RichEmbedDocument.html(for: link, dark: dark), baseURL: URL(string: "https://" + identity))
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var key = ""
        var loadingDocument = false
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if loadingDocument, navigationAction.targetFrame?.isMainFrame == true, navigationAction.navigationType == .other {
                loadingDocument = false
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else if navigationAction.targetFrame?.isMainFrame == true, navigationAction.request.url?.scheme != "about" {
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
               ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}
