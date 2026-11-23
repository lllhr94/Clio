import Foundation

public enum ImageGenerationError: Error, Equatable {
    case invalidEndpoint, invalidResponse, contentRejected, insufficientQuota, invalidKey, rateLimited, timeout, serviceUnavailable
}

extension OpenAIProvider {
    /// Returns the image bytes from an OpenAI-compatible images endpoint.
    public func generateImage(model: String, prompt: String, size: String) async throws -> Data {
        try await generateImage(model: model, prompt: prompt, size: size, session: HTTP.session)
    }

    private static let maxImageBytes = 32_000_000
    private static let maxJSONEnvelopeBytes = 48_000_000

    func generateImage(model: String, prompt: String, size: String, session: URLSession) async throws -> Data {
        let request = try imageRequest(model: model, prompt: prompt, size: size)
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if response.expectedContentLength > Int64(Self.maxJSONEnvelopeBytes) {
            throw ImageGenerationError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            if (data.count & 0xFFF) == 0 { try Task.checkCancellation() }
            data.append(byte)
            if data.count > Self.maxJSONEnvelopeBytes {
                throw ImageGenerationError.invalidResponse
            }
        }
        let json = JSONValue.parse(String(decoding: data, as: UTF8.self))
        guard (200..<300).contains(status), json?["error"] == nil || json?["error"] == .null else {
            throw Self.imageFailure(status: status, json: json)
        }
        guard let item = json?["data"]?.array?.first else { throw ImageGenerationError.invalidResponse }
        if let encoded = item["b64_json"]?.string, let decoded = Data(base64Encoded: encoded), !decoded.isEmpty {
            guard decoded.count <= Self.maxImageBytes else { throw ImageGenerationError.invalidResponse }
            return decoded
        }
        guard let address = item["url"]?.string, let url = Self.imageURL(address) else {
            throw ImageGenerationError.invalidResponse
        }

        // The download may be on a CDN. Keep the model key on the generation request, and block local/private SSRF & >32 MB payloads.
        do {
            let image = try await Web.publicBytes(from: url, limit: Self.maxImageBytes, timeout: 60, session: session)
            guard !image.isEmpty else { throw ImageGenerationError.invalidResponse }
            return image
        } catch let failure as ProviderError {
            if failure.status == 408 || failure.status == 504 { throw ImageGenerationError.timeout }
            throw ImageGenerationError.invalidResponse
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw ImageGenerationError.timeout
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ImageGenerationError.invalidResponse
        }
    }

    func imageRequest(model: String, prompt: String, size: String) throws -> URLRequest {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = Self.imageURL(base), url.query == nil, url.fragment == nil else {
            throw ImageGenerationError.invalidEndpoint
        }
        var request = URLRequest(url: url.appendingPathComponent("images/generations"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try HTTP.json(["model": model, "prompt": prompt, "size": size, "n": 1])
        return request
    }

    private static func imageURL(_ address: String) -> URL? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func imageFailure(status: Int, json: JSONValue?) -> ImageGenerationError {
        let error = json?["error"]
        let fields = [error?["code"]?.string, error?["type"]?.string, error?["message"]?.string,
                      error?.string, json?["code"]?.string, json?["message"]?.string]
        let detail = fields.compactMap { $0 }.joined(separator: " ").lowercased()
        if ["content_policy", "content policy", "content_filter", "content filter", "safety", "moderation", "内容审核"]
            .contains(where: { detail.contains($0) }) { return .contentRejected }
        if status == 402 || ["quota", "billing", "insufficient funds", "insufficient balance", "额度", "余额"]
            .contains(where: { detail.contains($0) }) { return .insufficientQuota }
        if status == 408 || status == 504 || detail.contains("timed out") { return .timeout }
        if status == 401 || status == 403 { return .invalidKey }
        if status == 429 { return .rateLimited }
        if status >= 500 { return .serviceUnavailable }
        return .invalidResponse
    }
}
