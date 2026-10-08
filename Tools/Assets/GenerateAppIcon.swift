#!/usr/bin/env -S swift -swift-version 6
import AppKit
import Foundation

// Run from the repository root:
// swift -swift-version 6 Tools/Assets/GenerateAppIcon.swift
// Optional native-size light/dark inspection sheet:
// swift -swift-version 6 Tools/Assets/GenerateAppIcon.swift --preview /tmp/TSX-AppIcon-preview.png
// The selected glass artwork is kept at its original resolution. Every output
// is rendered directly from this master, with the same macOS tile contour.
// See README.md for the source and export contour.
// macOS asset sizes: https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/AppIconType.html

enum GenerationError: Error {
    case missingArtwork, invalidArtwork, bitmapAllocation, pngEncoding
    case pngOptimization(Int32), missingPreviewPath
}

let scriptDirectory = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent()
let root = scriptDirectory.deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appending(path: "LumaxTranslate/Resources/Assets.xcassets")
let iconSet = catalog.appending(path: "AppIcon.appiconset")
let brandSet = catalog.appending(path: "AppBrand.imageset")
let source = scriptDirectory.appending(path: "AppIcon.png")
guard let artwork = NSImage(contentsOf: source),
      let sourceBitmap = NSBitmapImageRep(data: try Data(contentsOf: source)) else {
    throw GenerationError.missingArtwork
}
guard sourceBitmap.pixelsWide == 1254, sourceBitmap.pixelsHigh == 1254,
      sourceBitmap.hasAlpha else { throw GenerationError.invalidArtwork }
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: brandSet, withIntermediateDirectories: true)
let scratch = FileManager.default.temporaryDirectory.appending(path: "TSXIcon-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

@MainActor
func png(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32
    )?.converting(to: .sRGB, renderingIntent: .default),
       let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw GenerationError.bitmapAllocation
    }
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    // A fixed vector export contour removes exterior cutout residue without
    // redrawing the glass. The master alpha is retained inside this contour.
    context.cgContext.scaleBy(x: CGFloat(size) / 1254, y: CGFloat(size) / 1254)
    let tile = NSBezierPath()
    tile.move(to: NSPoint(x: 418, y: 1106))
    tile.line(to: NSPoint(x: 836, y: 1106))
    tile.curve(to: NSPoint(x: 1106, y: 836), controlPoint1: NSPoint(x: 1025, y: 1106), controlPoint2: NSPoint(x: 1106, y: 1025))
    tile.line(to: NSPoint(x: 1106, y: 418))
    tile.curve(to: NSPoint(x: 836, y: 148), controlPoint1: NSPoint(x: 1106, y: 229), controlPoint2: NSPoint(x: 1025, y: 148))
    tile.line(to: NSPoint(x: 418, y: 148))
    tile.curve(to: NSPoint(x: 148, y: 418), controlPoint1: NSPoint(x: 229, y: 148), controlPoint2: NSPoint(x: 148, y: 229))
    tile.line(to: NSPoint(x: 148, y: 836))
    tile.curve(to: NSPoint(x: 418, y: 1106), controlPoint1: NSPoint(x: 148, y: 1025), controlPoint2: NSPoint(x: 229, y: 1106))
    tile.close()
    tile.addClip()
    artwork.draw(in: NSRect(x: 0, y: 0, width: 1254, height: 1254),
                 from: .zero, operation: .sourceOver, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw GenerationError.pngEncoding
    }
    return data
}

@MainActor
func optimize(_ data: Data) throws -> Data {
    let input = scratch.appending(path: "uncompressed.png")
    let output = scratch.appending(path: "optimized.png")
    try data.write(to: input)
    if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["pngcrush", "-q", "-reduce", input.path, output.path]
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw GenerationError.pngOptimization(process.terminationStatus) }
    let optimized = try Data(contentsOf: output)
    return optimized.count < data.count ? optimized : data
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try optimize(png(size: points * scale)).write(to: iconSet.appending(path: filename), options: .atomic)
        images.append(["filename": filename, "idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x"])
    }
}
let info: [String: Any] = ["author": "xcode", "version": 1]
let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: options)
    .write(to: iconSet.appending(path: "Contents.json"), options: .atomic)
try JSONSerialization.data(withJSONObject: ["info": info], options: options)
    .write(to: catalog.appending(path: "Contents.json"), options: .atomic)
print("Generated 10 macOS AppIcon images from \(source.path)")

// Ordinary image assets are available to SwiftUI and the isolated visual host;
// an AppIcon set itself is not a named SwiftUI image.
var brandImages: [[String: String]] = []
for scale in [1, 2, 3] {
    let filename = "AppBrand\(scale == 1 ? "" : "@\(scale)x").png"
    try optimize(png(size: 128 * scale)).write(to: brandSet.appending(path: filename), options: .atomic)
    brandImages.append(["filename": filename, "idiom": "universal", "scale": "\(scale)x"])
}
try JSONSerialization.data(withJSONObject: ["images": brandImages, "info": info], options: options)
    .write(to: brandSet.appending(path: "Contents.json"), options: .atomic)
print("Generated AppBrand from the same artwork and contour")

@MainActor
func preview(at output: URL) throws {
    let width = 1060, height = 640
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw GenerationError.bitmapAllocation
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    for (index, isDark) in [true, false].enumerated() {
        let base = CGFloat(index * 320)
        (isDark ? NSColor(srgbRed: 0.07, green: 0.09, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1)).setFill()
        NSRect(x: 0, y: base, width: CGFloat(width), height: 320).fill()
        let labelColor = isDark ? NSColor.white : NSColor.black
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: labelColor]
        (isDark ? "Dark background · native pixel sizes" : "Light background · native pixel sizes" as NSString)
            .draw(at: NSPoint(x: 28, y: base + 284), withAttributes: labelAttributes)
        for (size, centerX) in [(16, 72), (32, 182), (64, 320), (128, 516), (256, 836)] {
            let imageURL: URL
            switch size {
            case 64: imageURL = iconSet.appending(path: "icon_32x32@2x.png")
            default: imageURL = iconSet.appending(path: "icon_\(size)x\(size).png")
            }
            guard let image = NSImage(contentsOf: imageURL) else { throw GenerationError.missingArtwork }
            image.draw(in: NSRect(x: CGFloat(centerX) - CGFloat(size) / 2, y: base + 144 - CGFloat(size) / 2,
                                  width: CGFloat(size), height: CGFloat(size)))
            ("\(size) px" as NSString).draw(at: NSPoint(x: centerX - 18, y: Int(base) + 16), withAttributes: labelAttributes)
        }
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw GenerationError.pngEncoding }
    try data.write(to: output, options: .atomic)
    print("Preview: \(output.path)")
}

if let option = CommandLine.arguments.firstIndex(of: "--preview") {
    guard CommandLine.arguments.indices.contains(option + 1) else { throw GenerationError.missingPreviewPath }
    try preview(at: URL(fileURLWithPath: CommandLine.arguments[option + 1]))
}
