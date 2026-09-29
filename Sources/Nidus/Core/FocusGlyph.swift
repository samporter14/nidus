//
//  FocusGlyph.swift
//  Nidus
//
//  The menu bar mark. At rest it is a flavivirus particle: a ring with five
//  E-protein ribbons around the five-fold axis. While a session runs it is a
//  brain: the ring becomes the cortex outline, each ribbon bends into a fold,
//  two more folds draw in, and the brain fills from the bottom as time passes.
//
//  Every frame is a pure function of a GlyphState, drawn in a 24-unit square,
//  so the menu bar item, the spike and the tests all draw the same picture.
//  No DroppyKit import.
//

import AppKit

struct GlyphState: Equatable, Sendable {
    /// 0 is the particle, 1 the brain.
    var morph: Double = 0
    /// How much of the brain is filled, 0 to 1.
    var fill: Double = 0
    /// The two folds the particle has no ribbon for, 0 hidden to 1 drawn.
    var detail: Double = 0
    /// 1 normally; the paused brain is drawn faint.
    var alpha: Double = 1
    /// Horizontal nudge in glyph units, for the flinch.
    var offsetX: Double = 0
    /// Scale about the centre, for the pop.
    var scale: Double = 1

    static let particle = GlyphState()
    static let brain = GlyphState(morph: 1, detail: 1)
}

enum FocusGlyph {
    /// The glyph's coordinate space is 24 units square, like an SF Symbol's.
    static let unit: CGFloat = 24

    // MARK: Drawing

    /// Draws one frame into `size` points square. The context's origin is
    /// its bottom-left, as CoreGraphics' is.
    static func draw(_ state: GlyphState, in ctx: CGContext, size: CGFloat) {
        let k = size / unit
        ctx.saveGState()
        // Into the y-down 24-unit space the geometry is written in.
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: k, y: -k)
        ctx.translateBy(x: 12 + state.offsetX, y: 12)
        ctx.scaleBy(x: state.scale, y: state.scale)
        ctx.translateBy(x: -12, y: -12)
        ctx.setAlpha(state.alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(.black)
        ctx.setFillColor(.black)

        let t = clamp(state.morph)
        let outline = Geometry.lerp(Geometry.circle, Geometry.brain, t)

        if state.fill > 0 {
            // The fill rises from just above the outline's bottom to its top.
            let top = 21.5 - clamp(state.fill) * 19.5
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: top, width: unit, height: unit - top))
            ctx.addPath(path(outline, closed: true))
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.85))
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.setLineWidth(1.5)
        ctx.addPath(path(outline, closed: true))
        ctx.strokePath()

        ctx.setLineWidth(1.5 - 0.2 * t)
        for (ribbon, fold) in zip(Geometry.ribbons, Geometry.folds) {
            ctx.addPath(path(Geometry.lerp(ribbon, fold, t), closed: false))
            ctx.strokePath()
        }

        if state.detail > 0 {
            ctx.setLineWidth(1.3)
            for fold in Geometry.extraFolds {
                let count = max(2, Int((clamp(state.detail) * Double(fold.count - 1)).rounded()) + 1)
                ctx.addPath(path(Array(fold.prefix(count)), closed: false))
                ctx.strokePath()
            }
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// A template image for a status item: black on clear, tinted by the
    /// menu bar. Drawn again for each backing scale it is shown at.
    static func image(_ state: GlyphState, pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, in: ctx, size: pointSize)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A bitmap, for the spike's contact sheets and for tests.
    static func bitmap(_ state: GlyphState, pointSize: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int(pointSize * scale)
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(state, in: ctx, size: pointSize)
        return ctx.makeImage()
    }

    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    private static func path(_ points: [CGPoint], closed: Bool) -> CGPath {
        let p = CGMutablePath()
        guard let first = points.first else { return p }
        p.move(to: first)
        p.addLines(between: Array(points.dropFirst()))
        if closed { p.closeSubpath() }
        return p
    }

    // MARK: Geometry

    /// The shapes, resampled to matching point counts so any two can be
    /// interpolated point for point. Built once.
    enum Geometry {
        static let radius: CGFloat = 8.6
        static let centre = CGPoint(x: 12, y: 12)

        /// Points around a closed outline.
        static let outlineCount = 96
        /// Points along an open ribbon or fold.
        static let strokeCount = 40

        /// The particle's envelope, and the brain's cortex, aligned.
        static let circle: [CGPoint] = {
            var pts: [CGPoint] = []
            for i in 0..<outlineCount {
                let a = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(outlineCount)
                pts.append(CGPoint(x: centre.x + radius * cos(a), y: centre.y + radius * sin(a)))
            }
            return pts
        }()

        static let brain: [CGPoint] = align(
            resample(flatten(fit(SVGPath.parse(brainOutline))), count: outlineCount, closed: true),
            to: circle)

        /// Five E-protein ribbons around the five-fold axis, each bending into
        /// the fold it becomes.
        static let ribbons: [[CGPoint]] = (0..<5).map { i in
            resample(flatten(ribbon(index: i)), count: strokeCount, closed: false)
        }

        static let folds: [[CGPoint]] = zip(ribbons, ribbonToFold).map { ribbon, foldIndex in
            let fold = resample(flatten(fit(SVGPath.parse(foldPaths[foldIndex]))), count: strokeCount, closed: false)
            return distance(ribbon, fold.reversed()) < distance(ribbon, fold) ? fold.reversed() : fold
        }

        /// The folds with no ribbon to come from; they draw in after the morph.
        static let extraFolds: [[CGPoint]] = [2, 4].map {
            resample(flatten(fit(SVGPath.parse(foldPaths[$0]))), count: strokeCount, closed: false)
        }

        static func lerp(_ a: [CGPoint], _ b: [CGPoint], _ t: Double) -> [CGPoint] {
            if t <= 0 { return a }
            if t >= 1 { return b }
            let t = CGFloat(t)
            return zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * t, y: $0.y + ($1.y - $0.y) * t) }
        }

        // The brain, drawn in a 24 space and then scaled to fill the glyph.
        private static let brainOutline = "M4.6 14.2 C3.2 13.4 2.9 11.4 3.9 10.2 C3.2 8.6 4.2 6.8 5.9 6.6 C6.1 5 7.8 4 9.4 4.6 C10.4 3.3 12.4 3 13.7 4 C15 3.1 17.1 3.4 17.9 4.9 C19.6 5.1 20.9 6.7 20.6 8.4 C21.7 9.5 21.6 11.4 20.5 12.3 C20.6 13.9 19.3 15 17.9 14.9 C18 16.4 16.6 17.4 15.2 17.1 C14.3 17.9 12.9 17.9 12.2 17.1 C10.8 17.4 9.3 16.9 8.8 15.9 C7.4 16.4 5.6 15.7 4.6 14.2 Z"
        private static let foldPaths = [
            "M12.6 4.2 C11.7 5.6 13.2 6.8 12.2 8.4 C11.6 9.4 12.4 10.2 12 11.4",
            "M6.2 8.4 C7.6 8.2 8.4 9.4 7.8 10.6",
            "M9.4 5 C9.1 6.6 10.4 7.2 9.8 8.6",
            "M6.4 12.8 C8.2 12.2 9.6 13 11.2 12.4 C12.4 12 13.2 12.6 14.2 12.2",
            "M15.4 5 C14.6 6.4 16 7.4 15.2 8.8",
            "M17.6 8 C16.6 9 17.8 10.2 16.8 11.2",
            "M14.6 15.5 C15.8 15.9 17 15.8 18 15.2",
        ]
        /// Which fold each ribbon (clockwise from the top) bends into.
        private static let ribbonToFold = [0, 5, 6, 3, 1]

        private static func fit(_ segments: [SVGPath.Segment]) -> [SVGPath.Segment] {
            let s: CGFloat = 1.17
            func f(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - 12.3) * s + 12, y: (p.y - 10.45) * s + 12) }
            return segments.map { $0.mapPoints(f) }
        }

        private static func ribbon(index i: Int) -> [SVGPath.Segment] {
            let r0: CGFloat = 2.6, r2: CGFloat = 6.7, sweep: CGFloat = 58
            let a0 = CGFloat(i) * 72 - 90
            func pt(_ r: CGFloat, _ deg: CGFloat) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: centre.x + r * cos(a), y: centre.y + r * sin(a))
            }
            let p0 = pt(r0, a0), p1 = pt((r0 + r2) / 2, a0 + sweep * 0.45), p2 = pt(r2, a0 + sweep)
            let c = CGPoint(x: 2 * p1.x - (p0.x + p2.x) / 2, y: 2 * p1.y - (p0.y + p2.y) / 2)
            return [.move(p0), .quad(c, p2)]
        }

        // MARK: Sampling

        static func flatten(_ segments: [SVGPath.Segment], steps: Int = 24) -> [CGPoint] {
            var pts: [CGPoint] = []
            var current = CGPoint.zero
            for segment in segments {
                switch segment {
                case .move(let p):
                    pts.append(p); current = p
                case .line(let p):
                    pts.append(p); current = p
                case .quad(let c, let p):
                    for i in 1...steps {
                        let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                        pts.append(CGPoint(x: u * u * current.x + 2 * u * t * c.x + t * t * p.x,
                                           y: u * u * current.y + 2 * u * t * c.y + t * t * p.y))
                    }
                    current = p
                case .cubic(let c1, let c2, let p):
                    for i in 1...steps {
                        let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                        pts.append(CGPoint(
                            x: u * u * u * current.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p.x,
                            y: u * u * u * current.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p.y))
                    }
                    current = p
                case .close:
                    break
                }
            }
            return pts
        }

        /// `count` points spaced evenly by arc length. A closed shape gets no
        /// duplicate of its first point.
        static func resample(_ pts: [CGPoint], count: Int, closed: Bool) -> [CGPoint] {
            var poly = pts
            if closed, let first = pts.first { poly.append(first) }
            var cumulative: [CGFloat] = [0]
            for i in 1..<poly.count { cumulative.append(cumulative[i - 1] + hypot(poly[i].x - poly[i - 1].x, poly[i].y - poly[i - 1].y)) }
            let total = cumulative.last ?? 0
            var out: [CGPoint] = []
            var j = 0
            for i in 0..<count {
                let target = closed ? total * CGFloat(i) / CGFloat(count) : total * CGFloat(i) / CGFloat(count - 1)
                while j < poly.count - 2, cumulative[j + 1] < target { j += 1 }
                let span = cumulative[j + 1] - cumulative[j]
                let f = span > 0 ? (target - cumulative[j]) / span : 0
                out.append(CGPoint(x: poly[j].x + (poly[j + 1].x - poly[j].x) * f, y: poly[j].y + (poly[j + 1].y - poly[j].y) * f))
            }
            return out
        }

        /// Rotates and possibly reverses a closed outline so that each of its
        /// points moves the least to reach the other's.
        static func align(_ a: [CGPoint], to b: [CGPoint]) -> [CGPoint] {
            var best = a, bestDistance = CGFloat.greatestFiniteMagnitude
            for candidate in [a, a.reversed()] {
                for shift in 0..<candidate.count {
                    let rotated = Array(candidate[shift...] + candidate[..<shift])
                    let d = distance(rotated, b)
                    if d < bestDistance { bestDistance = d; best = rotated }
                }
            }
            return best
        }

        static func distance(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
            zip(a, b).reduce(0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) }
        }
    }
}

/// Enough of an SVG path parser for the shapes above: absolute M, L, Q, C
/// and Z, with space-separated coordinates.
enum SVGPath {
    enum Segment {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, CGPoint)
        case cubic(CGPoint, CGPoint, CGPoint)
        case close

        func mapPoints(_ f: (CGPoint) -> CGPoint) -> Segment {
            switch self {
            case .move(let p): return .move(f(p))
            case .line(let p): return .line(f(p))
            case .quad(let c, let p): return .quad(f(c), f(p))
            case .cubic(let a, let b, let p): return .cubic(f(a), f(b), f(p))
            case .close: return .close
            }
        }
    }

    static func parse(_ d: String) -> [Segment] {
        var segments: [Segment] = []
        var command: Character = "M"
        var numbers: [CGFloat] = []
        var token = ""

        func flush() {
            guard !token.isEmpty, let v = Double(token) else { token = ""; return }
            numbers.append(CGFloat(v)); token = ""
            emit()
        }
        func emit() {
            switch command {
            case "M" where numbers.count == 2: segments.append(.move(CGPoint(x: numbers[0], y: numbers[1]))); numbers = []
            case "L" where numbers.count == 2: segments.append(.line(CGPoint(x: numbers[0], y: numbers[1]))); numbers = []
            case "Q" where numbers.count == 4:
                segments.append(.quad(CGPoint(x: numbers[0], y: numbers[1]), CGPoint(x: numbers[2], y: numbers[3]))); numbers = []
            case "C" where numbers.count == 6:
                segments.append(.cubic(CGPoint(x: numbers[0], y: numbers[1]), CGPoint(x: numbers[2], y: numbers[3]),
                                       CGPoint(x: numbers[4], y: numbers[5]))); numbers = []
            default: break
            }
        }
        for ch in d {
            if ch.isLetter {
                flush()
                command = ch
                numbers = []
                if ch == "Z" { segments.append(.close) }
            } else if ch == " " || ch == "," {
                flush()
            } else if ch == "-", !token.isEmpty {
                flush(); token = "-"
            } else {
                token.append(ch)
            }
        }
        flush()
        return segments
    }
}
