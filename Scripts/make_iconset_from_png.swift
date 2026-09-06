import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: make_iconset_from_png <source.png> <output.iconset>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = NSImage(contentsOf: sourceURL) else {
    fputs("Could not read source image: \(sourceURL.path)\n", stderr)
    exit(1)
}

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

func render(size: Int) -> NSImage {
    let edge = CGFloat(size)
    let image = NSImage(size: NSSize(width: edge, height: edge))
    image.lockFocus()
    NSColor.clear.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: edge, height: edge)).fill()

    let rounded = NSBezierPath(
        roundedRect: CGRect(x: edge * 0.055, y: edge * 0.055, width: edge * 0.89, height: edge * 0.89),
        xRadius: edge * 0.20,
        yRadius: edge * 0.20
    )
    rounded.addClip()
    source.draw(
        in: CGRect(x: 0, y: 0, width: edge, height: edge),
        from: CGRect(origin: .zero, size: source.size),
        operation: .sourceOver,
        fraction: 1.0
    )

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
    try savePNG(render(size: size), to: outputURL.appendingPathComponent(name))
}
