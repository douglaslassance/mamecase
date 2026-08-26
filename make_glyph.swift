#!/usr/bin/env swift
// Render Mamecase's picto (the `gamecontroller.fill` SF Symbol) as a
// 1024x1024 alpha mask for the Icon Composer document. The layer in
// AppIcon.icon/icon.json paints it, one colour per appearance, so this file
// only carries the shape.
//
// Run via ./build_icons.sh, or on its own:
//
//   swift make_glyph.swift

import AppKit
import Foundation

let symbolName = "gamecontroller.fill"
/// Fraction of the canvas the symbol's point size covers. Matches the 0.55
/// the flat icon used, so the mark keeps its proportions.
let glyphScale: CGFloat = 0.55
let canvas = 1024

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputURL = repoRoot.appendingPathComponent("AppIcon.icon/Assets/gamecontroller.png")

guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
    FileHandle.standardError.write("symbol \(symbolName) unavailable\n".data(using: .utf8)!)
    exit(1)
}

// Solid white: only the alpha matters, the icon layer supplies the colour.
let config = NSImage.SymbolConfiguration(pointSize: CGFloat(canvas) * glyphScale, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let configured = symbol.withSymbolConfiguration(config) ?? symbol

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
rep.size = NSSize(width: canvas, height: canvas)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let glyphSize = configured.size
configured.draw(
    in: NSRect(x: (CGFloat(canvas) - glyphSize.width) / 2,
               y: (CGFloat(canvas) - glyphSize.height) / 2,
               width: glyphSize.width, height: glyphSize.height),
    from: .zero, operation: .sourceOver, fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: outputURL)
print("wrote \(outputURL.path) (\(canvas)x\(canvas))")
