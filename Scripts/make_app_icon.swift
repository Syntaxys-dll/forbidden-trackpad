import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset"
let outputURL = URL(fileURLWithPath: output)
try? FileManager.default.removeItem(at: outputURL)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
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

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawForbiddenWord(scale: CGFloat) {
    let word = "FORBIDDEN" as NSString
    let font = NSFont(name: "HelveticaNeue-CondensedBlack", size: scale * 0.092)
        ?? NSFont.systemFont(ofSize: scale * 0.088, weight: .black)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let textRect = CGRect(x: scale * 0.08, y: scale * 0.735, width: scale * 0.84, height: scale * 0.12)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.black.withAlphaComponent(0.86),
        .strokeColor: NSColor.black.withAlphaComponent(0.96),
        .strokeWidth: -2.4,
        .kern: scale * 0.002,
        .paragraphStyle: paragraph
    ]

    word.draw(in: textRect, withAttributes: attributes)
}

func drawIcon(size: Int) -> NSImage {
    let scale = CGFloat(size)
    let image = NSImage(size: NSSize(width: scale, height: scale))
    image.lockFocus()

    let bounds = CGRect(x: 0, y: 0, width: scale, height: scale)
    NSGraphicsContext.current?.imageInterpolation = .high

    let bg = roundedRect(bounds.insetBy(dx: scale * 0.055, dy: scale * 0.055), radius: scale * 0.22)
    NSColor(calibratedWhite: 0.985, alpha: 1).setFill()
    bg.fill()

    NSColor.black.withAlphaComponent(0.08).setStroke()
    bg.lineWidth = max(1, scale * 0.006)
    bg.stroke()

    drawForbiddenWord(scale: scale)

    let padRect = CGRect(x: scale * 0.17, y: scale * 0.19, width: scale * 0.66, height: scale * 0.45)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
    shadow.shadowBlurRadius = scale * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -scale * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()

    let pad = roundedRect(padRect, radius: scale * 0.075)
    NSColor(calibratedWhite: 0.935, alpha: 1).setFill()
    pad.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.black.withAlphaComponent(0.30).setStroke()
    pad.lineWidth = max(1, scale * 0.012)
    pad.stroke()

    let topLine = NSBezierPath()
    topLine.move(to: CGPoint(x: padRect.minX + padRect.width * 0.12, y: padRect.maxY - padRect.height * 0.22))
    topLine.line(to: CGPoint(x: padRect.maxX - padRect.width * 0.12, y: padRect.maxY - padRect.height * 0.22))
    NSColor.black.withAlphaComponent(0.22).setStroke()
    topLine.lineWidth = max(1, scale * 0.01)
    topLine.lineCapStyle = .round
    topLine.stroke()

    let clickLine = NSBezierPath()
    clickLine.move(to: CGPoint(x: padRect.midX, y: padRect.minY + padRect.height * 0.08))
    clickLine.line(to: CGPoint(x: padRect.midX, y: padRect.minY + padRect.height * 0.24))
    NSColor.black.withAlphaComponent(0.18).setStroke()
    clickLine.lineWidth = max(1, scale * 0.008)
    clickLine.lineCapStyle = .round
    clickLine.stroke()

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 1)
    }
    try png.write(to: url)
}

for (name, size) in sizes {
    try savePNG(drawIcon(size: size), to: outputURL.appendingPathComponent(name))
}
