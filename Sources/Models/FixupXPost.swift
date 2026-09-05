import Foundation

struct FixupXPost: Codable, Sendable {
    let text: String
    let author: String
    let handle: String
    let timestamp: Double?
    let media: [PostMedia]
    let quote: Quote?

    struct PostMedia: Codable, Sendable, Identifiable {
        let url: String
        let kind: MediaKind
        var id: String { url }
        var reference: MediaReference { .init(source: url, label: kind == .image ? "Post image" : "Post video", kind: kind) }
    }

    struct Quote: Codable, Sendable {
        let text: String
        let author: String
        let handle: String
        let media: [PostMedia]
    }

    static func decode(_ data: Data, expectedID: String) throws -> Self {
        struct Author: Decodable { let name: String?; let screen_name: String? }
        struct Medium: Decodable { let type: String; let url: String }
        struct Media: Decodable { let all: [Medium]? }
        final class Status: Decodable {
            let type: String
            let id: String?
            let text: String?
            let author: Author?
            let created_timestamp: Double?
            let media: Media?
            let quote: Status?
        }
        struct Response: Decodable { let code: Int; let status: Status? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.code == 200, let post = response.status, post.type == "status", post.id == expectedID, let text = post.text else { throw URLError(.resourceUnavailable) }
        func media(_ value: Media?) -> [PostMedia] {
            var seen = Set<String>()
            return (value?.all ?? []).prefix(8).compactMap { item in
                guard let url = URL(string: item.url), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
                      let host = url.host?.lowercased(), host == "twimg.com" || host.hasSuffix(".twimg.com"), seen.insert(url.absoluteString).inserted else { return nil }
                let kind: MediaKind
                switch item.type { case "photo": kind = .image; case "video", "gif": kind = .video; default: return nil }
                return PostMedia(url: url.absoluteString, kind: kind)
            }
        }
        let quote = post.quote.flatMap { q -> Quote? in
            guard q.type == "status", let text = q.text else { return nil }
            return Quote(text: String(text.prefix(20_000)), author: String((q.author?.name ?? "").prefix(200)), handle: String((q.author?.screen_name ?? "").prefix(100)), media: media(q.media))
        }
        let timestamp = post.created_timestamp.flatMap { $0.isFinite && (-62_135_596_800...253_402_300_799).contains($0) ? $0 : nil }
        return Self(text: String(text.prefix(20_000)), author: String((post.author?.name ?? "").prefix(200)), handle: String((post.author?.screen_name ?? "").prefix(100)), timestamp: timestamp, media: media(post.media), quote: quote)
    }
}
