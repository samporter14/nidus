import AppKit
// Nidus's product icon in the Solanum family (README, Iconography): the
// mark's broken ring on tile-amber, and the five ribbons of Nidus's own glyph
// at scale(10) — ring radius 8.6 becomes 86, the interior strokes 9 units.
// No escapee: Nidus is the exception. Drawn in the mark's 200-unit box.
// render <out.png> <pixels> <layer: tile|ring|ribbons|glyph|all>, or render svg
@main enum Render {
    static func main() {
        let a = CommandLine.arguments
        if a[1] == "svg" {
            // The ribbons as SVG path data in the 200-unit box, for the block page.
            let c = FocusGlyph.Geometry.centre
            print(FocusGlyph.Geometry.ribbons.map { ribbon in
                ribbon.enumerated().map { i, p in
                    (i == 0 ? "M" : "L") + String(format: "%.1f %.1f", 100 + (p.x - c.x) * 10, 100 + (p.y - c.y) * 10)
                }.joined()
            }.joined(separator: "\n"))
            return
        }
        let px = Int(a[2])!, layer = a[3]
        let ink = CGColor(srgbRed: 0x14/255.0, green: 0x14/255.0, blue: 0x13/255.0, alpha: 1)
        let amber = CGColor(srgbRed: 0xD9/255.0, green: 0xA4/255.0, blue: 0x41/255.0, alpha: 1)
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let size = CGFloat(px)
        if layer == "tile" || layer == "all" {
            let r = size * 0.22
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size), cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.setFillColor(amber); ctx.fillPath()
        }
        let box = size * 330 / 512, origin = (size - box) / 2, k = box / 200
        ctx.translateBy(x: origin, y: size - origin); ctx.scaleBy(x: k, y: -k)
        ctx.setStrokeColor(ink); ctx.setFillColor(ink); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        if ["ring", "all", "glyph"].contains(layer) {
            // Exactly the mark's: centre (100,100), r 86, the gap at the upper right.
            let ring = CGMutablePath()
            let start = atan2(39.19 - 100, 160.81 - 100), end = atan2(16.93 - 100, 122.26 - 100)
            ring.addArc(center: CGPoint(x: 100, y: 100), radius: 86, startAngle: start, endAngle: end, clockwise: false)
            ctx.setLineWidth(7); ctx.addPath(ring); ctx.strokePath()
        }
        if ["ribbons", "all", "glyph"].contains(layer) {
            ctx.setLineWidth(9)
            let c = FocusGlyph.Geometry.centre
            for ribbon in FocusGlyph.Geometry.ribbons {
                let p = CGMutablePath()
                p.addLines(between: ribbon.map { CGPoint(x: 100 + ($0.x - c.x) * 10, y: 100 + ($0.y - c.y) * 10) })
                ctx.addPath(p); ctx.strokePath()
            }
        }
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
    }
}
