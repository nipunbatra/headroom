// Draws the Headroom icon (four rising meter bars) to a 1024px PNG.
// Usage: swift app/make_icon.swift out.png
import Cocoa

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func rgb(_ hex: Int) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
NSGradient(starting: rgb(0x262b35), ending: rgb(0x12151a))!.draw(in: tile, angle: -90)
let bars: [(Int, Double)] = [(0x0ca30c, 0.34), (0x2a78d6, 0.52), (0xfab219, 0.72), (0xd03b3b, 0.92)]
let inner = plate.insetBy(dx: 150, dy: 150), gap = 40.0
let w = (Double(inner.width) - gap * 3) / 4
for (i, bar) in bars.enumerated() {
    let r = NSRect(x: Double(inner.minX) + Double(i) * (w + gap), y: Double(inner.minY), width: w,
                   height: Double(inner.height) * bar.1)
    rgb(bar.0).setFill()
    NSBezierPath(roundedRect: r, xRadius: 34, yRadius: 34).fill()
}
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
