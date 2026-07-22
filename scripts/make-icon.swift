// Builds Prompter's approved master artwork into a complete macOS iconset and
// AppIcon.icns. Run from the repository root:
//   swift scripts/make-icon.swift bundle

import AppKit
import Foundation

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "bundle",
    isDirectory: true
)
let sourceURL = outputDirectory.appendingPathComponent("AppIcon.png")
let iconsetURL = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let outputURL = outputDirectory.appendingPathComponent("AppIcon.icns")

guard let source = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write(Data("Could not load \(sourceURL.path)\n".utf8))
    exit(1)
}

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(
    at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in sizes {
    guard let bitmap = NSBitmapImageRep(
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
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "PrompterIcon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    source.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PrompterIcon", code: 2)
    }
    try png.write(to: iconsetURL.appendingPathComponent("\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

print("Wrote \(outputURL.path)")
