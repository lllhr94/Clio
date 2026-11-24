import AgentKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum WorkspaceImages {
    enum Failure: Error {
        case unreadable, writeFailed

        var key: String {
            switch self {
            case .unreadable: "errors.imageResponse"
            case .writeFailed: "errors.imageSave"
            }
        }
    }

    /// Used by both the image tool and native chat replies, with the same PNG validation and file protection.
    static func save(_ data: Data) throws -> String {
        try Task.checkCancellation()
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = clock.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = Workspace.root.appendingPathComponent("图片", isDirectory: true)
        let file = folder.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8)).png")
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              let pixels = CGImageSourceCreateImageAtIndex(image, 0, nil) else {
            throw Failure.unreadable
        }
        try Task.checkCancellation()
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.writeFailed
        }
        CGImageDestinationAddImage(destination, pixels, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.writeFailed }
        do {
            var folderStat = stat()
            if lstat(folder.path, &folderStat) == 0, (folderStat.st_mode & S_IFMT) == S_IFLNK {
                throw Failure.writeFailed
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard Workspace.isInsideRealRoot(folder, root: Workspace.root),
                  Workspace.isInsideRealRoot(file, root: Workspace.root) else {
                throw Failure.writeFailed
            }
            try (png as Data).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw Failure.writeFailed
        }
        return "书案/图片/\(file.lastPathComponent)"
    }

    /// Keep only local Markdown in history. CDN requests never use the provider's key and enforce public SSRF + 32 MB limits.
    static func reply(_ images: [ReplyImage]) async throws -> String {
        var lines: [String] = []
        var failures: [String] = []
        for image in images {
            try Task.checkCancellation()
            do {
                let data: Data
                switch image {
                case .embedded(let part):
                    guard part.data.count <= 32_000_000 else { throw Failure.unreadable }
                    data = part.data
                case .remote(let url):
                    data = try await Web.publicBytes(from: url, limit: 32_000_000, timeout: 45)
                }
                lines.append("![](\(try save(data)))")
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                let key: String
                if let failure = error as? Failure { key = failure.key }
                else if (error as? URLError)?.code == .timedOut { key = "errors.imageTimeout" }
                else if let providerErr = error as? ProviderError, providerErr.status == 408 || providerErr.status == 504 { key = "errors.imageTimeout" }
                else { key = "errors.imageConnection" }
                if !failures.contains(key) { failures.append(key) }
            }
        }
        return (lines + failures.map { L.t($0) }).joined(separator: "\n\n")
    }
}
