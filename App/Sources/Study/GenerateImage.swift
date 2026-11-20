import AgentKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Saves a generated image in the phone's workspace, independent of the chat's work location.
struct GenerateImage: AgentTool {
    static let name = "generate_image"
    let baseURL: String
    let model: String
    let apiKey: String?

    var spec: ToolSpec {
        ToolSpec(name: Self.name, description: "按用户的要求生成一张图片，保存到书案。成功后把工具给出的 Markdown 图片行原样写进回答。", parameters: [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "图片的详细描述"],
                "size": ["type": "string", "description": "图片尺寸，形如 1024x1024", "default": "1024x1024"],
            ],
            "required": ["prompt"],
        ])
    }

    func label(for arguments: JSONValue) -> String { L.t("settings.imageGenerate") }

    func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let prompt = arguments["prompt"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { return failure("errors.imagePromptEmpty") }
        guard let apiKey, !apiKey.isEmpty else { return failure("errors.invalidApiKey") }
        let size = arguments["size"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let provider = OpenAIProvider(baseURL: baseURL, apiKey: apiKey)
        let data: Data
        do {
            data = try await provider.generateImage(model: model, prompt: prompt, size: size.isEmpty ? "1024x1024" : size)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: return failure("errors.imageTimeout")
            case .notConnectedToInternet, .networkConnectionLost: return failure("errors.offline")
            default: return failure("errors.imageConnection")
            }
        } catch let error as ImageGenerationError {
            switch error {
            case .invalidEndpoint: return failure("errors.imageEndpoint")
            case .invalidResponse: return failure("errors.imageResponse")
            case .contentRejected: return failure("errors.imageRejected")
            case .insufficientQuota: return failure("errors.insufficientQuota")
            case .invalidKey: return failure("errors.invalidApiKey")
            case .rateLimited: return failure("errors.rateLimited")
            case .timeout: return failure("errors.imageTimeout")
            case .serviceUnavailable: return failure("errors.serverError")
            }
        } catch {
            return failure("errors.imageConnection")
        }

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
            return failure("errors.imageResponse")
        }
        try Task.checkCancellation()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
                return failure("errors.imageSave")
            }
            CGImageDestinationAddImage(destination, pixels, nil)
            guard CGImageDestinationFinalize(destination) else { return failure("errors.imageSave") }
            try (png as Data).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return failure("errors.imageSave")
        }

        let alt = String(prompt.prefix(20))
            .replacingOccurrences(of: "[", with: "［")
            .replacingOccurrences(of: "]", with: "］")
            .components(separatedBy: .newlines).joined(separator: " ")
        return ToolOutput("图片已保存。把下面这行原样写进给用户的回答：\n![\(alt)](书案/图片/\(file.lastPathComponent))")
    }

    private func failure(_ key: String) -> ToolOutput { ToolOutput(L.t(key), isError: true) }
}
