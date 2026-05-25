#!/usr/bin/env swift
// Renders Mamecase's app icon: an off-white squircle with the
// `gamecontroller.fill` SF Symbol centered in near-black. Produces all
// PNGs required by an `.iconset` directory.
//
// Usage (driven by bundle.sh):
//   swift render_icon.swift <output-iconset-dir>

import AppKit
import Foundation

let symbolName = "gamecontroller.fill"
let backgroundColor = NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
let foregroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: render_icon.swift <output-iconset-dir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func renderPNG(pixelSize: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixelSize)
    let cornerRadius = size * 0.225
    let bg = NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
        xRadius: cornerRadius,
        yRadius: cornerRadius
    )
    backgroundColor.setFill()
    bg.fill()

    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
        return rep.representation(using: .png, properties: [:])
    }
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [foregroundColor]))
    let configured = symbol.withSymbolConfiguration(config) ?? symbol
    let symbolSize = configured.size
    let symbolRect = NSRect(
        x: (size - symbolSize.width) / 2,
        y: (size - symbolSize.height) / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )
    configured.draw(in: symbolRect)

    return rep.representation(using: .png, properties: [:])
}

for (name, pixels) in sizes {
    guard let data = renderPNG(pixelSize: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outDir.appendingPathComponent(name))
}
