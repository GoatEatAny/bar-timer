// Draws the app icon into an .iconset. Called from build.sh:
//
//   swiftc icon.swift -o .build/icon && .build/icon <output.iconset>
//
// The icon is drawn from code on every build, so the repository holds no image files.
// It matches the menu bar: a white bar with 7 of its 10 cells left, on a dark rounded square.
import AppKit

let segments = 10
let lit = 7

func draw(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Drawn on a 1024 grid and scaled. macOS icons keep the body within 824 points, with a margin around it.
    let k = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    NSGradient(starting: NSColor(white: 0.20, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k), angle: -90)

    let frame = NSRect(x: 192 * k, y: 412 * k, width: 640 * k, height: 200 * k)
    let outline = NSBezierPath(roundedRect: frame, xRadius: 40 * k, yRadius: 40 * k)
    outline.lineWidth = 20 * k
    NSColor(white: 1, alpha: 0.6).setStroke()
    outline.stroke()

    let inner = frame.insetBy(dx: 40 * k, dy: 40 * k)
    let gap = 14 * k
    let cell = (inner.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
    NSColor.white.setFill()
    for i in 0..<lit {
        NSBezierPath(roundedRect: NSRect(x: inner.minX + CGFloat(i) * (cell + gap), y: inner.minY,
                                         width: cell, height: inner.height),
                     xRadius: 10 * k, yRadius: 10 * k).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try draw(pixels: size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(pixels: size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
