import Foundation

enum RemoteWebAssets {
    private static var bundle: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Kiln_Kiln.bundle"),
           let packaged = Bundle(url: url) { return packaged }
        return .module
    }

    static func text(_ name: String) -> String {
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "remote"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    static let page: String = {
        let vendors = ["purify.min.js", "marked.umd.js", "lucide.min.js"]
            .map { "<script>" + text("vendor/" + $0) + "</script>" }.joined(separator: "\n")
        let logo = bundle.url(forResource: "OpenAI-white-monoblossom", withExtension: "png", subdirectory: "brands")
            .flatMap { try? Data(contentsOf: $0) }?.base64EncodedString() ?? ""
        return text("index.html")
            .replacingOccurrences(of: "/*STYLES*/", with: text("remote.css"))
            .replacingOccurrences(of: "/*APPLICATION*/", with: text("remote.js"))
            .replacingOccurrences(of: "<!--VENDOR-->", with: vendors)
            .replacingOccurrences(of: "__OPENAI_LOGO__", with: "data:image/png;base64," + logo)
    }()
}
