import AgentKit
@testable import Craft
import Foundation
import XCTest
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

final class MCPImageTests: XCTestCase {
    // Minimal spec-valid 1x1 VP8 WebP image.
    private static let minimalWebPBase64 = "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"

    func testNormalizeMimeTypeHandlesAliasesParametersAndCasing() {
        XCTAssertEqual(MCPImage.normalizeMimeType("image/jpg"), "image/jpeg")
        XCTAssertEqual(MCPImage.normalizeMimeType(" IMAGE/JPEG; charset=utf-8 "), "image/jpeg")
        XCTAssertEqual(MCPImage.normalizeMimeType("image/pjpeg"), "image/jpeg")
        XCTAssertEqual(MCPImage.normalizeMimeType("image/x-png"), "image/png")
        XCTAssertEqual(MCPImage.normalizeMimeType("image/PNG"), "image/png")
        XCTAssertEqual(MCPImage.normalizeMimeType("image/webp"), "image/webp")
        XCTAssertEqual(MCPImage.normalizeMimeType("image/gif"), "image/gif")
        XCTAssertNil(MCPImage.normalizeMimeType(nil))
        XCTAssertNil(MCPImage.normalizeMimeType("   "))
    }

    func testSniffFormatIdentifiesMagicBytesAndRejectsNonImages() {
        XCTAssertEqual(MCPImage.sniffFormat(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])), .png)
        XCTAssertEqual(MCPImage.sniffFormat(Data([0xFF, 0xD8, 0xFF, 0xE0])), .jpeg)
        XCTAssertEqual(MCPImage.sniffFormat(Data("GIF87a\u{01}".utf8)), .gif)
        XCTAssertEqual(MCPImage.sniffFormat(Data("GIF89a\u{01}".utf8)), .gif)
        XCTAssertEqual(MCPImage.sniffFormat(Data(base64Encoded: Self.minimalWebPBase64)!), .webp)
        XCTAssertEqual(MCPImage.sniffFormat(Data([0x42, 0x4D, 0x1E, 0x00])), .bmp)
        XCTAssertEqual(MCPImage.sniffFormat(Data([0x49, 0x49, 0x2A, 0x00])), .tiff)
        XCTAssertEqual(MCPImage.sniffFormat(Data([0x4D, 0x4D, 0x00, 0x2A])), .tiff)
        XCTAssertNil(MCPImage.sniffFormat(Data("not an image".utf8)))
        XCTAssertNil(MCPImage.sniffFormat(Data([0x89])))
    }

    #if canImport(ImageIO)
    func testExtractsPNGJPEGWebPAndGIFAndOverridesMismatchedMime() throws {
        let pngData = try makeImageData(width: 8, height: 8, type: UTType.png.identifier, alpha: true)
        let jpegData = try makeImageData(width: 8, height: 8, type: UTType.jpeg.identifier)
        let gifData = try makeImageData(width: 8, height: 8, type: UTType.gif.identifier)
        let webpData = try XCTUnwrap(Data(base64Encoded: Self.minimalWebPBase64))

        let result: JSONValue = [
            "content": [
                ["type": "text", "text": "截图结果："],
                ["type": "image", "data": .string(pngData.base64EncodedString()), "mimeType": "image/x-png"],
                // Server mislabeled JPEG bytes as image/png; sniffed magic bytes must win.
                ["type": "image", "data": .string(jpegData.base64EncodedString()), "mimeType": "image/png"],
                ["type": "image", "data": .string(webpData.base64EncodedString()), "mimeType": "application/octet-stream"],
                ["type": "image", "data": .string(gifData.base64EncodedString())],
            ],
        ]

        let output = MCPImage.toolOutput(from: result)
        XCTAssertFalse(output.isError)
        XCTAssertEqual(output.images.count, 4)
        XCTAssertEqual(output.images[0], ImagePart(mediaType: "image/png", data: pngData))
        XCTAssertEqual(output.images[1], ImagePart(mediaType: "image/jpeg", data: jpegData))
        XCTAssertEqual(output.images[2], ImagePart(mediaType: "image/webp", data: webpData))
        XCTAssertEqual(output.images[3], ImagePart(mediaType: "image/gif", data: gifData))
        XCTAssertTrue(output.text.contains("截图结果："))
        XCTAssertTrue(output.text.contains("［已附 4 张图片（image/png、image/jpeg、image/webp、image/gif）］"))
    }

    func testExtractsDataURLWithWhitespaceAndImageFieldFallback() throws {
        let pngData = try makeImageData(width: 6, height: 6, type: UTType.png.identifier)
        let rawBase64 = pngData.base64EncodedString()
        let splitIndex = rawBase64.index(rawBase64.startIndex, offsetBy: rawBase64.count / 2)
        let wrappedDataURL = "  data:image/png;charset=utf-8;base64,\n  \(rawBase64[..<splitIndex])\r\n  \(rawBase64[splitIndex...])  "

        let result: JSONValue = [
            "content": [
                ["type": "image", "data": "", "image": .string(wrappedDataURL)],
            ],
        ]

        let output = MCPImage.toolOutput(from: result)
        XCTAssertEqual(output.images, [ImagePart(mediaType: "image/png", data: pngData)])
        XCTAssertEqual(output.text, "［已附 1 张图片（image/png）］")
    }

    func testConvertsBMPToJPEG() throws {
        let bmpData = try makeImageData(width: 12, height: 12, type: UTType.bmp.identifier)
        let item: JSONValue = [
            "type": "image",
            "data": .string(bmpData.base64EncodedString()),
            "mimeType": "image/bmp",
        ]

        let extracted = MCPImage.extractImage(from: item, remainingBudget: MCPImageLimits.default.maxTotalBytes)
        guard case .accepted(let part) = extracted else {
            return XCTFail("Expected BMP to convert cleanly to JPEG, got \(extracted)")
        }
        XCTAssertEqual(part.mediaType, "image/jpeg")
        XCTAssertEqual(MCPImage.sniffFormat(part.data), .jpeg)
    }

    func testDownsamplesOversizedPNGWithTransparencyToJPEGWithinCap() throws {
        let largePNG = try makeNoisyPNG(canvasSize: 1600, noiseSize: 600)
        XCTAssertGreaterThan(largePNG.count, 200_000)

        let limits = MCPImageLimits(
            maxImages: 4,
            maxBytesPerImage: 200_000,
            maxTotalBytes: 400_000
        )
        let result: JSONValue = [
            "content": [
                ["type": "image", "data": .string(largePNG.base64EncodedString()), "mimeType": "image/png"],
            ],
        ]

        let output = MCPImage.toolOutput(from: result, limits: limits)
        XCTAssertEqual(output.images.count, 1)
        XCTAssertEqual(output.images[0].mediaType, "image/jpeg")
        XCTAssertLessThanOrEqual(output.images[0].data.count, 200_000)
        XCTAssertEqual(MCPImage.sniffFormat(output.images[0].data), .jpeg)
        XCTAssertEqual(output.text, "［已附 1 张图片（image/jpeg）］")
    }

    func testEnforcesMaxImagesPerCallAndTotalByteBudget() throws {
        let pngData = try makeImageData(width: 8, height: 8, type: UTType.png.identifier)
        let encodedPNG = pngData.base64EncodedString()

        // 6 valid images should be capped at 4.
        let sixImages: JSONValue = [
            "content": .array((0..<6).map { _ in
                ["type": "image", "data": .string(encodedPNG), "mimeType": "image/png"]
            }),
        ]
        let cappedOutput = MCPImage.toolOutput(from: sixImages)
        XCTAssertEqual(cappedOutput.images.count, 4)
        XCTAssertTrue(cappedOutput.text.contains("［已附 4 张图片（image/png）］"))
        XCTAssertTrue(cappedOutput.text.contains("另有 2 张图片未能读取：已达单次最多 4 张图片上限"))

        // Tight total budget leaves only 100 bytes after image 1, so image 2 cannot fit even as JPEG.
        let jpegData = try makeImageData(width: 8, height: 8, type: UTType.jpeg.identifier)
        let encodedJPEG = jpegData.base64EncodedString()
        let tightLimits = MCPImageLimits(
            maxImages: 4,
            maxBytesPerImage: 100_000,
            maxTotalBytes: jpegData.count + 100
        )
        let twoImages: JSONValue = [
            "content": [
                ["type": "image", "data": .string(encodedJPEG), "mimeType": "image/jpeg"],
                ["type": "image", "data": .string(encodedJPEG), "mimeType": "image/jpeg"],
            ],
        ]
        let budgetOutput = MCPImage.toolOutput(from: twoImages, limits: tightLimits)
        XCTAssertEqual(budgetOutput.images.count, 1)
        XCTAssertTrue(budgetOutput.text.contains("［已附 1 张图片（image/jpeg）］"))
        XCTAssertTrue(budgetOutput.text.contains("总大小上限"))
    }

    func testRejectsEmptyInvalidBase64SVGCorruptedAndDecompressionBombPayloads() throws {
        let truncatedPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        let noIDATPNG = makeFakeHeaderPNG(width: 8, height: 8)
        let bombPNG = makeFakeHeaderPNG(width: 30_000, height: 30_000)

        let payloads: [(JSONValue, [String])] = [
            (["type": "image", "mimeType": "image/png"], ["没有图片数据"]),
            (["type": "image", "data": "not-base64!!!", "mimeType": "image/png"], ["base64"]),
            (["type": "image", "data": .string(Data("plain text".utf8).base64EncodedString()), "mimeType": "image/png"], ["不是支持的图片格式"]),
            (["type": "image", "data": "data:image/svg+xml,<svg/>"], ["base64"]),
            (["type": "image", "data": .string(Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8).base64EncodedString()), "mimeType": "image/svg+xml"], ["SVG"]),
            (["type": "image", "data": .string(truncatedPNG.base64EncodedString()), "mimeType": "image/png"], ["损坏", "格式不符"]),
            (["type": "image", "data": .string(noIDATPNG.base64EncodedString()), "mimeType": "image/png"], ["损坏"]),
            (["type": "image", "data": .string(bombPNG.base64EncodedString()), "mimeType": "image/png"], ["分辨率过高"]),
        ]

        for (item, expectedFragments) in payloads {
            let result = MCPImage.extractImage(from: item, remainingBudget: MCPImageLimits.default.maxTotalBytes)
            guard case .rejected(let reason) = result else {
                XCTFail("Expected rejection for item \(item), got \(result)")
                continue
            }
            XCTAssertTrue(
                expectedFragments.contains { reason.contains($0) },
                "Expected one of \(expectedFragments) in '\(reason)'"
            )

            let wrapped = MCPImage.toolOutput(from: ["content": [item]])
            XCTAssertTrue(wrapped.images.isEmpty)
            XCTAssertTrue(wrapped.text.contains("［一张图片未能读取："))
        }
    }

    func testRejectsOversizedEncodedStringBeforeDecoding() throws {
        let pngData = try makeImageData(width: 8, height: 8, type: UTType.png.identifier)
        let tinyEncodedLimit = MCPImageLimits(maxEncodedBytes: 16)
        let result = MCPImage.extractImage(
            from: ["type": "image", "data": .string(pngData.base64EncodedString())],
            remainingBudget: tinyEncodedLimit.maxTotalBytes,
            limits: tinyEncodedLimit
        )
        guard case .rejected(let reason) = result else {
            return XCTFail("Expected pre-decode limit rejection, got \(result)")
        }
        XCTAssertTrue(reason.contains("过大"))
    }

    func testLongTextTruncationPreservesImageIndicatorAndServerFlags() throws {
        let pngData = try makeImageData(width: 8, height: 8, type: UTType.png.identifier)
        let longText = String(repeating: "a", count: 20_000)
        let result: JSONValue = [
            "isError": true,
            "content": [
                ["type": "text", "text": .string(longText)],
                ["type": "image", "data": .string(pngData.base64EncodedString()), "mimeType": "image/png"],
            ],
        ]

        let output = MCPImage.toolOutput(from: result)
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.images.count, 1)
        XCTAssertTrue(output.text.contains("……（太长，截断了）"))
        XCTAssertTrue(output.text.contains("［已附 1 张图片（image/png）］"))
        XCTAssertLessThanOrEqual(output.text.count, 16_050)

        let structuredOnly: JSONValue = ["structuredContent": ["ok": true]]
        XCTAssertEqual(MCPImage.toolOutput(from: structuredOnly).text, "{\"ok\":true}")

        let emptyResult: JSONValue = [:]
        XCTAssertEqual(MCPImage.toolOutput(from: emptyResult).text, "（没有内容）")
    }

    func testCanSeeFalseDropsImagesKeepsTextAndDoesNotConsumeTurnBudget() throws {
        let pngData = try makeImageData(width: 8, height: 8, type: UTType.png.identifier)
        let jpegData = try makeImageData(width: 8, height: 8, type: UTType.jpeg.identifier)
        let turnBudget = MCPImageTurnBudget(maxImages: 6, maxTotalBytes: 10 * 1024 * 1024)

        let result: JSONValue = [
            "content": [
                ["type": "text", "text": "页面摘要如下："],
                ["type": "image", "data": .string(pngData.base64EncodedString()), "mimeType": "image/png"],
                ["type": "image", "data": .string(jpegData.base64EncodedString()), "mimeType": "image/jpeg"],
            ],
        ]

        let output = MCPImage.toolOutput(from: result, canSee: false, turnBudget: turnBudget)
        XCTAssertTrue(output.images.isEmpty)
        XCTAssertTrue(output.text.contains("页面摘要如下："))
        XCTAssertTrue(output.text.contains("［有 2 张图片；当前模型看不了图，已保留文字内容］"))
        let snapshot = turnBudget.snapshot()
        XCTAssertEqual(snapshot.images, 0)
        XCTAssertEqual(snapshot.bytes, 0)
    }

    func testTurnBudgetEnforcesCumulativeImageCountAndByteCapAcrossCalls() throws {
        let pngData = try makeImageData(width: 8, height: 8, type: UTType.png.identifier)
        let encodedPNG = pngData.base64EncodedString()
        let countBudget = MCPImageTurnBudget(maxImages: 6, maxTotalBytes: 10 * 1024 * 1024)

        let fourImages: JSONValue = [
            "content": .array((0..<4).map { _ in
                ["type": "image", "data": .string(encodedPNG), "mimeType": "image/png"]
            }),
        ]
        let first = MCPImage.toolOutput(from: fourImages, turnBudget: countBudget)
        XCTAssertEqual(first.images.count, 4)
        XCTAssertEqual(countBudget.snapshot().images, 4)

        let second = MCPImage.toolOutput(from: fourImages, turnBudget: countBudget)
        XCTAssertEqual(second.images.count, 2)
        XCTAssertEqual(countBudget.snapshot().images, 6)
        XCTAssertTrue(second.text.contains("［已附 2 张图片（image/png）］"))
        XCTAssertTrue(second.text.contains("另有 2 张图片未能读取：已达本轮最多 6 张图片上限"))

        let third = MCPImage.toolOutput(from: ["content": [["type": "image", "data": .string(encodedPNG)]]], turnBudget: countBudget)
        XCTAssertTrue(third.images.isEmpty)
        XCTAssertTrue(third.text.contains("已达本轮最多 6 张图片上限"))

        // Cumulative byte cap across calls.
        let jpegData = try makeImageData(width: 8, height: 8, type: UTType.jpeg.identifier)
        let encodedJPEG = jpegData.base64EncodedString()
        let byteBudget = MCPImageTurnBudget(maxImages: 6, maxTotalBytes: jpegData.count * 2 + 100)

        let oneJPEG: JSONValue = ["content": [["type": "image", "data": .string(encodedJPEG), "mimeType": "image/jpeg"]]]
        let call1 = MCPImage.toolOutput(from: oneJPEG, turnBudget: byteBudget)
        XCTAssertEqual(call1.images.count, 1)

        let twoJPEGs: JSONValue = [
            "content": [
                ["type": "image", "data": .string(encodedJPEG), "mimeType": "image/jpeg"],
                ["type": "image", "data": .string(encodedJPEG), "mimeType": "image/jpeg"],
            ],
        ]
        let call2 = MCPImage.toolOutput(from: twoJPEGs, turnBudget: byteBudget)
        XCTAssertEqual(call2.images.count, 1)
        XCTAssertTrue(call2.text.contains("［已附 1 张图片（image/jpeg）］"))
        XCTAssertTrue(call2.text.contains("本轮图片总大小上限"))
    }

    func testAnimatedGIFConvertsToStaticJPEG() throws {
        let animatedGIF = try makeAnimatedGIFData(width: 8, height: 8, frameCount: 2)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(animatedGIF as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)

        let result: JSONValue = [
            "content": [
                ["type": "image", "data": .string(animatedGIF.base64EncodedString()), "mimeType": "image/gif"],
            ],
        ]
        let output = MCPImage.toolOutput(from: result)
        XCTAssertEqual(output.images.count, 1)
        XCTAssertEqual(output.images[0].mediaType, "image/jpeg")
        XCTAssertEqual(MCPImage.sniffFormat(output.images[0].data), .jpeg)
        XCTAssertEqual(output.text, "［已附 1 张图片（image/jpeg）］")
    }

    func testLongTextTruncationPrioritizesAttachedNoteOverManyRejectedNotes() throws {
        let pngData = try makeImageData(width: 8, height: 8, type: UTType.png.identifier)
        let longText = String(repeating: "x", count: 20_000)
        var items: [JSONValue] = [["type": "text", "text": .string(longText)]]
        for _ in 0..<100 {
            items.append(["type": "image", "mimeType": "image/png"])
        }
        items.append(["type": "image", "data": .string(pngData.base64EncodedString()), "mimeType": "image/png"])

        let output = MCPImage.toolOutput(
            from: ["content": .array(items)],
            limits: MCPImageLimits(maxAttempts: 200)
        )
        XCTAssertEqual(output.images.count, 1)
        XCTAssertLessThanOrEqual(output.text.count, 16_050)
        XCTAssertTrue(output.text.contains("……（太长，截断了）"))
        XCTAssertTrue(output.text.contains("［已附 1 张图片（image/png）］"))
    }

    func testSkipImagesOnCancellationPreservesTextAndIsErrorWithoutDecoding() async throws {
        let pngData = try makeImageData(width: 8, height: 8, type: UTType.png.identifier)
        let turnBudget = MCPImageTurnBudget(maxImages: 6, maxTotalBytes: 10 * 1024 * 1024)
        let result: JSONValue = [
            "isError": true,
            "content": [
                ["type": "text", "text": "已执行远程命令，部分输出如下"],
                ["type": "image", "data": .string(pngData.base64EncodedString()), "mimeType": "image/png"],
                ["type": "image", "data": "invalid-not-base64!!!", "mimeType": "image/png"],
            ],
        ]

        let explicit = MCPImage.toolOutputWithMetrics(from: result, skipImages: true, turnBudget: turnBudget)
        XCTAssertTrue(explicit.output.isError)
        XCTAssertTrue(explicit.output.images.isEmpty)
        XCTAssertTrue(explicit.output.text.contains("已执行远程命令，部分输出如下"))
        XCTAssertTrue(explicit.output.text.contains("［有 2 张图片；取消时跳过图片读取，已保留文字结果］"))
        XCTAssertEqual(explicit.metrics.decodeAttempts, 0)
        XCTAssertEqual(explicit.metrics.transcodePasses, 0)
        let budgetAfterExplicit = turnBudget.snapshot()
        XCTAssertEqual(budgetAfterExplicit.images, 0)
        XCTAssertEqual(budgetAfterExplicit.bytes, 0)

        let cancelled = await withTaskGroup(of: (output: ToolOutput, metrics: MCPImage.ProcessingMetrics).self) { group in
            group.cancelAll()
            group.addTask {
                MCPImage.toolOutputWithMetrics(from: result, turnBudget: turnBudget)
            }
            return await group.next()!
        }
        XCTAssertTrue(cancelled.output.isError)
        XCTAssertTrue(cancelled.output.images.isEmpty)
        XCTAssertTrue(cancelled.output.text.contains("已执行远程命令，部分输出如下"))
        XCTAssertTrue(cancelled.output.text.contains("取消时跳过图片读取"))
        XCTAssertEqual(cancelled.metrics.decodeAttempts, 0)
        XCTAssertEqual(cancelled.metrics.transcodePasses, 0)
    }

    func testCapsImageAttemptsAndSkipsTranscodeWhenBudgetNearExhaustion() throws {
        // 1) Near-exhaustion budget (< minTranscodeBudget) short-circuits subsequent oversized images before decode/transcode.
        let largePNG = try makeNoisyPNG(canvasSize: 1600, noiseSize: 600)
        let encodedLarge = largePNG.base64EncodedString()
        let baseline = MCPImage.toolOutputWithMetrics(
            from: ["content": [["type": "image", "data": .string(encodedLarge), "mimeType": "image/png"]]],
            limits: MCPImageLimits(maxImages: 4, maxBytesPerImage: 200_000, maxTotalBytes: 400_000)
        )
        XCTAssertEqual(baseline.output.images.count, 1)
        let compressedSize = baseline.output.images[0].data.count
        let singleTranscodePasses = baseline.metrics.transcodePasses
        XCTAssertGreaterThan(singleTranscodePasses, 0)

        let tightLimits = MCPImageLimits(
            maxImages: 4,
            maxBytesPerImage: 200_000,
            maxTotalBytes: compressedSize + 4_000
        )
        let elevenLarge: JSONValue = [
            "content": .array((0..<11).map { _ in
                ["type": "image", "data": .string(encodedLarge), "mimeType": "image/png"]
            }),
        ]
        let bounded = MCPImage.toolOutputWithMetrics(from: elevenLarge, limits: tightLimits)
        XCTAssertEqual(bounded.output.images.count, 1)
        XCTAssertEqual(bounded.metrics.decodeAttempts, 1)
        XCTAssertEqual(bounded.metrics.transcodePasses, singleTranscodePasses)
        XCTAssertTrue(bounded.output.text.contains("［已附 1 张图片（image/jpeg）］"))
        XCTAssertTrue(bounded.output.text.contains("总大小上限"))

        // 2) Many consecutive invalid/unfit images stop at maxAttempts (default 8).
        let corruptPNG = makeFakeHeaderPNG(width: 8, height: 8)
        let encodedCorrupt = corruptPNG.base64EncodedString()
        let fifteenCorrupt: JSONValue = [
            "content": .array((0..<15).map { _ in
                ["type": "image", "data": .string(encodedCorrupt), "mimeType": "image/png"]
            }),
        ]
        let capped = MCPImage.toolOutputWithMetrics(from: fifteenCorrupt)
        XCTAssertTrue(capped.output.images.isEmpty)
        XCTAssertEqual(capped.metrics.decodeAttempts, 8)
        XCTAssertTrue(capped.output.text.contains("另有 7 张图片未能读取：已达单次最多尝试 8 张图片上限"))
    }

    // MARK: - Helpers

    private func makeImageData(width: Int, height: Int, type: String, alpha: Bool = false) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = alpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "MCPImageTests", code: 1)
        }
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw NSError(domain: "MCPImageTests", code: 2)
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, type as CFString, 1, nil) else {
            throw NSError(domain: "MCPImageTests", code: 3)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "MCPImageTests", code: 4)
        }
        return out as Data
    }

    private func makeNoisyPNG(canvasSize: Int, noiseSize: Int) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: canvasSize * canvasSize * 4)
        var rng: UInt64 = 0x1234_5678_9ABC_DEF0
        let offset = (canvasSize - noiseSize) / 2
        for y in 0..<canvasSize {
            for x in 0..<canvasSize {
                let index = (y * canvasSize + x) * 4
                if x >= offset, x < offset + noiseSize, y >= offset, y < offset + noiseSize {
                    rng = rng &* 6364136223846793005 &+ 1442695040888963407
                    pixels[index] = UInt8((rng >> 16) & 0xFF)
                    pixels[index + 1] = UInt8((rng >> 24) & 0xFF)
                    pixels[index + 2] = UInt8((rng >> 32) & 0xFF)
                    pixels[index + 3] = 200
                } else {
                    pixels[index] = 255
                    pixels[index + 1] = 255
                    pixels[index + 2] = 255
                    pixels[index + 3] = 255
                }
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let image: CGImage? = pixels.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: canvasSize,
                      height: canvasSize,
                      bitsPerComponent: 8,
                      bytesPerRow: canvasSize * 4,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return nil
            }
            return context.makeImage()
        }
        guard let cgImage = image else {
            throw NSError(domain: "MCPImageTests", code: 5)
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "MCPImageTests", code: 6)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "MCPImageTests", code: 7)
        }
        return out as Data
    }

    private func makeFakeHeaderPNG(width: UInt32, height: UInt32) -> Data {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdrBody = Data("IHDR".utf8)
        var beWidth = width.bigEndian
        var beHeight = height.bigEndian
        withUnsafeBytes(of: &beWidth) { ihdrBody.append(contentsOf: $0) }
        withUnsafeBytes(of: &beHeight) { ihdrBody.append(contentsOf: $0) }
        ihdrBody.append(contentsOf: [8, 2, 0, 0, 0])

        var ihdrLen = UInt32(13).bigEndian
        var crc = crc32(ihdrBody).bigEndian
        withUnsafeBytes(of: &ihdrLen) { png.append(contentsOf: $0) }
        png.append(ihdrBody)
        withUnsafeBytes(of: &crc) { png.append(contentsOf: $0) }
        png.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        return png
    }

    private func makeAnimatedGIFData(width: Int, height: Int, frameCount: Int) throws -> Data {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw NSError(domain: "MCPImageTests", code: 10)
        }
        let fileGIFDict: [CFString: Any] = [kCGImagePropertyGIFLoopCount: 0]
        let fileProperties: [CFString: Any] = [kCGImagePropertyGIFDictionary: fileGIFDict]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let frameGIFDict: [CFString: Any] = [kCGImagePropertyGIFDelayTime: 0.1]
        let frameProperties: [CFString: Any] = [kCGImagePropertyGIFDictionary: frameGIFDict]
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        for index in 0..<frameCount {
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                throw NSError(domain: "MCPImageTests", code: 11)
            }
            let shade: CGFloat = index % 2 == 0 ? 0.2 : 0.8
            context.setFillColor(red: shade, green: 0.4, blue: 0.6, alpha: 1.0)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let frame = context.makeImage() else {
                throw NSError(domain: "MCPImageTests", code: 12)
            }
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "MCPImageTests", code: 13)
        }
        return out as Data
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return ~crc
    }
    #endif
}
