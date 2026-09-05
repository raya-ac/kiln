import Foundation

enum RichEmbedDocument {
    static func html(for link: RichLink, dark: Bool) -> String {
        let foreground = dark ? "#eeeeef" : "#202124"
        let background = dark ? "#19191c" : "#ffffff"
        guard let url = link.embedURL else { return "" }
        let source = escape(url.absoluteString)
        // Provider pages retain their cross-origin identity without a script bridge,
        // Kiln cookies, local-file access, or top-level navigation privileges.
        let policy = "default-src 'none'; frame-src https://www.youtube-nocookie.com https://player.vimeo.com https://open.spotify.com https://w.soundcloud.com https://www.tiktok.com; style-src 'unsafe-inline'"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="strict-origin-when-cross-origin"><meta http-equiv="Content-Security-Policy" content="\(escape(policy))"><style>html,body{margin:0;height:100%;background:\(background);color:\(foreground);font:13px system-ui}iframe{width:100%;height:100%;border:0;display:block}</style></head><body><iframe src="\(source)" title="\(escape(link.provider.rawValue))" allow="encrypted-media; fullscreen; picture-in-picture" referrerpolicy="strict-origin-when-cross-origin" sandbox="allow-scripts allow-same-origin allow-popups" allowfullscreen></iframe></body></html>
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
