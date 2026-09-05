import AppKit
import ImageIO
import UniformTypeIdentifiers

enum AttachmentImportError: LocalizedError {
    case unreadableFile, invalidImage, imageTooLarge

    var errorDescription: String? {
        switch self {
        case .unreadableFile: "The attachment is not a readable local file."
        case .invalidImage: "The clipboard image could not be read."
        case .imageTooLarge: "The clipboard image is too large (maximum 32 MB or 40 megapixels)."
        }
    }
}

struct AttachmentImporter: Sendable {
    var directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kiln/attachments", isDirectory: true)

    static func accepts(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    // Snapshot only on an explicit paste. File URLs take priority over Finder thumbnails.
    @MainActor static func providers(from pasteboard: NSPasteboard) -> [NSItemProvider] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                return NSItemProvider(object: url as NSURL)
            }
            for type in item.types where UTType(type.rawValue)?.conforms(to: .image) == true {
                if let data = item.data(forType: type) {
                    return NSItemProvider(item: data as NSData, typeIdentifier: type.rawValue)
                }
            }
            return nil
        }
    }

    @MainActor func load(_ provider: NSItemProvider) async throws -> ComposerAttachment {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    if let error { continuation.resume(throwing: error); return }
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        ?? (item as? String).flatMap(URL.init(string:))
                    guard let url else { continuation.resume(throwing: AttachmentImportError.unreadableFile); return }
                    continuation.resume(returning: url)
                }
            }
            return try Self.file(url)
        }
        let types = provider.registeredTypeIdentifiers.filter { UTType($0)?.conforms(to: .image) == true }
        for type in types {
            do {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: AttachmentImportError.invalidImage) }
                    }
                }
                return try await Task.detached { try self.saveImage(data) }.value
            } catch AttachmentImportError.imageTooLarge { throw AttachmentImportError.imageTooLarge }
            catch { if type == types.last { throw error } }
        }
        throw AttachmentImportError.invalidImage
    }

    static func file(_ url: URL) throws -> ComposerAttachment {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
              values.isRegularFile == true, values.isReadable == true else { throw AttachmentImportError.unreadableFile }
        return ComposerAttachment(id: UUID().uuidString, path: url.standardizedFileURL.path, name: url.lastPathComponent)
    }

    func saveImage(_ data: Data) throws -> ComposerAttachment {
        guard data.count <= 32 * 1024 * 1024 else { throw AttachmentImportError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw AttachmentImportError.invalidImage }
        guard width <= 40_000_000 / height else { throw AttachmentImportError.imageTooLarge }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw AttachmentImportError.invalidImage
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentImportError.invalidImage }
        guard png.length <= 32 * 1024 * 1024 else { throw AttachmentImportError.imageTooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let url = directory.appendingPathComponent("pasted-\(id).png")
        try (png as Data).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return ComposerAttachment(id: id, path: url.path, name: "Screenshot.png")
    }
}
