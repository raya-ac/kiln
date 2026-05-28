import Foundation

struct CrashReportInfo: Identifiable, Equatable {
    let url: URL
    let modifiedAt: Date

    var id: String { url.path }

    var displayPath: String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

enum CrashReportLocator {
    static var reportDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("DiagnosticReports", isDirectory: true)
    }

    static func latestKilnReport() -> CrashReportInfo? {
        latestKilnReport(in: reportDirectory)
    }

    static func latestKilnReport(in directory: URL, fileManager: FileManager = .default) -> CrashReportInfo? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return urls
            .compactMap { reportInfo(for: $0) }
            .max(by: { $0.modifiedAt < $1.modifiedAt })
    }

    private static func reportInfo(for url: URL) -> CrashReportInfo? {
        let name = url.lastPathComponent
        guard name.hasPrefix("Kiln") else { return nil }

        let ext = url.pathExtension.lowercased()
        guard ext == "ips" || ext == "crash" else { return nil }

        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        if values?.isRegularFile == false { return nil }

        return CrashReportInfo(
            url: url,
            modifiedAt: values?.contentModificationDate ?? .distantPast
        )
    }
}
