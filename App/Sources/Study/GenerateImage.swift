import AgentKit
import Foundation

/// Saves a generated image in the phone's workspace, independent of the chat's work location.
struct GenerateImage: AgentTool {
    static let name = "generate_image"
    let baseURL: String
    let model: String
    let apiKey: String?
    var endpointKind: Endpoint.Kind = .openai
    var customHeaders: [String: String] = [:]

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
        let resolvedSize = size.isEmpty ? "1024x1024" : size
        let data: Data
        do {
            if endpointKind.usesResponsesAPI {
                let responses = OpenAIResponsesProvider(
                    baseURL: baseURL,
                    apiKey: apiKey,
                    isCodex: endpointKind == .openaiCodex,
                    customHeaders: customHeaders,
                    fixedRoute: true
                )
                data = try await responses.generateImage(model: model, prompt: prompt, size: resolvedSize)
            } else {
                let provider = OpenAIProvider(
                    baseURL: baseURL,
                    apiKey: apiKey,
                    fixedRoute: true,
                    customHeaders: customHeaders
                )
                data = try await provider.generateImage(model: model, prompt: prompt, size: resolvedSize)
            }
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

        let path: String
        do {
            path = try WorkspaceImages.save(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkspaceImages.Failure {
            return failure(error.key)
        } catch {
            return failure("errors.imageSave")
        }

        let alt = String(prompt.prefix(20))
            .replacingOccurrences(of: "[", with: "［")
            .replacingOccurrences(of: "]", with: "］")
            .components(separatedBy: .newlines).joined(separator: " ")
        return ToolOutput("图片已保存。把下面这行原样写进给用户的回答：\n![\(alt)](\(path))")
    }

    private func failure(_ key: String) -> ToolOutput { ToolOutput(L.t(key), isError: true) }
}
