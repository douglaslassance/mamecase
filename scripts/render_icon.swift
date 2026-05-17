#!/usr/bin/env swift
import AppKit
import Foundation

// Renders Mamecase's app icon: a rounded-rect background with the
// `gamecontroller.fill` SF Symbol centered in white. Produces all PNGs
// required by an `.iconset` directory.

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: render_icon.swift <output-iconset-dir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: CGFloat)] = [
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

@MainActor
func renderIcon(size pixels: CGFloat, to url: URL) {
    let size = NSSize(width: pixels, height: pixels)
    let canvas = NSImage(size: size)
    canvas.lockFocus()

    NSGraphicsContext.current?.imageInterpolation = .high

    // Rounded-rect background, accent blue-grey.
    let bg = NSColor(srgbRed: 0.12, green: 0.18, blue: 0.32, alpha: 1.0)
    let radius = pixels * 0.225
    let bgPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                              xRadius: radius, yRadius: radius)
    bg.setFill()
    bgPath.fill()

    // Centered gamecontroller glyph.
    let symbolPoint = pixels * 0.6
    let config = NSImage.SymbolConfiguration(pointSize: symbolPoint, weight: .regular)
        .applying(.init(hierarchicalColor: .white))
    if let glyph = NSImage(systemSymbolName: "gamecontroller.fill",
                           accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let gSize = glyph.size
        let origin = NSPoint(x: (pixels - gSize.width) / 2,
                             y: (pixels - gSize.height) / 2)
        glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode PNG for \(url.lastPathComponent)\n".utf8))
        return
    }
    try? png.write(to: url, options: .atomic)
}

await MainActor.run {
    for (name, pixels) in sizes {
        renderIcon(size: pixels, to: outDir.appendingPathComponent(name))
    }
}
