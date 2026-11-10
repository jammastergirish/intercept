import AppKit

// Renders the Intercept app mark (near-black squircle, ember ring around an
// ember record dot, in the One Tap Transcribe "Graphite & Ember" style) into a
// .iconset directory. build_app.sh runs this, then iconutil makes AppIcon.icns.

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(_ side: Int) -> NSBitmapImageRep {
    let s = CGFloat(side)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * 0.055
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    NSColor(srgbRed: 31/255, green: 31/255, blue: 30/255, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.23, yRadius: rect.width * 0.23).fill()

    let ember = NSColor(srgbRed: 232/255, green: 116/255, blue: 46/255, alpha: 1)
    let ringR = rect.width * 0.27
    let ring = NSBezierPath(ovalIn: NSRect(x: rect.midX - ringR, y: rect.midY - ringR, width: 2 * ringR, height: 2 * ringR))
    ring.lineWidth = rect.width * 0.055
    ember.setStroke()
    ring.stroke()

    let dotR = rect.width * 0.15
    ember.setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.midX - dotR, y: rect.midY - dotR, width: 2 * dotR, height: 2 * dotR)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in sizes {
    let rep = draw(px)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("wrote iconset to \(outDir)")
