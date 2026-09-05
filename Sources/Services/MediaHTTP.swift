import Foundation
import Network
import UniformTypeIdentifiers

struct MediaByteRange: Equatable, Sendable {
    let offset: UInt64
    let count: UInt64

    static func parse(_ header: String, size: UInt64) -> Self? {
        guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { return nil }
            let count = min(size, suffix)
            return Self(offset: size - count, count: count)
        }
        guard let start = UInt64(parts[0]), start < size else { return nil }
        let end: UInt64
        if parts[1].isEmpty { end = size - 1 }
        else { guard let value = UInt64(parts[1]), value >= start else { return nil }; end = min(value, size - 1) }
        return Self(offset: start, count: end - start + 1)
    }
}

struct HTTPFileBody: Sendable {
    let url: URL
    let range: MediaByteRange
}

enum MediaHTTP {
    static func response(file: URL, rangeHeader: String?, download: Bool, head: Bool = false) throws -> HTTPResponse {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let byteCount = values.fileSize, byteCount >= 0 else { return .notFound }
        let size = UInt64(byteCount)
        let range: MediaByteRange
        if let rangeHeader {
            guard let parsed = MediaByteRange.parse(rangeHeader, size: size) else {
                return HTTPResponse(status: 416, headers: ["Content-Range": "bytes */\(size)"])
            }
            range = parsed
        } else { range = MediaByteRange(offset: 0, count: size) }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let displayable = mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime == "application/pdf"
        let filename = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")) ?? "media"
        var headers = [
            "Content-Type": mime,
            "Accept-Ranges": "bytes",
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "sandbox; default-src 'none'",
            "Referrer-Policy": "no-referrer",
            "Cache-Control": "private, no-store",
            "Content-Disposition": (download || !displayable ? "attachment" : "inline") + "; filename*=UTF-8''" + filename,
            "Content-Length": String(range.count),
        ]
        if rangeHeader != nil { headers["Content-Range"] = "bytes \(range.offset)-\(range.offset + range.count - 1)/\(size)" }
        return HTTPResponse(status: rangeHeader == nil ? 200 : 206, headers: headers,
            file: head ? nil : HTTPFileBody(url: file, range: range))
    }
}

/// A single serialized send chain bounds video memory to one chunk and stops
/// reading immediately when the browser closes or seeks to a different range.
final class HTTPFileTransfer: @unchecked Sendable {
    private let handle: FileHandle
    private let connection: NWConnection
    private var remaining: UInt64

    init(body: HTTPFileBody, connection: NWConnection) throws {
        handle = try FileHandle(forReadingFrom: body.url)
        self.connection = connection
        remaining = body.range.count
        try handle.seek(toOffset: body.range.offset)
    }

    deinit { try? handle.close() }

    func sendNext() {
        guard remaining > 0 else { connection.cancel(); return }
        do {
            guard let chunk = try handle.read(upToCount: Int(min(remaining, 65_536))), !chunk.isEmpty else {
                connection.cancel(); return
            }
            remaining -= UInt64(chunk.count)
            connection.send(content: chunk, completion: .contentProcessed { [self] error in
                if error != nil { connection.cancel() } else { sendNext() }
            })
        } catch { connection.cancel() }
    }
}
