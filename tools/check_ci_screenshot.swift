import CoreGraphics
import Foundation
import ImageIO

// A simulator screenshot can contain a status bar even when the app never drew.
guard CommandLine.arguments.count == 2,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.height > image.width else {
    exit(EXIT_FAILURE)
}

let width = 64
let height = 128
var pixels = [UInt8](repeating: 0, count: width * height)
let rendered = pixels.withUnsafeMutableBytes { buffer in
    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
    context.interpolationQuality = .low
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}

let body = pixels[(width * 13)..<(width * (height - 13))]
guard rendered, let darkest = body.min(), let lightest = body.max(), lightest - darkest >= 20 else {
    exit(EXIT_FAILURE)
}
