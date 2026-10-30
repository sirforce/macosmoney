// Draws the MacMoney app icon (the "Gold Coin") at 1024×1024.
// Usage: swift tools/icon/AppIcon.swift <output-folder>   (normally run via tools/icon/make-icons.sh)
import AppKit

let out = CommandLine.arguments[1]
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: a)
}
func grad(_ c: [CGColor], _ loc: [CGFloat]? = nil) -> CGGradient { CGGradient(colorsSpace: srgb, colors: c as CFArray, locations: loc)! }
func rr(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

func render(_ name: String, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    draw(g.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

/// macOS-style squircle with drop shadow, diagonal gradient and a soft top gloss.
func base(_ ctx: CGContext, _ colors: [UInt32]) {
    let path = rr(body, 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: hex(0, 0.38))
    ctx.addPath(path); ctx.setFillColor(hex(colors[0])); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(grad(colors.map { hex($0) }), start: CGPoint(x: 140, y: 900), end: CGPoint(x: 884, y: 124), options: [])
    ctx.drawLinearGradient(grad([hex(0xffffff, 0.22), hex(0xffffff, 0)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(rr(body.insetBy(dx: 2, dy: 2), 184)); ctx.setStrokeColor(hex(0xffffff, 0.18)); ctx.setLineWidth(4); ctx.strokePath(); ctx.restoreGState()
}

func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .black) -> NSFont {
    let f = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: f.fontDescriptor.withDesign(.rounded) ?? f.fontDescriptor, size: size) ?? f
}
func glyph(_ s: String, _ font: NSFont, _ color: CGColor, center: CGPoint, shadow: CGColor? = nil, offset: CGSize = CGSize(width: 0, height: -8), blur: CGFloat = 16) {
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!])
    let size = attr.size()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    if let shadow { ctx.setShadow(offset: offset, blur: blur, color: shadow) }
    attr.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2 + font.descender / 2.2))
    ctx.restoreGState()
}
func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }
func sparkle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: CGColor) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
    ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath()
}

// 1 · Gold Coin
render("AppIcon-1024") { ctx in
    base(ctx, [0x13C8B5, 0x2E6FE0, 0x4B33C8])
    let c = CGPoint(x: 512, y: 500)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 40, color: hex(0x0B1150, 0.55))
    ctx.addEllipse(in: circle(c, 282)); ctx.setFillColor(hex(0xF29D00)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addEllipse(in: circle(c, 282)); ctx.clip()
    ctx.drawLinearGradient(grad([hex(0xFFF1A6), hex(0xFFC21A), hex(0xE08600)]), start: CGPoint(x: 330, y: 780), end: CGPoint(x: 700, y: 220), options: [])
    ctx.restoreGState()
    ctx.saveGState(); ctx.addEllipse(in: circle(c, 232)); ctx.clip()
    ctx.drawLinearGradient(grad([hex(0xF2A100), hex(0xFFD54A), hex(0xFFE88A)]), start: CGPoint(x: 330, y: 730), end: CGPoint(x: 690, y: 270), options: [])
    ctx.restoreGState()
    ctx.addEllipse(in: circle(c, 232)); ctx.setStrokeColor(hex(0xC77400, 0.65)); ctx.setLineWidth(10); ctx.strokePath()
    glyph("$", rounded(340), hex(0xFFF6CC, 0.9), center: CGPoint(x: c.x - 4, y: c.y + 4))
    glyph("$", rounded(340), hex(0xB36200), center: c, shadow: hex(0x7A3D00, 0.35), offset: CGSize(width: 0, height: -4), blur: 6)
    sparkle(ctx, CGPoint(x: 740, y: 760), 62, hex(0xffffff, 0.95))
    sparkle(ctx, CGPoint(x: 800, y: 660), 30, hex(0xffffff, 0.8))
}

print("done")
