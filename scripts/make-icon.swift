// Renders AppIcon.icns for Prompter: a white waveform on a violet→indigo squircle.
// Run: swift scripts/make-icon.swift <output-dir>
// Produces <output-dir>/AppIcon.iconset/*.png and <output-dir>/AppIcon.icns (via iconutil).

import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build")
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: 1
    )
}

func draw(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let cg = gctx.cgContext
    let S = CGFloat(px)
    let u = S / 1024.0

    // Standard macOS icon grid: squircle inset ~100pt on a 1024 canvas.
    let margin = 100 * u
    let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let radius = 185 * u
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow behind the squircle (skip at tiny sizes — it just muddies).
    if px >= 64 {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 24 * u,
                     color: NSColor.black.withAlphaComponent(0.30).cgColor)
        cg.addPath(squircle)
        cg.setFillColor(rgb(0x3730A3).cgColor)
        cg.fillPath()
        cg.restoreGState()
    }

    cg.saveGState()
    cg.addPath(squircle)
    cg.clip()

    // Background: violet → indigo vertical gradient.
    let bg = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(0x7C3AED).cgColor, rgb(0x3730A3).cgColor] as CFArray,
        locations: [0, 1]
    )!
    cg.drawLinearGradient(bg, start: CGPoint(x: S / 2, y: rect.maxY), end: CGPoint(x: S / 2, y: rect.minY), options: [])

    // Soft radial glow behind the waveform.
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.white.withAlphaComponent(0.22).cgColor,
                 NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: S / 2, y: S / 2), startRadius: 0,
                          endCenter: CGPoint(x: S / 2, y: S / 2), endRadius: 430 * u, options: [])

    // Top sheen for a little depth.
    let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.white.withAlphaComponent(0.14).cgColor,
                 NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    cg.drawLinearGradient(sheen, start: CGPoint(x: S / 2, y: rect.maxY),
                          end: CGPoint(x: S / 2, y: rect.midY), options: [])

    // The waveform — same silhouette as the HUD pill.
    let heights: [CGFloat] = [0.16, 0.33, 0.52, 0.68, 0.52, 0.33, 0.16]
    let barW = 58 * u
    let gap = 42 * u
    let totalW = barW * CGFloat(heights.count) + gap * CGFloat(heights.count - 1)
    var x = (S - totalW) / 2

    cg.setShadow(offset: CGSize(width: 0, height: -5 * u), blur: 16 * u,
                 color: NSColor.black.withAlphaComponent(0.28).cgColor)
    cg.setFillColor(NSColor.white.cgColor)
    for h in heights {
        let bh = rect.height * h
        let bar = CGRect(x: x, y: (S - bh) / 2, width: barW, height: bh)
        cg.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        cg.fillPath()
        x += barW + gap
    }

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    let rep = draw(px: px)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(name).png"))
}

// Pack into .icns
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(outDir.appendingPathComponent("AppIcon.icns").path)")
