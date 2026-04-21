import SwiftUI
import AppKit
import WebKit

// MARK: - Code Editor (Monaco in WKWebView)
//
// Monaco is the same engine VS Code ships. We load the `min/vs` runtime
// from Sources/App/Resources/monaco/vs/ (fetched by scripts/fetch-monaco.sh)
// through a WKWebView via loadFileURL: — fully offline, no CORS.
//
// Public API is unchanged from the previous NSTextView implementation so
// RightPanel (and any other callsite) compiles without edits.
//
// Guardrails (after an earlier crashy build):
//   * No private KVC. `allowFileAccessFromFileURLs` etc. are removed —
//     `loadFileURL:allowingReadAccessTo:` is enough for sibling <script>
//     loads. `drawsBackground` is replaced by `underPageBackgroundColor`.
//   * Host loading is deferred to `updateNSView` via async dispatch so any
//     exception never propagates inside a SwiftUI/AppKit layout pass.
//   * If the runtime hasn't been fetched yet we render an inline HTML
//     message instead of failing silently; user knows to run `make monaco`.

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: String
    let isEditable: Bool
    var accentHex: String = "ff7a45"
    var onSave: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "kiln")
        config.userContentController = ucc

        let web = WKWebView(frame: .zero, configuration: config)
        // Match Monaco's dark theme so there's no white flash on first paint.
        web.underPageBackgroundColor = NSColor(red: 0x1a/255.0, green: 0x1a/255.0, blue: 0x1a/255.0, alpha: 1)
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.parent = self

        // Defer initial load off the current layout pass. Loading a file URL
        // synchronously inside makeNSView raised under macOS 26's layout
        // engine. Dispatching to main gets us past the current commit.
        if !coord.loadRequested {
            coord.loadRequested = true
            DispatchQueue.main.async { [weak coord, weak web] in
                guard let coord, let web else { return }
                Self.loadHost(into: web, coord: coord)
            }
        }

        guard coord.ready else { return }
        coord.push(text: text, language: Self.monacoLanguage(for: language), editable: isEditable)
        coord.pushAccent(accentHex)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "kiln")
    }

    private static func loadHost(into web: WKWebView, coord: Coordinator) {
        // Find the editor host page bundled by SPM.
        //
        // Bundle.module's auto-generated accessor looks at
        // `Bundle.main.bundleURL/Kiln_Kiln.bundle` — which for a packaged
        // .app resolves to the app ROOT, a spot codesign forbids
        // unsealed contents. So in shipped builds we copy the resource
        // bundle to Contents/Resources/Kiln_Kiln.bundle instead, and
        // load from there as a first-class fallback before letting
        // Bundle.module try (which succeeds in dev via the baked-in
        // .build/ path).
        func appResourceBundleURL() -> URL? {
            guard let resources = Bundle.main.resourceURL else { return nil }
            let url = resources.appendingPathComponent("Kiln_Kiln.bundle")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        var candidates: [URL?] = []
        if let res = appResourceBundleURL(), let b = Bundle(url: res) {
            candidates.append(b.url(forResource: "index", withExtension: "html", subdirectory: "editor"))
            candidates.append(b.url(forResource: "index", withExtension: "html"))
        }
        candidates.append(Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "App/Resources/editor"))
        candidates.append(Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "editor"))
        candidates.append(Bundle.module.url(forResource: "index", withExtension: "html"))
        guard let url = candidates.compactMap({ $0 }).first else {
            web.loadHTMLString(Self.fallbackHTML(
                title: "Editor resources missing",
                body: "Could not find <code>App/Resources/editor/index.html</code> in the app bundle.<br>Rebuild with <code>swift build</code>."
            ), baseURL: nil)
            return
        }

        // Check that the Monaco runtime was fetched. The host page expects
        // `../monaco/vs/loader.js` relative to itself.
        let vsLoader = url
            .deletingLastPathComponent()           // editor/
            .deletingLastPathComponent()           // Resources bundle root
            .appendingPathComponent("monaco/vs/loader.js")
        if !FileManager.default.fileExists(atPath: vsLoader.path) {
            web.loadHTMLString(Self.fallbackHTML(
                title: "Monaco runtime missing",
                body: "Run <code>make monaco</code> once to fetch the editor runtime (~13 MB), then rebuild."
            ), baseURL: nil)
            return
        }

        // Grant read access to the bundle resource root so Monaco's
        // `../monaco/vs/` relative load resolves.
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        web.loadFileURL(url, allowingReadAccessTo: root)
        coord.hostLoaded = true
    }

    /// Themed error card — same palette as the Monaco dark theme so the
    /// editor pane doesn't flash bright when resources are missing.
    private static func fallbackHTML(title: String, body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
          html, body { height: 100%; margin: 0; background: #1a1a1a; color: #e6e6e6;
            font: 13px -apple-system, BlinkMacSystemFont, sans-serif; }
          .card { padding: 24px 28px; max-width: 520px; margin: 40px auto; }
          h1 { font-size: 14px; color: #ff7a45; margin: 0 0 8px; letter-spacing: 0.02em; }
          p { color: #9a9a9a; margin: 0; line-height: 1.55; }
          code { background: #262626; padding: 1px 6px; border-radius: 3px; color: #e6e6e6; }
        </style></head>
        <body><div class="card"><h1>\(title)</h1><p>\(body)</p></div></body></html>
        """
    }

    // MARK: - Language mapping
    //
    // RightPanel's languageForFile() uses short tags ("js", "py", "shell", …).
    // Monaco wants canonical names ("javascript", "python", "shell", …). Keep
    // this in one place so adding extensions doesn't touch two files.
    static func monacoLanguage(for lang: String) -> String {
        switch lang.lowercased() {
        case "swift": return "swift"
        case "js", "javascript": return "javascript"
        case "ts", "typescript": return "typescript"
        case "jsx": return "javascript"
        case "tsx": return "typescript"
        case "py", "python": return "python"
        case "rb", "ruby": return "ruby"
        case "go", "golang": return "go"
        case "rs", "rust": return "rust"
        case "c": return "c"
        case "cpp", "c++", "cc", "cxx": return "cpp"
        case "objc", "objective-c", "m", "mm": return "objective-c"
        case "java": return "java"
        case "kotlin", "kt": return "kotlin"
        case "scala": return "scala"
        case "php": return "php"
        case "sh", "bash", "zsh", "shell": return "shell"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "ini"
        case "xml": return "xml"
        case "html", "htm": return "html"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "less": return "less"
        case "md", "markdown": return "markdown"
        case "sql": return "sql"
        case "dockerfile": return "dockerfile"
        case "makefile": return "makefile"
        case "graphql", "gql": return "graphql"
        case "r": return "r"
        case "lua": return "lua"
        case "perl", "pl": return "perl"
        case "dart": return "dart"
        case "elixir", "ex", "exs": return "elixir"
        case "clojure", "clj": return "clojure"
        case "haskell", "hs": return "haskell"
        case "fsharp", "fs": return "fsharp"
        case "cs", "csharp": return "csharp"
        case "vb": return "vb"
        case "powershell", "ps1": return "powershell"
        // Custom-registered languages (see App/Resources/editor/index.html
        // registerBasic calls). Monaco doesn't ship these — we register a
        // minimal Monarch tokenizer at editor init so keywords/strings/
        // comments get colored. These cases MUST match the `id` passed to
        // registerBasic or setModelLanguage silently falls back to plaintext.
        case "zig": return "zig"
        case "nim": return "nim"
        case "odin": return "odin"
        case "elm": return "elm"
        case "ocaml", "ml", "mli": return "ocaml"
        case "fortran", "f", "f77", "f90", "f95", "f03", "f08": return "fortran"
        case "nix": return "nix"
        case "mk", "make": return "makefile"
        case "cmake": return "cmake"
        case "gleam": return "gleam"
        case "crystal", "cr": return "crystal"
        case "vlang": return "v"
        // Passthrough: any other language id gets handed straight to Monaco.
        // Monaco silently treats unknown ids as plaintext, so this is safe
        // AND means new registerBasic calls in index.html don't need a
        // corresponding Swift case to take effect.
        default: return lang.lowercased()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: CodeEditorView
        weak var webView: WKWebView?
        var loadRequested = false
        var hostLoaded = false
        var ready = false
        private var lastPushedText: String = ""
        private var lastPushedLang: String = ""
        private var lastEditable: Bool?
        private var lastAccent: String = ""

        init(_ parent: CodeEditorView) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any], let kind = dict["kind"] as? String else { return }
            switch kind {
            case "ready":
                ready = true
                push(text: parent.text,
                     language: CodeEditorView.monacoLanguage(for: parent.language),
                     editable: parent.isEditable)
                pushAccent(parent.accentHex)
            case "change":
                guard let newText = dict["text"] as? String else { return }
                lastPushedText = newText
                if parent.text != newText { parent.text = newText }
            case "save":
                parent.onSave?()
            default:
                break
            }
        }

        func push(text: String, language: String, editable: Bool) {
            guard let web = webView else { return }
            if text != lastPushedText {
                lastPushedText = text
                let js = "window.kiln && window.kiln.setText(\(Self.jsString(text)));"
                web.evaluateJavaScript(js, completionHandler: nil)
            }
            if language != lastPushedLang {
                lastPushedLang = language
                let js = "window.kiln && window.kiln.setLanguage(\(Self.jsString(language)));"
                web.evaluateJavaScript(js, completionHandler: nil)
            }
            if editable != lastEditable {
                lastEditable = editable
                let js = "window.kiln && window.kiln.setEditable(\(editable ? "true" : "false"));"
                web.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        /// Push the user's accent hex through to Monaco so keywords, cursor,
        /// selection etc. pick up their selected color. Idempotent.
        func pushAccent(_ hex: String) {
            guard let web = webView, ready else { return }
            let clean = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            if clean == lastAccent { return }
            lastAccent = clean
            let js = "window.kiln && window.kiln.setAccent(\(Self.jsString(clean)));"
            web.evaluateJavaScript(js, completionHandler: nil)
        }

        /// JSON-encode a Swift string for safe inline injection into JS.
        private static func jsString(_ s: String) -> String {
            if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
               let arr = String(data: data, encoding: .utf8) {
                // arr is e.g. `["hello"]` — strip the brackets.
                return String(arr.dropFirst().dropLast())
            }
            return "\"\""
        }
    }
}
