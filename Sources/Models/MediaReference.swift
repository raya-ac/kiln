import Foundation
import UniformTypeIdentifiers
import CryptoKit
import cmark_gfm
import cmark_gfm_extensions

enum MediaKind: String, Codable, Sendable {
    case image, video, audio, document, file, link
    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .document: "doc.richtext"
        case .file: "doc"
        case .link: "link"
        }
    }
}

struct MediaReference: Identifiable, Equatable, Sendable {
    let source: String
    let label: String
    let kind: MediaKind
    var id: String { SHA256.hash(data: Data((kind.rawValue + source).utf8)).map { String(format: "%02x", $0) }.joined() }

    static func make(source: String, label: String = "", imageSyntax: Bool = false) -> Self? {
        guard !source.isEmpty, source.utf8.count < 16_384 else { return nil }
        let scheme = URL(string: source)?.scheme?.lowercased()
        guard scheme == nil || ["https", "http", "file", "sandbox"].contains(scheme!) else { return nil }
        if let link = RichLink.make(source) {
            return Self(source: link.url.absoluteString, label: label.isEmpty ? link.provider.rawValue : label, kind: .link)
        }
        let ext = (URL(string: source)?.pathExtension ?? (source as NSString).pathExtension).lowercased()
        let kind: MediaKind
        if ["mp4", "m4v", "mov", "webm", "mkv", "avi", "mpeg", "mpg", "ogv", "m3u8"].contains(ext) { kind = .video }
        else if ["mp3", "wav", "m4a", "aac", "ogg", "oga", "opus", "flac", "aiff", "aif", "caf"].contains(ext) { kind = .audio }
        else if ext == "pdf" { kind = .document }
        else if ["png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "heif", "tif", "tiff", "bmp", "svg", "ico"].contains(ext) || imageSyntax { kind = .image }
        else if (scheme == nil || scheme == "file" || scheme == "sandbox") && !ext.isEmpty { kind = .file }
        else { return nil }
        let name = label.isEmpty ? (URL(string: source)?.lastPathComponent ?? (source as NSString).lastPathComponent) : label
        return Self(source: source, label: name.isEmpty ? kind.rawValue.capitalized : name, kind: kind)
    }

    func url(workDir: String) -> URL? {
        let raw = source.hasPrefix("sandbox:") ? String(source.dropFirst(8)) : source
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased() {
            guard ["http", "https", "file"].contains(scheme), url.user == nil, url.password == nil else { return nil }
            if url.isFileURL, let host = url.host, !host.isEmpty && host != "localhost" { return nil }
            return url
        }
        let path = (raw as NSString).expandingTildeInPath.removingPercentEncoding ?? raw
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: workDir, isDirectory: true).appendingPathComponent(path).standardizedFileURL
    }

    func permittedURL(workDir: String, attachmentsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.kiln/attachments")) -> URL? {
        guard let url = url(workDir: workDir) else { return nil }
        guard url.isFileURL else { return url }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let roots = [URL(fileURLWithPath: workDir), attachmentsDirectory].map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        guard roots.contains(where: { resolved.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { return nil }
        return resolved
    }
}

struct MediaMarkdownSection: Identifiable, Sendable {
    let id: Int
    let markdown: String
    let media: [MediaReference]
}

enum MediaMarkdown {
    private final class Cached: NSObject {
        let sections: [MediaMarkdownSection]
        init(_ sections: [MediaMarkdownSection]) { self.sections = sections }
    }
    private final class Cache: @unchecked Sendable {
        let values = NSCache<NSString, Cached>()
        init() { values.totalCostLimit = 8_000_000; values.countLimit = 100 }
    }
    private static let cache = Cache()
    /// Use the same CommonMark parser as MarkdownUI, so examples inside code
    /// blocks and escaped image syntax are never treated as requests to load media.
    static func sections(_ markdown: String) -> [MediaMarkdownSection] {
        if let saved = cache.values.object(forKey: markdown as NSString) { return saved.sections }
        guard markdown.utf8.count <= 2_000_000, let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else {
            return [.init(id: 0, markdown: markdown, media: [])]
        }
        defer { cmark_parser_free(parser) }
        cmark_gfm_core_extensions_ensure_registered()
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let syntax = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, syntax) }
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let root = cmark_parser_finish(parser) else { return [.init(id: 0, markdown: markdown, media: [])] }
        defer { cmark_node_free(root) }
        var sections: [MediaMarkdownSection] = []
        var seen = Set<String>()
        var child = cmark_node_first_child(root)
        while let block = child {
            child = cmark_node_next(block)
            var media: [MediaReference] = []
            collect(block, into: &media, seen: &seen)
            guard let output = cmark_render_commonmark(block, CMARK_OPT_DEFAULT, 0) else { continue }
            let text = String(cString: output)
            free(output)
            sections.append(.init(id: sections.count, markdown: text, media: media))
        }
        if sections.allSatisfy({ $0.media.isEmpty }) { sections = [.init(id: 0, markdown: markdown, media: [])] }
        cache.values.setObject(Cached(sections), forKey: markdown as NSString, cost: markdown.utf8.count)
        return sections
    }

    static func references(_ markdown: String) -> [MediaReference] { sections(markdown).flatMap(\.media) }

    private static func collect(_ node: UnsafeMutablePointer<cmark_node>, into media: inout [MediaReference], seen: inout Set<String>) {
        let type = cmark_node_get_type(node)
        if type == CMARK_NODE_CODE_BLOCK || type == CMARK_NODE_CODE { return }
        if type == CMARK_NODE_IMAGE || type == CMARK_NODE_LINK,
           let raw = cmark_node_get_url(node) {
            let source = String(cString: raw)
            let label = cmark_node_first_child(node).flatMap { cmark_node_get_literal($0) }.map(String.init(cString:)) ?? ""
            if let reference = MediaReference.make(source: source, label: label, imageSyntax: type == CMARK_NODE_IMAGE), seen.insert(reference.id).inserted {
                media.append(reference)
            }
            if type == CMARK_NODE_IMAGE, let link = cmark_node_new(CMARK_NODE_LINK) {
                cmark_node_set_url(link, source)
                while let child = cmark_node_first_child(node) { cmark_node_unlink(child); cmark_node_append_child(link, child) }
                cmark_node_replace(node, link)
                cmark_node_free(node)
            }
            return
        }
        if type == CMARK_NODE_TEXT, let literal = cmark_node_get_literal(node),
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let text = String(cString: literal)
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url, let reference = MediaReference.make(source: url.absoluteString), seen.insert(reference.id).inserted { media.append(reference) }
            }
        }
        var child = cmark_node_first_child(node)
        while let current = child { child = cmark_node_next(current); collect(current, into: &media, seen: &seen) }
    }
}
