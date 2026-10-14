// Crops a PNG to its visible pixels plus a margin, so a transparent window capture
// does not carry its empty frame into the README.
// Usage: swift trim-transparent.swift <input.png> <output.png> [margin]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("usage: trim-transparent.swift <input.png> <output.png> [margin]"); exit(2)
}
let margin = arguments.count > 3 ? Int(arguments[3]) ?? 24 : 24
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
// Ignore the faint outer shadow; keep anything clearly drawn.
var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 40 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= 0 else { print("image is fully transparent"); exit(1) }
let crop = CGRect(x: max(0, minX - margin), y: max(0, minY - margin),
                  width: min(width, maxX + margin + 1) - max(0, minX - margin),
                  height: min(height, maxY + margin + 1) - max(0, minY - margin))
guard let cropped = image.cropping(to: crop),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, cropped, nil)
CGImageDestinationFinalize(destination)
print("\(arguments[2]): \(Int(crop.width))x\(Int(crop.height))")
