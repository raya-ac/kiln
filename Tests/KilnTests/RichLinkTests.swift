import XCTest
import SwiftUI
import WebKit
@testable import Kiln

final class RichLinkTests: XCTestCase {
    func testProviderURLsAndCanonicalization() throws {
        for source in ["https://youtu.be/M7lc1UVf-VE?si=tracking", "https://www.youtube.com/watch?v=M7lc1UVf-VE", "https://www.youtube.com/shorts/M7lc1UVf-VE", "https://www.youtube.com/live/M7lc1UVf-VE"] {
            let link = try XCTUnwrap(RichLink.make(source))
            XCTAssertEqual(link.provider, .youtube)
            XCTAssertEqual(link.url.absoluteString, "https://www.youtube.com/watch?v=M7lc1UVf-VE")
            XCTAssertEqual(link.embedURL?.host, "www.youtube-nocookie.com")
        }
        XCTAssertEqual(RichLink.make("https://youtu.be/M7lc1UVf-VE?t=1m20s")?.start, 80)
        XCTAssertEqual(RichLink.make("https://x.com/Interior/status/463440424141459456?s=20")?.contentID, "463440424141459456")
        XCTAssertEqual(RichLink.make("https://twitter.com/i/web/status/463440424141459456")?.provider, .twitter)
        XCTAssertEqual(RichLink.make("https://vimeo.com/76979871/abcdef")?.embedURL?.query, "autoplay=0&dnt=1&h=abcdef")
        XCTAssertEqual(RichLink.make("https://open.spotify.com/intl-en/track/4uLU6hMCjMI75M1A2tKUQC?si=tracking")?.contentID, "track/4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertEqual(RichLink.make("https://soundcloud.com/artist/sets/album")?.provider, .soundcloud)
        XCTAssertEqual(RichLink.make("https://www.tiktok.com/@scout2015/video/6718335390845095173")?.provider, .tiktok)
    }

    func testUnsafeAndUnsupportedDestinationsDoNotBecomeEmbeds() {
        for source in ["https://youtube.com.evil.test/watch?v=M7lc1UVf-VE", "https://youtube.com@127.0.0.1/watch?v=M7lc1UVf-VE", "https://youtube.com:8443/watch?v=M7lc1UVf-VE", "file:///video", "javascript:alert(1)", "https://x.com/user/status/%27%3Cscript%3E", "https://x.com/user", "https://youtu.be/short", "https://vimeo.com/1234/../../admin", "https://soundcloud.com/oembed?url=http://localhost", "https://open.spotify.com/track/../../admin"] {
            XCTAssertNil(RichLink.make(source), source)
        }
    }

    func testFixupXAliasesAndStructuredPostMedia() throws {
        for host in ["twitter.com", "x.com", "fixupx.com", "fxtwitter.com"] {
            let link = try XCTUnwrap(RichLink.make("https://\(host)/Interior/status/463440424141459456"))
            XCTAssertEqual(link.url.absoluteString, "https://fixupx.com/i/status/463440424141459456")
            XCTAssertEqual(link.metadataURL.host, "api.fxtwitter.com")
        }
        let input: [String: Any] = ["code": 200, "status": ["type": "status", "id": "12345", "text": "<script>plain text</script>", "author": ["name": "A", "screen_name": "a"], "created_timestamp": 1399327782,
            "media": ["all": [["type": "photo", "url": "https://pbs.twimg.com/media/photo.jpg"], ["type": "photo", "url": "https://pbs.twimg.com/media/photo.jpg"], ["type": "video", "url": "https://video.twimg.com/a.mp4"], ["type": "photo", "url": "http://127.0.0.1/private"]]],
            "quote": ["type": "status", "id": "67890", "text": "Quoted text", "author": ["name": "B", "screen_name": "b"]]]]
        let data = try JSONSerialization.data(withJSONObject: input)
        let post = try FixupXPost.decode(data, expectedID: "12345")
        XCTAssertEqual(post.text, "<script>plain text</script>")
        XCTAssertEqual(post.media.map(\.kind), [.image, .video])
        XCTAssertEqual(post.quote?.text, "Quoted text")
        XCTAssertThrowsError(try FixupXPost.decode(data, expectedID: "67890"))
        XCTAssertThrowsError(try FixupXPost.decode(Data(#"{"code":404,"status":null}"#.utf8), expectedID: "12345"))
    }

    func testMarkdownBareLinksCodeAndDeduplication() {
        let source = """
        [Watch](https://youtu.be/M7lc1UVf-VE?si=abc)
        https://www.youtube.com/watch?v=M7lc1UVf-VE
        https://x.com/Interior/status/463440424141459456
        `https://youtu.be/not-a-video`
        ```
        https://www.youtube.com/watch?v=abcdefghijk
        ```
        """
        let refs = MediaMarkdown.references(source)
        XCTAssertEqual(refs.count, 2)
        XCTAssertTrue(refs.allSatisfy { $0.kind == .link })
        XCTAssertEqual(refs.first?.label, "Watch")
    }

    func testMetadataIsDataNotExecutableProviderHTML() throws {
        let link = try XCTUnwrap(RichLink.make("https://youtu.be/M7lc1UVf-VE"))
        let data = Data(#"{"title":"<script>bad</script>","author_name":"Author","thumbnail_url":"http://127.0.0.1/private","html":"<script>doNotExecute()</script>"}"#.utf8)
        let metadata = try LinkMetadata.decode(data, for: link)
        XCTAssertEqual(metadata.title, "<script>bad</script>")
        XCTAssertEqual(metadata.author, "Author")
        XCTAssertEqual(metadata.thumbnail, link.fallback.thumbnail)
        for thumbnail in ["https://i.ytimg.com/vi/test/hqdefault.jpg", "https://i.scdn.co/image/abc"] {
            let data = try JSONSerialization.data(withJSONObject: ["thumbnail_url": thumbnail])
            XCTAssertEqual(try LinkMetadata.decode(data, for: link).thumbnail, thumbnail)
        }
    }

    func testEmbedDocumentsAreIsolatedAndDoNotAutoplay() throws {
        let youtube = try XCTUnwrap(RichLink.make("https://youtu.be/M7lc1UVf-VE"))
        let html = RichEmbedDocument.html(for: youtube, dark: true)
        XCTAssertTrue(html.contains("strict-origin-when-cross-origin"))
        XCTAssertTrue(html.contains("autoplay=0"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertFalse(html.contains("allow-top-navigation"))
        let twitter = try XCTUnwrap(RichLink.make("https://x.com/Interior/status/463440424141459456"))
        let post = RichEmbedDocument.html(for: twitter, dark: true)
        XCTAssertEqual(post, "")
        XCTAssertEqual(twitter.url.host, "fixupx.com")
        XCTAssertEqual(twitter.metadataURL.absoluteString, "https://api.fxtwitter.com/2/status/463440424141459456")
        XCTAssertNil(twitter.embedURL)
    }

    @MainActor func testNativeEmbedHostLoadsWithApplicationOrigin() async throws {
        let link = try XCTUnwrap(RichLink.make("https://youtu.be/M7lc1UVf-VE"))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let blocker = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "kiln-embed-test", encodedContentRuleList: #"[{"trigger":{"url-filter":"https://.*"},"action":{"type":"block"}}]"#)
        if let blocker { config.userContentController.add(blocker) }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), configuration: config)
        let coordinator = RichEmbedWebView.Coordinator()
        coordinator.loadingDocument = true
        view.navigationDelegate = coordinator
        view.loadHTMLString(RichEmbedDocument.html(for: link, dark: true), baseURL: URL(string: "https://li.raya.kiln"))
        var source: String?
        for _ in 0..<60 {
            source = try? await view.evaluateJavaScript("document.querySelector('iframe')?.src") as? String
            if source != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(source, link.embedURL?.absoluteString)
        let origin = try await view.evaluateJavaScript("document.baseURI") as? String
        XCTAssertEqual(origin, "https://li.raya.kiln/")
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
        view.stopLoading()
    }

    @MainActor func testLiveNativeEmbedSnapshotWhenRequested() async throws {
        guard let output = ProcessInfo.processInfo.environment["KILN_LIVE_EMBED_OUTPUT"] else { throw XCTSkip("Opt-in native provider screenshot") }
        _ = NSApplication.shared
        let link = try XCTUnwrap(RichLink.make("https://x.com/Interior/status/463440424141459456"))
        let metadata = await LinkMetadataService.shared.metadata(for: link)
        let post = try XCTUnwrap(metadata.post)
        let host = NSHostingView(rootView: FixupXPostView(post: post).padding(20).frame(width: 600, height: 700).background(Color.kilnBg))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(5))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("rich-links-native-x.png"))
    }

    func testLiveProviderMetadataWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["KILN_LIVE_LINK_TESTS"] == "1" else { throw XCTSkip("Opt-in public provider request") }
        var fixtures: [[String: Any]] = []
        for source in ["https://youtu.be/M7lc1UVf-VE", "https://x.com/Interior/status/463440424141459456", "https://vimeo.com/49343906", "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC", "https://soundcloud.com/forss/flickermood", "https://www.tiktok.com/@scout2015/video/6718335390845095173"] {
            let link = try XCTUnwrap(RichLink.make(source))
            let reference = try XCTUnwrap(MediaReference.make(source: source))
            let metadata = await LinkMetadataService.shared.metadata(for: link, refresh: true)
            print("Provider \(link.provider.rawValue): \(metadata.unavailable ? "unavailable" : "loaded") | \(metadata.title) | \(metadata.author)")
            if link.provider == .youtube { XCTAssertFalse(metadata.unavailable); XCTAssertFalse(metadata.author.isEmpty) }
            var fixture: [String: Any] = ["id": reference.id, "source": reference.source, "label": reference.label, "kind": "link", "provider": link.provider.rawValue,
                "title": metadata.title, "author": metadata.author, "unavailable": metadata.unavailable, "height": link.height]
            fixture["thumbnail"] = metadata.thumbnail
            fixture["embedURL"] = link.embedURL?.absoluteString
            if let post = metadata.post { fixture["post"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(post)) }
            fixtures.append(fixture)
        }
        if let path = ProcessInfo.processInfo.environment["KILN_LINK_FIXTURES"] {
            try JSONSerialization.data(withJSONObject: fixtures, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}
