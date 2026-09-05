import SwiftUI
import MarkdownUI
import AVKit
import PDFKit
import ImageIO

struct MediaMarkdownView: View {
    let text: String
    let workDir: String
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MediaMarkdown.sections(text)) { section in
                if !section.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Markdown(section.markdown, baseURL: URL(fileURLWithPath: workDir, isDirectory: true))
                        .markdownTheme(.kilnScaled(scale))
                        .markdownImageProvider(NoAutomaticImageProvider())
                        .markdownInlineImageProvider(NoAutomaticInlineImageProvider())
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            if let link = RichLink.make(url.absoluteString), link.provider == .twitter {
                                NSWorkspace.shared.open(link.url)
                                return .handled
                            }
                            guard ["http", "https", "file", "mailto", "kiln"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
                            if url.isFileURL, MediaReference.make(source: url.absoluteString)?.kind == .file {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                return .handled
                            }
                            return .systemAction
                        })
                }
                ForEach(section.media) { media in
                    if media.kind == .link, let link = RichLink.make(media.source) { RichLinkView(link: link) }
                    else { InlineMediaView(media: media, workDir: workDir) }
                }
            }
        }
    }
}

private struct NoAutomaticImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View { Image(systemName: "photo").foregroundStyle(Color.kilnTextSecondary) }
}

private struct NoAutomaticInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image { Image(systemName: "photo") }
}

struct InlineMediaView: View {
    let media: MediaReference
    let workDir: String
    @State private var image: NSImage?
    @State private var document: PDFDocument?
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var retry = 0
    @State private var fullscreen = false

    private var url: URL? { media.permittedURL(workDir: workDir) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url {
                switch media.kind {
                case .image:
                    if let image {
                        AnimatedMediaImage(image: image)
                            .frame(maxWidth: .infinity).frame(height: min(320, max(120, image.size.height)))
                            .onTapGesture { fullscreen = true }
                            .accessibilityLabel(media.label)
                    } else { placeholder }
                case .document:
                    if let document { MediaPDFView(document: document).frame(height: 320) }
                    else { placeholder }
                case .audio, .video:
                    if let player, let item = player.currentItem {
                        MediaPlayerView(player: player, audioOnly: media.kind == .audio)
                            .frame(height: media.kind == .audio ? 72 : 280)
                            .onReceive(item.publisher(for: \.status)) { status in
                                if status == .failed { error = "This format could not be played here." }
                            }
                    } else {
                        Button {
                            let player = AVPlayer(url: url)
                            self.player = player
                            player.play()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "play.circle.fill").font(.system(size: 30))
                                Text(media.label).font(.system(size: 13)).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(16).frame(maxWidth: .infinity)
                            .frame(height: media.kind == .audio ? 72 : 180)
                            .background(Color.kilnSurface)
                        }.buttonStyle(.plain).help("Play " + media.label)
                    }
                case .file, .link:
                    Label(media.label, systemImage: media.kind.symbol).font(.system(size: 12))
                }
            } else {
                Label("Preview unavailable outside this workspace", systemImage: media.kind.symbol)
                    .font(.system(size: 12)).foregroundStyle(Color.kilnTextSecondary)
            }
            HStack(spacing: 8) {
                Text(error ?? media.label).font(.system(size: 11)).foregroundStyle(Color.kilnTextSecondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if error != nil && (media.kind == .image || media.kind == .document) {
                    WorkspaceIconButton(icon: "arrow.clockwise", label: "Retry media") { retry += 1 }
                }
                if let destination = media.url(workDir: workDir) {
                    if media.kind == .file && destination.isFileURL {
                        WorkspaceIconButton(icon: "folder", label: "Show file in Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                    } else {
                        WorkspaceIconButton(icon: "arrow.up.right.square", label: "Open media") { NSWorkspace.shared.open(destination) }
                    }
                }
                if image != nil {
                    WorkspaceIconButton(icon: "arrow.up.left.and.arrow.down.right", label: "Expand image") { fullscreen = true }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: media.id + String(retry)) { await loadPreview() }
        .onDisappear { player?.pause(); player = nil }
        .sheet(isPresented: $fullscreen) {
            VStack(spacing: 12) {
                HStack { Text(media.label).lineLimit(1); Spacer(); Button("Done") { fullscreen = false } }
                if let image { AnimatedMediaImage(image: image).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.padding(20).frame(minWidth: 640, minHeight: 480)
        }
    }

    private var placeholder: some View {
        Group {
            if error != nil { Image(systemName: media.kind.symbol).font(.system(size: 28)).foregroundStyle(Color.kilnTextTertiary) }
            else { ProgressView().controlSize(.small) }
        }.frame(maxWidth: .infinity).frame(height: 120).background(Color.kilnSurface)
    }

    @MainActor private func loadPreview() async {
        guard let url, media.kind == .image || media.kind == .document else { return }
        error = nil
        do {
            let data = try await MediaDataLoader.shared.data(for: url, reload: retry > 0)
            try Task.checkCancellation()
            if media.kind == .document {
                guard let document = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                self.document = document
            } else {
                let prepared = try await Task.detached(priority: .userInitiated) { try MediaImageDecoder.prepare(data) }.value
                try Task.checkCancellation()
                guard let image = NSImage(data: prepared) else { throw CocoaError(.fileReadCorruptFile) }
                self.image = image
            }
        } catch is CancellationError { }
        catch { self.error = "Preview unavailable. Open the media to view it in another app." }
    }
}

enum MediaImageDecoder {
    static func prepare(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let frames = CGImageSourceGetCount(source)
        guard let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, frames > 0, frames <= 1000,
              width <= (frames > 1 ? 16_000_000 : 80_000_000) / height / frames else { throw CocoaError(.fileReadTooLarge) }
        if frames > 1 { return data }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw CocoaError(.fileReadCorruptFile) }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileReadCorruptFile) }
        return output as Data
    }
}

private struct AnimatedMediaImage: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let view = FlexibleImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) { view.image = image }

    private final class FlexibleImageView: NSImageView {
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    }
}

private struct MediaPDFView: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}

private struct MediaPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let audioOnly: Bool
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = !audioOnly
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}

actor MediaDataLoader {
    static let shared = MediaDataLoader()
    private let cache = NSCache<NSURL, NSData>()
    private let session: URLSession
    private let limit = 32 * 1024 * 1024

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        session = URLSession(configuration: config)
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 24
    }

    func data(for url: URL, reload: Bool = false) async throws -> Data {
        if !url.isFileURL, !reload, let cached = cache.object(forKey: url as NSURL) { return cached as Data }
        let data: Data
        if url.isFileURL {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { throw CocoaError(.fileReadTooLarge) }
            data = try Data(contentsOf: url)
        } else {
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), response.expectedContentLength <= limit else { throw URLError(.badServerResponse) }
            var buffer = Data()
            for try await byte in bytes {
                guard buffer.count < limit else { throw CocoaError(.fileReadTooLarge) }
                buffer.append(byte)
            }
            data = buffer
        }
        cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        return data
    }
}
