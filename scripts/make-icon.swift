// Renders the app icon: teal→indigo gradient squircle with a white waveform.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    fatalError("usage: make-icon.swift <output-dir>")
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let s = size
    // macOS icon grid: content squircle inset ~10% per side.
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.20, green: 0.62, blue: 0.86, alpha: 1),
        ending: NSColor(calibratedRed: 0.29, green: 0.27, blue: 0.74, alpha: 1)
    )
    gradient?.draw(in: squircle, angle: -60)

    // Waveform bars (symmetric heights), white with slight shadow.
    let barHeights: [CGFloat] = [0.18, 0.34, 0.52, 0.72, 0.46, 0.60, 0.30, 0.20]
    let barCount = CGFloat(barHeights.count)
    let zone = rect.insetBy(dx: rect.width * 0.17, dy: rect.height * 0.22)
    let gap = zone.width * 0.045
    let barWidth = (zone.width - gap * (barCount - 1)) / barCount

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = s * 0.012
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
    shadow.set()

    NSColor.white.setFill()
    for (i, h) in barHeights.enumerated() {
        let barHeight = zone.height * h
        let x = zone.minX + CGFloat(i) * (barWidth + gap)
        let y = zone.midY - barHeight / 2
        let bar = NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: barWidth, height: barHeight),
            xRadius: barWidth / 2, yRadius: barWidth / 2)
        bar.fill()
    }
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for px in sizes {
    let img = drawIcon(size: CGFloat(px))
    writePNG(img, pixels: px, to: outDir.appendingPathComponent("icon_\(px).png"))
}
print("wrote \(sizes.count) icons to \(outDir.path)")
