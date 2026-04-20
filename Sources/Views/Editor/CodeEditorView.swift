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

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let language: String
    let isEditable: Bool
    var onSave: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "kiln")
        config.userContentController = ucc
        // Allow file:// pages loaded via loadFileURL: to read sibling assets.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.preferences.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")   // avoid white flash on load
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web

        loadHost(into: web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        guard coord.ready else { return }
        coord.push(text: text, language: Self.monacoLanguage(for: language), editable: isEditable)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "kiln")
    }

    private func loadHost(into web: WKWebView) {
        guard let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "App/Resources/editor")
                ?? Bundle.module.url(forResource: "index", withExtension: "html") else {
            return
        }
        // Grant read access to the bundle resource root so Monaco's ../monaco/vs/
        // relative load resolves. Walk two parents up from the host html.
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        web.loadFileURL(url, allowingReadAccessTo: root)
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
        default: return "plaintext"
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: CodeEditorView
        weak var webView: WKWebView?
        var ready = false
        private var lastPushedText: String = ""
        private var lastPushedLang: String = ""
        private var lastEditable: Bool?

        init(_ parent: CodeEditorView) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any], let kind = dict["kind"] as? String else { return }
            switch kind {
            case "ready":
                ready = true
                push(text: parent.text,
                     language: CodeEditorView.monacoLanguage(for: parent.language),
                     editable: parent.isEditable)
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
