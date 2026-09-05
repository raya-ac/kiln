import Foundation

actor LinkMetadataService {
    static let shared = LinkMetadataService()
    private var cache: [String: (Date, LinkMetadata)] = [:]
    private var pending: [String: Task<LinkMetadata, Never>] = [:]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config, delegate: NoMetadataRedirects(), delegateQueue: nil)
    }

    func metadata(for link: RichLink, refresh: Bool = false) async -> LinkMetadata {
        let key = link.url.absoluteString
        if !refresh, let (expiry, value) = cache[key], expiry > Date() { return value }
        if let task = pending[key] { return await task.value }
        let session = session
        let task = Task<LinkMetadata, Never> {
            do {
                // Only canonical links reach fixed provider endpoints. Never fetch arbitrary pages,
                // follow their redirects, or execute HTML returned by an oEmbed endpoint.
                var request = URLRequest(url: link.metadataURL)
                request.setValue("Kiln (https://github.com/raya-ac/kiln)", forHTTPHeaderField: "User-Agent")
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= 512_000 else { throw URLError(.badServerResponse) }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 512_000 else { throw CocoaError(.fileReadTooLarge) }
                    data.append(byte)
                }
                return try LinkMetadata.decode(data, for: link)
            } catch {
                var value = link.fallback
                value.unavailable = true
                return value
            }
        }
        pending[key] = task
        let value = await task.value
        pending[key] = nil
        if cache.count >= 256 { cache = cache.filter { $0.value.0 > Date() }; if cache.count >= 256 { cache.removeAll(keepingCapacity: true) } }
        cache[key] = (Date().addingTimeInterval(value.unavailable ? 60 : 3600), value)
        return value
    }
}

private final class NoMetadataRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
