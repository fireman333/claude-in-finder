// Generates AppIcon.icns and DocumentIcon.icns with CoreGraphics, so the project
// needs no image assets checked in and no Xcode asset catalog.
import AppKit
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

let terracotta = NSColor(srgbRed: 0.788, green: 0.392, blue: 0.259, alpha: 1)  // #c96442
let paper      = NSColor(srgbRed: 0.99,  green: 0.98,  blue: 0.97,  alpha: 1)
let ink        = NSColor(srgbRed: 0.16,  green: 0.16,  blue: 0.18,  alpha: 1)

func roundedRect(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

/// The app icon: a terracotta tile with a chat bubble cut out of it.
func drawApp(_ size: CGFloat) {
    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    terracotta.setFill()
    roundedRect(rect, size * 0.225).fill()

    let w = rect.width * 0.58, h = rect.height * 0.44
    let bubble = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2 + rect.height * 0.05,
                        width: w, height: h)
    paper.setFill()
    roundedRect(bubble, h * 0.28).fill()

    // tail
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: bubble.minX + bubble.width * 0.22, y: bubble.minY + 1))
    tail.line(to: NSPoint(x: bubble.minX + bubble.width * 0.20, y: bubble.minY - h * 0.30))
    tail.line(to: NSPoint(x: bubble.minX + bubble.width * 0.50, y: bubble.minY + 1))
    tail.close()
    tail.fill()

    terracotta.setFill()
    for i in 0..<3 {
        let d = bubble.height * 0.13
        let x = bubble.minX + bubble.width * (0.27 + Double(i) * 0.20) - d / 2
        NSBezierPath(ovalIn: NSRect(x: x, y: bubble.midY - d / 2, width: d, height: d)).fill()
    }
}

/// The document icon: a page with a folded corner and a terracotta band.
func drawDoc(_ size: CGFloat) {
    let w = size * 0.72, h = size * 0.86
    let rect = NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h)
    let fold = w * 0.26

    let page = NSBezierPath()
    page.move(to: NSPoint(x: rect.minX, y: rect.minY))
    page.line(to: NSPoint(x: rect.minX, y: rect.maxY))
    page.line(to: NSPoint(x: rect.maxX - fold, y: rect.maxY))
    page.line(to: NSPoint(x: rect.maxX, y: rect.maxY - fold))
    page.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    page.close()
    paper.setFill(); page.fill()
    ink.withAlphaComponent(0.18).setStroke(); page.lineWidth = max(1, size * 0.006); page.stroke()

    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: rect.maxX - fold, y: rect.maxY))
    corner.line(to: NSPoint(x: rect.maxX - fold, y: rect.maxY - fold))
    corner.line(to: NSPoint(x: rect.maxX, y: rect.maxY - fold))
    corner.close()
    ink.withAlphaComponent(0.12).setFill(); corner.fill()

    terracotta.setFill()
    let band = NSRect(x: rect.minX + w * 0.14, y: rect.minY + h * 0.16,
                      width: w * 0.72, height: h * 0.10)
    roundedRect(band, band.height / 2).fill()

    ink.withAlphaComponent(0.22).setFill()
    for i in 0..<4 {
        let y = rect.minY + h * (0.36 + Double(i) * 0.11)
        let lw = w * (i == 3 ? 0.42 : 0.72)
        roundedRect(NSRect(x: rect.minX + w * 0.14, y: y, width: lw, height: h * 0.035),
                    h * 0.018).fill()
    }
}

func makeIconset(name: String, draw: @escaping (CGFloat) -> Void) throws {
    let dir = outDir.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let specs: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
    for (pt, scale) in specs {
        let px = pt * scale
        let image = NSImage(size: NSSize(width: px, height: px))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(CGFloat(px))
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        let suffix = scale == 1 ? "" : "@2x"
        try png.write(to: dir.appendingPathComponent("icon_\(pt)x\(pt)\(suffix).png"))
    }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", dir.path, "-o", outDir.appendingPathComponent("\(name).icns").path]
    try p.run(); p.waitUntilExit()
    try? FileManager.default.removeItem(at: dir)
    print("wrote \(name).icns")
}

try makeIconset(name: "AppIcon", draw: drawApp)
try makeIconset(name: "DocumentIcon", draw: drawDoc)
