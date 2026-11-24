import AgentKit
import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Memory and payload caps applied to images returned by MCP `tools/call` responses.
public struct MCPImageLimits: Equatable, Sendable {
    public var maxImages: Int
    public var maxBytesPerImage: Int
    public var maxTotalBytes: Int
    public var maxEncodedBytes: Int
    public var maxPixelDimension: Int
    public var maxPixelCount: Int
    public var maxUnconvertedDimension: Int
    public var maxAttempts: Int
    public var minTranscodeBudget: Int

    public init(
        maxImages: Int = 4,
        maxBytesPerImage: Int = 3_900_000,
        maxTotalBytes: Int = 10 * 1024 * 1024,
        maxEncodedBytes: Int = 24 * 1024 * 1024,
        maxPixelDimension: Int = 16_384,
        maxPixelCount: Int = 64_000_000,
        maxUnconvertedDimension: Int = 4096,
        maxAttempts: Int? = nil,
        minTranscodeBudget: Int = 8_192
    ) {
        let clampedImages = max(0, maxImages)
        self.maxImages = clampedImages
        self.maxBytesPerImage = max(1, maxBytesPerImage)
        self.maxTotalBytes = max(1, maxTotalBytes)
        self.maxEncodedBytes = max(1, maxEncodedBytes)
        self.maxPixelDimension = max(1, maxPixelDimension)
        self.maxPixelCount = max(1, maxPixelCount)
        self.maxUnconvertedDimension = max(1, maxUnconvertedDimension)
        self.maxAttempts = max(clampedImages, maxAttempts ?? max(clampedImages * 2, clampedImages + 2))
        self.minTranscodeBudget = max(0, minTranscodeBudget)
    }

    public static let `default` = MCPImageLimits()
}

/// Thread-safe cumulative image budget shared across all MCP tool calls within one agent turn.
public final class MCPImageTurnBudget: @unchecked Sendable {
    public enum ReserveOutcome: Equatable, Sendable {
        case reserved
        case imageLimitReached
        case byteLimitReached
    }

    public let maxImages: Int
    public let maxTotalBytes: Int

    private let lock = NSLock()
    private var usedImages = 0
    private var usedBytes = 0

    public init(maxImages: Int = 6, maxTotalBytes: Int = 10 * 1024 * 1024) {
        self.maxImages = max(0, maxImages)
        self.maxTotalBytes = max(1, maxTotalBytes)
    }

    public var remainingImages: Int {
        lock.lock()
        defer { lock.unlock() }
        return max(0, maxImages - usedImages)
    }

    public var remainingBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return max(0, maxTotalBytes - usedBytes)
    }

    public func snapshot() -> (images: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (usedImages, usedBytes)
    }

    public func tryReserve(bytes: Int) -> ReserveOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard usedImages < maxImages else { return .imageLimitReached }
        guard bytes >= 0, usedBytes + bytes <= maxTotalBytes else { return .byteLimitReached }
        usedImages += 1
        usedBytes += bytes
        return .reserved
    }
}

/// Sniffed raster image format from raw decoded bytes.
public enum MCPImageFormat: String, Equatable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case webp = "image/webp"
    case gif = "image/gif"
    case bmp = "image/bmp"
    case tiff = "image/tiff"
    case heic = "image/heic"

    /// Formats natively supported by Clio's vision providers without transcoding.
    public var isDirectlySupported: Bool {
        switch self {
        case .jpeg, .png, .webp, .gif: return true
        case .bmp, .tiff, .heic: return false
        }
    }
}

/// Validates, normalizes, and downsamples base64 image content returned by MCP tools.
public enum MCPImage {
    public enum ExtractionResult: Equatable, Sendable {
        case accepted(ImagePart)
        case rejected(String)
    }

    struct ProcessingMetrics: Equatable, Sendable {
        var decodeAttempts = 0
        var transcodePasses = 0
    }

    private enum OutputSegment {
        case text(String)
        case imageGroup([String])
        case hiddenImageGroup(Int)
        case cancelledImageGroup(Int)
        case imageNote(String)
    }

    private enum SkipReason: Equatable {
        case callLimit(Int)
        case turnLimit(Int)
        case attemptLimit(Int)
        case callByteLimit
        case turnByteLimit
    }

    private struct DecodedPayload {
        var data: Data
        var dataURLMime: String?
    }

    private enum DecodeError: Error {
        case message(String)
        case budgetExceeded
    }

    private static let maxTextLength = 16_000
    private static let maxNotesLength = 1500

    /// Normalizes a declared MIME type string (stripping `;parameters`, casing, and aliases like `image/jpg`).
    public static func normalizeMimeType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let head = raw.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !head.isEmpty else { return nil }
        switch head {
        case "image/jpg", "image/pjpeg": return "image/jpeg"
        case "image/x-png": return "image/png"
        case "image/x-webp": return "image/webp"
        case "image/x-ms-bmp", "image/x-bmp": return "image/bmp"
        case "image/tif": return "image/tiff"
        case "image/heif": return "image/heic"
        default: return head
        }
    }

    /// Sniffs actual raster image container format from magic bytes.
    public static func sniffFormat(_ data: Data) -> MCPImageFormat? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8, bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return .png
        }
        if bytes.count >= 3, bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if bytes.count >= 6,
           bytes.starts(with: [0x47, 0x49, 0x46, 0x38, 0x37, 0x61])
            || bytes.starts(with: [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]) {
            return .gif
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return .webp
        }
        if bytes[0] == 0x42, bytes[1] == 0x4D {
            return .bmp
        }
        if bytes.count >= 4,
           bytes.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return .tiff
        }
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70,
           let brand = String(bytes: bytes[8..<12], encoding: .ascii),
           ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) {
            return .heic
        }
        return nil
    }

    /// Converts an MCP `tools/call` `result` JSON object into a `ToolOutput`, attaching validated images under caps.
    public static func toolOutput(
        from result: JSONValue,
        limits: MCPImageLimits = .default,
        canSee: Bool = true,
        skipImages: Bool = false,
        turnBudget: MCPImageTurnBudget? = nil
    ) -> ToolOutput {
        toolOutputWithMetrics(
            from: result,
            limits: limits,
            canSee: canSee,
            skipImages: skipImages,
            turnBudget: turnBudget
        ).output
    }

    static func toolOutputWithMetrics(
        from result: JSONValue,
        limits: MCPImageLimits = .default,
        canSee: Bool = true,
        skipImages: Bool = false,
        turnBudget: MCPImageTurnBudget? = nil
    ) -> (output: ToolOutput, metrics: ProcessingMetrics) {
        let contentItems = result["content"]?.array ?? []
        var segments: [OutputSegment] = []
        var images: [ImagePart] = []
        var metrics = ProcessingMetrics()
        var callRemainingBytes = limits.maxTotalBytes
        var attempts = 0
        var pendingSkipReason: SkipReason?
        var pendingSkipCount = 0

        func flushSkipped() {
            guard pendingSkipCount > 0, let reason = pendingSkipReason else { return }
            switch reason {
            case .callLimit(let limit):
                if pendingSkipCount == 1 {
                    segments.append(.imageNote("［一张图片未能读取：已达单次最多 \(limit) 张图片上限］"))
                } else {
                    segments.append(.imageNote("［另有 \(pendingSkipCount) 张图片未能读取：已达单次最多 \(limit) 张图片上限］"))
                }
            case .turnLimit(let limit):
                if pendingSkipCount == 1 {
                    segments.append(.imageNote("［一张图片未能读取：已达本轮最多 \(limit) 张图片上限］"))
                } else {
                    segments.append(.imageNote("［另有 \(pendingSkipCount) 张图片未能读取：已达本轮最多 \(limit) 张图片上限］"))
                }
            case .attemptLimit(let limit):
                if pendingSkipCount == 1 {
                    segments.append(.imageNote("［一张图片未能读取：已达单次最多尝试 \(limit) 张图片上限］"))
                } else {
                    segments.append(.imageNote("［另有 \(pendingSkipCount) 张图片未能读取：已达单次最多尝试 \(limit) 张图片上限］"))
                }
            case .callByteLimit:
                if pendingSkipCount == 1 {
                    segments.append(.imageNote("［一张图片未能读取：超出单次调用图片总大小上限，已略过］"))
                } else {
                    segments.append(.imageNote("［另有 \(pendingSkipCount) 张图片未能读取：超出单次调用图片总大小上限，已略过］"))
                }
            case .turnByteLimit:
                if pendingSkipCount == 1 {
                    segments.append(.imageNote("［一张图片未能读取：超出本轮图片总大小上限，已略过］"))
                } else {
                    segments.append(.imageNote("［另有 \(pendingSkipCount) 张图片未能读取：超出本轮图片总大小上限，已略过］"))
                }
            }
            pendingSkipReason = nil
            pendingSkipCount = 0
        }

        func recordSkip(_ reason: SkipReason) {
            if pendingSkipReason == reason {
                pendingSkipCount += 1
            } else {
                flushSkipped()
                pendingSkipReason = reason
                pendingSkipCount = 1
            }
        }

        for item in contentItems {
            let kind = item["type"]?.string
            if kind != "image" {
                flushSkipped()
            }
            switch kind {
            case "text":
                segments.append(.text(item["text"]?.string ?? ""))
            case "image":
                if skipImages || Task.isCancelled {
                    flushSkipped()
                    if case .cancelledImageGroup(let count)? = segments.last {
                        segments[segments.count - 1] = .cancelledImageGroup(count + 1)
                    } else {
                        segments.append(.cancelledImageGroup(1))
                    }
                    continue
                }
                if !canSee {
                    flushSkipped()
                    if case .hiddenImageGroup(let count)? = segments.last {
                        segments[segments.count - 1] = .hiddenImageGroup(count + 1)
                    } else {
                        segments.append(.hiddenImageGroup(1))
                    }
                    continue
                }
                if images.count >= limits.maxImages {
                    recordSkip(.callLimit(limits.maxImages))
                    continue
                }
                if let turnBudget, turnBudget.remainingImages <= 0 {
                    recordSkip(.turnLimit(turnBudget.maxImages))
                    continue
                }
                if attempts >= limits.maxAttempts {
                    recordSkip(.attemptLimit(limits.maxAttempts))
                    continue
                }
                let turnRemaining = turnBudget?.remainingBytes ?? Int.max
                let effectiveRemaining = min(callRemainingBytes, turnRemaining)
                if effectiveRemaining <= 0 {
                    recordSkip(turnRemaining <= 0 ? .turnByteLimit : .callByteLimit)
                    continue
                }
                attempts += 1
                let extraction = extractImageWithMetrics(
                    from: item,
                    remainingBudget: effectiveRemaining,
                    limits: limits,
                    isTurnBudgetTighter: turnRemaining < callRemainingBytes,
                    metrics: &metrics
                )
                switch extraction {
                case .accepted(let part):
                    if let turnBudget {
                        switch turnBudget.tryReserve(bytes: part.data.count) {
                        case .reserved:
                            break
                        case .imageLimitReached:
                            recordSkip(.turnLimit(turnBudget.maxImages))
                            continue
                        case .byteLimitReached:
                            recordSkip(.turnByteLimit)
                            continue
                        }
                    }
                    flushSkipped()
                    images.append(part)
                    callRemainingBytes = max(0, callRemainingBytes - part.data.count)
                    if case .imageGroup(var existing)? = segments.last {
                        existing.append(part.mediaType)
                        segments[segments.count - 1] = .imageGroup(existing)
                    } else {
                        segments.append(.imageGroup([part.mediaType]))
                    }
                case .rejected(let reason):
                    if reason == "超出本轮图片总大小上限，已略过" {
                        recordSkip(.turnByteLimit)
                    } else if reason == "超出单次调用图片总大小上限，已略过" {
                        recordSkip(.callByteLimit)
                    } else {
                        flushSkipped()
                        segments.append(.imageNote("［一张图片未能读取：\(reason)］"))
                    }
                }
            case "resource":
                segments.append(.text(item["resource"]?["text"]?.string ?? "［资源］"))
            default:
                segments.append(.text(item.compact))
            }
        }
        flushSkipped()

        if segments.isEmpty, let structured = result["structuredContent"] {
            segments.append(.text(structured.compact))
        }

        let text = renderText(from: segments)
        let isError = result["isError"]?.bool ?? false
        return (ToolOutput(text.isEmpty ? "（没有内容）" : text, isError: isError, images: images), metrics)
    }

    /// Validates, normalizes, and downsamples a single MCP `"image"` content item.
    public static func extractImage(
        from item: JSONValue,
        remainingBudget: Int,
        limits: MCPImageLimits = .default
    ) -> ExtractionResult {
        var metrics = ProcessingMetrics()
        return extractImageWithMetrics(
            from: item,
            remainingBudget: remainingBudget,
            limits: limits,
            isTurnBudgetTighter: false,
            metrics: &metrics
        )
    }

    private static func extractImageWithMetrics(
        from item: JSONValue,
        remainingBudget: Int,
        limits: MCPImageLimits,
        isTurnBudgetTighter: Bool,
        metrics: inout ProcessingMetrics
    ) -> ExtractionResult {
        guard remainingBudget > 0 else {
            return .rejected(isTurnBudgetTighter ? "超出本轮图片总大小上限，已略过" : "超出单次调用图片总大小上限，已略过")
        }

        let rawString = nonEmpty(item["data"]?.string)
            ?? nonEmpty(item["image"]?.string)
            ?? nonEmpty(item["image"]?["data"]?.string)
        let itemMime = normalizeMimeType(
            nonEmpty(item["mimeType"]?.string)
                ?? nonEmpty(item["mediaType"]?.string)
                ?? nonEmpty(item["image"]?["mimeType"]?.string)
        )

        let decoded: DecodedPayload
        do {
            decoded = try decodeBase64Payload(
                rawString,
                maxEncodedBytes: limits.maxEncodedBytes,
                remainingBudget: remainingBudget,
                minTranscodeBudget: limits.minTranscodeBudget,
                metrics: &metrics
            )
        } catch DecodeError.budgetExceeded {
            return .rejected(isTurnBudgetTighter ? "超出本轮图片总大小上限，已略过" : "超出单次调用图片总大小上限，已略过")
        } catch DecodeError.message(let reason) {
            return .rejected(reason)
        } catch {
            return .rejected("图片数据无法读取")
        }

        if itemMime == "image/svg+xml" || decoded.dataURLMime == "image/svg+xml" || looksLikeMarkup(decoded.data) {
            return .rejected("不支持 SVG 或文本格式图片")
        }

        guard let format = sniffFormat(decoded.data) else {
            return .rejected("不是支持的图片格式")
        }

        return validateAndFit(
            data: decoded.data,
            format: format,
            remainingBudget: remainingBudget,
            limits: limits,
            isTurnBudgetTighter: isTurnBudgetTighter,
            metrics: &metrics
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private static func decodeBase64Payload(
        _ raw: String?,
        maxEncodedBytes: Int,
        remainingBudget: Int,
        minTranscodeBudget: Int,
        metrics: inout ProcessingMetrics
    ) throws -> DecodedPayload {
        guard let raw else { throw DecodeError.message("没有图片数据") }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DecodeError.message("没有图片数据") }

        var dataURLMime: String?
        let encoded: Substring
        if trimmed.prefix(5).lowercased() == "data:" {
            guard let comma = trimmed.firstIndex(of: ",") else {
                throw DecodeError.message("图片数据链接格式不对")
            }
            let headerStart = trimmed.index(trimmed.startIndex, offsetBy: 5)
            let header = trimmed[headerStart..<comma]
            let tokens = header.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard tokens.contains("base64") else {
                throw DecodeError.message("只支持 base64 编码的图片数据")
            }
            if let first = tokens.first, !first.isEmpty, first != "base64" {
                dataURLMime = normalizeMimeType(first)
            }
            encoded = trimmed[trimmed.index(after: comma)...]
        } else {
            encoded = Substring(trimmed)
        }

        guard encoded.utf8.count <= maxEncodedBytes else {
            throw DecodeError.message("图片编码内容过大，已略过")
        }

        var nonWhitespaceCount = 0
        var paddingCount = 0
        for byte in encoded.utf8 {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                continue
            case 0x3D: // '='
                paddingCount += 1
                if paddingCount > 2 {
                    throw DecodeError.message("图片 base64 数据格式不对")
                }
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2F:
                if paddingCount > 0 {
                    throw DecodeError.message("图片 base64 数据格式不对")
                }
                nonWhitespaceCount += 1
            default:
                throw DecodeError.message("图片 base64 数据格式不对")
            }
        }

        guard nonWhitespaceCount > 0 else {
            throw DecodeError.message("没有图片数据")
        }

        let estimatedDecodedBytes = max(0, (nonWhitespaceCount / 4) * 3 - paddingCount)
        if remainingBudget < minTranscodeBudget, estimatedDecodedBytes > remainingBudget {
            throw DecodeError.budgetExceeded
        }

        metrics.decodeAttempts += 1
        guard let data = Data(base64Encoded: String(encoded), options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw DecodeError.message("图片 base64 解码失败")
        }
        return DecodedPayload(data: data, dataURLMime: dataURLMime)
    }

    private static func looksLikeMarkup(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return prefix.hasPrefix("<svg")
            || prefix.hasPrefix("<?xml")
            || prefix.hasPrefix("<!doctype")
            || prefix.hasPrefix("<html")
    }

    private static func validateAndFit(
        data: Data,
        format: MCPImageFormat,
        remainingBudget: Int,
        limits: MCPImageLimits,
        isTurnBudgetTighter: Bool,
        metrics: inout ProcessingMetrics
    ) -> ExtractionResult {
        let maxAllowedBytes = min(limits.maxBytesPerImage, remainingBudget)
        guard maxAllowedBytes > 0 else {
            return .rejected(isTurnBudgetTighter ? "超出本轮图片总大小上限，已略过" : "超出单次调用图片总大小上限，已略过")
        }

        #if canImport(ImageIO)
        return autoreleasepool {
            let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, noCache) else {
                return .rejected("图片数据损坏，无法读取")
            }
            guard let rawUTI = CGImageSourceGetType(source) as String?,
                  utiMatches(rawUTI, format: format) else {
                return .rejected("图片内容与格式不符")
            }
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
                  let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0 else {
                return .rejected("图片数据损坏，读不出尺寸")
            }
            guard width <= limits.maxPixelDimension,
                  height <= limits.maxPixelDimension,
                  Int64(width) * Int64(height) <= Int64(limits.maxPixelCount) else {
                return .rejected("图片分辨率过高（\(width)×\(height)）")
            }

            let isAnimatedGIF = format == .gif && CGImageSourceGetCount(source) > 1
            let longest = max(width, height)
            if format.isDirectlySupported, !isAnimatedGIF, data.count <= maxAllowedBytes, longest <= limits.maxUnconvertedDimension {
                let probeOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, min(64, longest)),
                    kCGImageSourceShouldCache: false,
                ]
                guard CGImageSourceCreateThumbnailAtIndex(source, 0, probeOptions as CFDictionary) != nil else {
                    return .rejected("图片内容损坏，无法解码")
                }
                return .accepted(ImagePart(mediaType: format.rawValue, data: data))
            }

            if maxAllowedBytes < limits.minTranscodeBudget {
                if remainingBudget < limits.maxBytesPerImage {
                    return .rejected(isTurnBudgetTighter ? "超出本轮图片总大小上限，已略过" : "超出单次调用图片总大小上限，已略过")
                }
                return .rejected("图片压缩空间不足，已略过")
            }

            return encodeJPEGWithinBudget(
                source: source,
                longestDimension: longest,
                maxAllowedBytes: maxAllowedBytes,
                remainingBudget: remainingBudget,
                limits: limits,
                isTurnBudgetTighter: isTurnBudgetTighter,
                metrics: &metrics
            )
        }
        #else
        if format.isDirectlySupported, data.count <= maxAllowedBytes {
            return .accepted(ImagePart(mediaType: format.rawValue, data: data))
        }
        if data.count > maxAllowedBytes {
            if remainingBudget < limits.maxBytesPerImage {
                return .rejected(isTurnBudgetTighter ? "超出本轮图片总大小上限，已略过" : "超出单次调用图片总大小上限，已略过")
            }
            return .rejected("图片过大，已略过")
        }
        return .rejected("当前环境不支持此图片格式")
        #endif
    }

    #if canImport(ImageIO)
    private static func utiMatches(_ rawUTI: String, format: MCPImageFormat) -> Bool {
        guard let utType = UTType(rawUTI) else { return false }
        switch format {
        case .png:
            return utType.conforms(to: .png)
        case .jpeg:
            return utType.conforms(to: .jpeg)
        case .gif:
            return utType.conforms(to: .gif)
        case .webp:
            if let webp = UTType("org.webm.webp"), utType.conforms(to: webp) { return true }
            return rawUTI == "org.webm.webp" || rawUTI == "public.webp"
        case .bmp:
            return utType.conforms(to: .bmp)
        case .tiff:
            return utType.conforms(to: .tiff)
        case .heic:
            if let heic = UTType("public.heic"), utType.conforms(to: heic) { return true }
            if let heif = UTType("public.heif"), utType.conforms(to: heif) { return true }
            return false
        }
    }

    private static func encodeJPEGWithinBudget(
        source: CGImageSource,
        longestDimension: Int,
        maxAllowedBytes: Int,
        remainingBudget: Int,
        limits: MCPImageLimits,
        isTurnBudgetTighter: Bool,
        metrics: inout ProcessingMetrics
    ) -> ExtractionResult {
        let steps: [(longest: Int, quality: Double)] = [
            (2048, 0.82),
            (1568, 0.78),
            (1280, 0.70),
            (1024, 0.60),
            (768, 0.50),
            (512, 0.45),
        ]
        var decodedAny = false
        for step in steps {
            metrics.transcodePasses += 1
            let targetLongest = max(1, min(step.longest, longestDimension))
            let attempt: (decoded: Bool, data: Data?) = autoreleasepool {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: targetLongest,
                    kCGImageSourceShouldCache: false,
                ]
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return (false, nil)
                }
                let flattened = flattenAlphaIfNeeded(thumbnail)
                let out = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
                    return (true, nil)
                }
                CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: step.quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { return (true, nil) }
                return (true, out as Data)
            }
            if attempt.decoded { decodedAny = true }
            guard let encoded = attempt.data else { continue }
            if encoded.count <= maxAllowedBytes {
                return .accepted(ImagePart(mediaType: "image/jpeg", data: encoded))
            }
        }
        if !decodedAny {
            return .rejected("图片内容损坏，无法解码")
        }
        if remainingBudget < limits.maxBytesPerImage {
            return .rejected(isTurnBudgetTighter ? "超出本轮图片总大小上限，已略过" : "超出单次调用图片总大小上限，已略过")
        }
        return .rejected("图片压缩后仍超过大小上限，已略过")
    }

    private static func flattenAlphaIfNeeded(_ image: CGImage) -> CGImage {
        let alpha = image.alphaInfo
        let hasAlpha = alpha == .first || alpha == .last || alpha == .premultipliedFirst || alpha == .premultipliedLast
        guard hasAlpha,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return image
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
    #endif

    private static func renderText(from segments: [OutputSegment]) -> String {
        var allParts: [String] = []
        var bodyParts: [String] = []
        var attachedNotes: [String] = []
        var rejectedNotes: [String] = []

        for segment in segments {
            switch segment {
            case .text(let value):
                allParts.append(value)
                bodyParts.append(value)
            case .imageGroup(let mimes):
                var uniqueMimes: [String] = []
                for mime in mimes where !uniqueMimes.contains(mime) {
                    uniqueMimes.append(mime)
                }
                let line = "［已附 \(mimes.count) 张图片（\(uniqueMimes.joined(separator: "、"))）］"
                allParts.append(line)
                attachedNotes.append(line)
            case .hiddenImageGroup(let count):
                let line = "［有 \(count) 张图片；当前模型看不了图，已保留文字内容］"
                allParts.append(line)
                attachedNotes.append(line)
            case .cancelledImageGroup(let count):
                let line = "［有 \(count) 张图片；取消时跳过图片读取，已保留文字结果］"
                allParts.append(line)
                attachedNotes.append(line)
            case .imageNote(let note):
                allParts.append(note)
                rejectedNotes.append(note)
            }
        }

        let joined = allParts.joined(separator: "\n")
        if joined.count <= maxTextLength {
            return joined
        }

        let truncationMarker = "\n……（太长，截断了）"
        if attachedNotes.isEmpty && rejectedNotes.isEmpty {
            return String(joined.prefix(maxTextLength)) + truncationMarker
        }

        var packedNotes: [String] = []
        var packedChars = 0
        func appendBoundedNote(_ line: String) {
            if packedNotes.isEmpty {
                let clipped = String(line.prefix(maxNotesLength))
                packedNotes.append(clipped)
                packedChars = clipped.count
            } else {
                let added = line.count + 1
                if packedChars + added <= maxNotesLength {
                    packedNotes.append(line)
                    packedChars += added
                }
            }
        }
        // Prioritize successful/attachment indicators before rejected-image notes when truncating.
        for line in attachedNotes { appendBoundedNote(line) }
        for line in rejectedNotes { appendBoundedNote(line) }
        let notesBlock = packedNotes.joined(separator: "\n")

        let bodyJoined = bodyParts.joined(separator: "\n")
        if bodyJoined.isEmpty {
            return notesBlock
        }
        let availableBody = max(0, maxTextLength - notesBlock.count - 1)
        if bodyJoined.count <= availableBody {
            return bodyJoined + "\n" + notesBlock
        }
        let prefix = String(bodyJoined.prefix(availableBody))
        if prefix.isEmpty {
            return notesBlock
        }
        return prefix + truncationMarker + "\n" + notesBlock
    }
}
