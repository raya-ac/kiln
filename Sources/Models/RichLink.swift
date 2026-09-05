import Foundation

enum LinkProvider: String, Codable, Sendable {
    case youtube = "YouTube", twitter = "Twitter / X", vimeo = "Vimeo"
    case spotify = "Spotify", soundcloud = "SoundCloud", tiktok = "TikTok"
}

struct RichLink: Equatable, Sendable {
    let provider: LinkProvider
    let url: URL
    let contentID: String
    var start = 0

    static func make(_ source: String) -> Self? {
        guard source.utf8.count < 4096, let url = URL(string: source),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        func valid(_ id: String, _ allowed: String, _ range: ClosedRange<Int>) -> Bool {
            range.contains(id.utf8.count) && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: allowed).contains($0) }
        }
        let digits = "0123456789", alphanumeric = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be", "www.youtube-nocookie.com"].contains(host) {
            let id: String?
            if host.hasSuffix("youtu.be") { id = path.first }
            else if path == ["watch"] { id = value("v") }
            else if path.count == 2, ["shorts", "live", "embed"].contains(path[0]) { id = path[1] }
            else { id = nil }
            guard let id, valid(id, alphanumeric + "-_", 11...11) else { return nil }
            let start = timestamp(value("t") ?? value("start") ?? "")
            return .init(provider: .youtube, url: URL(string: "https://www.youtube.com/watch?v=\(id)" + (start > 0 ? "&t=\(start)" : ""))!, contentID: id, start: start)
        }
        if ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com", "mobile.x.com", "fixupx.com", "www.fixupx.com", "fxtwitter.com", "www.fxtwitter.com"].contains(host),
           path.count >= 3, path[1] == "status" || (path.count >= 4 && path[0] == "i" && path[1] == "web" && path[2] == "status") {
            let id = path[path[1] == "status" ? 2 : 3]
            guard valid(id, digits, 2...20) else { return nil }
            return .init(provider: .twitter, url: URL(string: "https://fixupx.com/i/status/\(id)")!, contentID: id)
        }
        if ["vimeo.com", "www.vimeo.com", "player.vimeo.com"].contains(host) {
            let parts = path.first == "video" ? Array(path.dropFirst()) : path
            guard let id = parts.first, valid(id, digits, 1...15), parts.count <= 2 else { return nil }
            let hash = parts.count == 2 ? parts[1] : value("h")
            guard hash == nil || valid(hash!, alphanumeric, 1...64) else { return nil }
            return .init(provider: .vimeo, url: URL(string: "https://vimeo.com/\(id)" + (hash.map { "/" + $0 } ?? ""))!, contentID: id)
        }
        if host == "open.spotify.com" {
            var parts = path
            if parts.first?.hasPrefix("intl-") == true { parts.removeFirst() }
            if parts.first == "embed" { parts.removeFirst() }
            guard parts.count == 2, ["track", "album", "playlist", "episode", "show", "artist"].contains(parts[0]), valid(parts[1], alphanumeric, 22...22) else { return nil }
            let id = parts.joined(separator: "/")
            return .init(provider: .spotify, url: URL(string: "https://open.spotify.com/\(id)")!, contentID: id)
        }
        if ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"].contains(host), (2...3).contains(path.count),
           path.allSatisfy({ valid($0, alphanumeric + "-_", 1...200) }), path.count == 2 || path[1] == "sets" {
            let id = path.joined(separator: "/")
            return .init(provider: .soundcloud, url: URL(string: "https://soundcloud.com/\(id)")!, contentID: id)
        }
        if ["www.tiktok.com", "tiktok.com", "m.tiktok.com"].contains(host), path.count == 3, path[0].hasPrefix("@"), path[1] == "video",
           valid(String(path[0].dropFirst()), alphanumeric + "._", 1...32), valid(path[2], digits, 1...25) {
            return .init(provider: .tiktok, url: URL(string: "https://www.tiktok.com/" + path.joined(separator: "/"))!, contentID: path[2])
        }
        return nil
    }

    private static func timestamp(_ value: String) -> Int {
        if let seconds = Int(value) { return min(86_400, max(0, seconds)) }
        guard let match = value.range(of: "^(?:[0-9]+h)?(?:[0-9]+m)?(?:[0-9]+s)?$", options: .regularExpression), match == value.startIndex..<value.endIndex else { return 0 }
        var total = 0, number = ""
        for char in value {
            if char.isNumber { number.append(char) }
            else { total += min(Int(number) ?? 0, 86_400) * (char == "h" ? 3600 : char == "m" ? 60 : 1); number = "" }
        }
        return min(total, 86_400)
    }

    var height: Int { switch provider { case .twitter, .tiktok: 440; case .spotify: 352; case .soundcloud: 200; default: 300 } }
    var embedURL: URL? {
        switch provider {
        case .youtube: URL(string: "https://www.youtube-nocookie.com/embed/\(contentID)?autoplay=0&start=\(start)")
        case .twitter: nil
        case .vimeo: URL(string: "https://player.vimeo.com/video/\(contentID)?autoplay=0&dnt=1" + (url.pathComponents.count > 2 ? "&h=\(url.lastPathComponent)" : ""))
        case .spotify: URL(string: "https://open.spotify.com/embed/\(contentID)")
        case .soundcloud: Self.endpoint("https://w.soundcloud.com/player/", items: ["url": url.absoluteString, "auto_play": "false"])
        case .tiktok: URL(string: "https://www.tiktok.com/player/v1/\(contentID)?autoplay=0")
        }
    }

    var metadataURL: URL {
        let base: String = switch provider {
        case .youtube: "https://www.youtube.com/oembed"
        case .twitter: "https://api.fxtwitter.com/2/status/\(contentID)"
        case .vimeo: "https://vimeo.com/api/oembed.json"
        case .spotify: "https://open.spotify.com/oembed"
        case .soundcloud: "https://soundcloud.com/oembed"
        case .tiktok: "https://www.tiktok.com/oembed"
        }
        if provider == .twitter { return URL(string: base)! }
        return Self.endpoint(base, items: ["url": url.absoluteString, "format": "json", "omit_script": "true", "dnt": "true"])
    }

    private static func endpoint(_ base: String, items: [String: String]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    var fallback: LinkMetadata {
        .init(title: provider == .twitter ? "Post via FixupX" : provider.rawValue, author: "", thumbnail: provider == .youtube ? "https://i.ytimg.com/vi/\(contentID)/hqdefault.jpg" : nil, unavailable: false)
    }
}

struct LinkMetadata: Codable, Sendable {
    var title: String
    var author: String
    var thumbnail: String?
    var unavailable: Bool
    var post: FixupXPost? = nil

    static func decode(_ data: Data, for link: RichLink) throws -> Self {
        if link.provider == .twitter {
            let post = try FixupXPost.decode(data, expectedID: link.contentID)
            return .init(title: post.handle.isEmpty ? "Post via FixupX" : "@" + post.handle, author: post.author, thumbnail: nil, unavailable: false, post: post)
        }
        struct Response: Decodable { var title: String?; var author_name: String?; var thumbnail_url: String? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        var value = link.fallback
        if let title = response.title, !title.isEmpty { value.title = String(title.prefix(600)) }
        if let author = response.author_name { value.author = String(author.prefix(200)) }
        if let raw = response.thumbnail_url, let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
           let host = url.host?.lowercased(), ["ytimg.com", "vimeocdn.com", "scdn.co", "sndcdn.com", "tiktokcdn.com", "tiktokcdn-us.com", "tiktokcdn-eu.com", "twimg.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            value.thumbnail = raw
        }
        return value
    }
}
