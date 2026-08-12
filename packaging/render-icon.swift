// Rasterises packaging/AppIcon.svg into an .iconset for `iconutil`.
//
// AppKit reads SVG directly (macOS 13+), which keeps the icon a text file in
// the repo instead of a committed binary blob nobody can diff.
//
//   swift packaging/render-icon.swift <in.svg> <out.iconset>

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <in.svg> <out.iconset>\n".utf8))
    exit(2)
}
let source = URL(fileURLWithPath: arguments[1])
let iconset = URL(fileURLWithPath: arguments[2], isDirectory: true)

guard let data = try? Data(contentsOf: source), let image = NSImage(data: data) else {
    FileHandle.standardError.write(Data("render-icon: can't read \(source.path)\n".utf8))
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// The set `iconutil` expects: every point size at 1x and 2x.
let pointSizes = [16, 32, 128, 256, 512]

func write(pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "render-icon", code: 1)
    }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render-icon", code: 2)
    }
    try png.write(to: url)
}

for points in pointSizes {
    try write(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try write(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
