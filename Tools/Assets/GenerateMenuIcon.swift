#!/usr/bin/env -S swift -swift-version 6
import AppKit
import Foundation

// Run from the repository root:
// swift -swift-version 6 Tools/Assets/GenerateMenuIcon.swift
// Use --output-directory PATH to inspect exports without replacing app resources.

let directory = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent()
let root = directory.deletingLastPathComponent().deletingLastPathComponent()
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--output-directory") else {
    fatalError("Usage: GenerateMenuIcon.swift [--output-directory PATH]")
}
let output = arguments.isEmpty
    ? root.appending(path: "TranslateX/Resources/Assets.xcassets/MenuBarIcon.imageset")
    : URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
guard let artwork = NSImage(contentsOf: directory.appending(path: "MenuBarIcon.svg")) else {
    fatalError("Cannot read MenuBarIcon.svg")
}
for scale in [1, 2] {
    let pixels = 18 * scale
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32
    )?.converting(to: .sRGB, renderingIntent: .default),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot allocate menu icon")
    }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode menu icon")
    }
    let name = "MenuBarIcon\(scale == 2 ? "@2x" : "").png"
    try data.write(to: output.appending(path: name), options: .atomic)
}
print("Exported the menu template at 18 and 36 px")
