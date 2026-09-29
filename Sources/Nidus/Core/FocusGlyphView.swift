//
//  FocusGlyphView.swift
//  Nidus
//
//  The menu bar glyph as Core Animation layers. Every transition is handed
//  to the render server once and interpolated there, frame by frame, at the
//  display's rate; nothing is redrawn per frame on our side. (Setting a new
//  status item image 60 times a second stutters: the menu bar is drawn in
//  another process and those updates are throttled.)
//
//  The shapes are FocusGlyph's, point for point, so a ribbon and its fold
//  have the same number of points and the path animation between them is
//  the morph itself. No DroppyKit import.
//

import AppKit
import QuartzCore

@MainActor
final class FocusGlyphView: NSView {
    /// What the glyph shows once any animation settles.
    private(set) var state = GlyphState.particle

    private let stage = CALayer()
    private let canvas = CALayer()
    private let fillLayer = CAShapeLayer()
    private let fillMask = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let ribbonLayers = (0..<5).map { _ in CAShapeLayer() }
    private let extraLayers = (0..<2).map { _ in CAShapeLayer() }
    private var generation = 0

    /// Ease in and out, close to the cubic the design mock used.
    static let ease = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)

    init(size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.addSublayer(stage)
        stage.frame = bounds
        stage.addSublayer(canvas)
        // A sublayer transform scales about the layer's anchor point. Anchor
        // the canvas at its corner, or the 24-unit drawing shrinks toward the
        // centre and lands 2.25pt off it (and clipped) at 18pt.
        canvas.anchorPoint = .zero
        canvas.frame = stage.bounds
        // The shapes are written y-down in a 24-unit square.
        canvas.isGeometryFlipped = true
        let k = size / FocusGlyph.unit
        canvas.sublayerTransform = CATransform3DMakeScale(k, k, 1)

        fillLayer.mask = fillMask
        fillLayer.opacity = 0.85
        for shape in [outlineLayer] + ribbonLayers + extraLayers {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
        }
        outlineLayer.lineWidth = 1.5
        extraLayers.forEach { $0.lineWidth = 1.3 }
        [fillLayer, outlineLayer].forEach(canvas.addSublayer)
        ribbonLayers.forEach(canvas.addSublayer)
        extraLayers.forEach(canvas.addSublayer)
        for (layer, fold) in zip(extraLayers, FocusGlyph.Geometry.extraFolds) {
            layer.path = Self.path(fold, closed: false)
        }
        apply(state, duration: 0)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks go through to the status item's button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    // MARK: Showing states

    /// Moves to `target` over `duration` (0 for at once), from wherever the
    /// glyph is on screen now, so an interrupted animation never jumps.
    func show(_ target: GlyphState, duration: CFTimeInterval, timing: CAMediaTimingFunction = FocusGlyphView.ease) {
        generation += 1
        apply(target, duration: duration, timing: timing)
    }

    /// Plays states one after another; `then` runs when the last settles,
    /// unless another show or sequence has replaced this one.
    func play(_ steps: [(GlyphState, CFTimeInterval)], then: (() -> Void)? = nil) {
        generation += 1
        run(steps[...], generation: generation, then: then)
    }

    /// A single sideways shake, for "that was blocked".
    func flinch() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        let k = bounds.width / FocusGlyph.unit
        a.values = [0, -1.2, 1.2, -0.8, 0.6, 0].map { $0 * k }
        a.duration = 0.3
        stage.add(a, forKey: "flinch")
    }

    private func run(_ steps: ArraySlice<(GlyphState, CFTimeInterval)>, generation: Int, then: (() -> Void)?) {
        guard generation == self.generation else { return }
        guard let (target, duration) = steps.first else { then?(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                self?.run(steps.dropFirst(), generation: generation, then: then)
            }
        }
        apply(target, duration: duration, timing: Self.ease)
        CATransaction.commit()
    }

    // MARK: Layers

    private func apply(_ s: GlyphState, duration: CFTimeInterval, timing: CAMediaTimingFunction = FocusGlyphView.ease) {
        state = s
        let g = FocusGlyph.Geometry.self
        let outline = Self.path(g.lerp(g.circle, g.brain, s.morph), closed: true)
        set(outlineLayer, "path", outline, duration, timing)
        set(fillLayer, "path", outline, duration, timing)
        for (i, layer) in ribbonLayers.enumerated() {
            set(layer, "path", Self.path(g.lerp(g.ribbons[i], g.folds[i], s.morph), closed: false), duration, timing)
            set(layer, "lineWidth", 1.5 - 0.2 * s.morph, duration, timing)
        }
        for layer in extraLayers {
            set(layer, "strokeEnd", s.detail, duration, timing)
            // A zero-length stroke still draws its round cap: hide it outright.
            set(layer, "opacity", s.detail > 0 ? 1 : 0, s.detail > 0 ? 0 : duration, timing)
        }
        // The fill rises from just above the outline's bottom to its top.
        let top = 21.5 - min(1, max(0, s.fill)) * 19.5
        set(fillMask, "path", CGPath(rect: CGRect(x: 0, y: top, width: FocusGlyph.unit, height: FocusGlyph.unit - top), transform: nil), duration, timing)
        set(canvas, "opacity", s.alpha, duration, timing)
        let k = bounds.width / FocusGlyph.unit
        var t = CATransform3DMakeTranslation(s.offsetX * k, 0, 0)
        t = CATransform3DScale(t, s.scale, s.scale, 1)
        set(stage, "transform", t, duration, timing)
    }

    /// Sets the model value and, when animating, animates to it from the
    /// value currently on screen.
    private func set(_ layer: CALayer, _ key: String, _ value: Any, _ duration: CFTimeInterval, _ timing: CAMediaTimingFunction) {
        let from = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
        guard duration > 0 else {
            layer.removeAnimation(forKey: key)
            return
        }
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = value
        a.duration = duration
        a.timingFunction = timing
        layer.add(a, forKey: key)
    }

    private func updateColors() {
        var ink = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = NSColor.labelColor.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.fillColor = ink
        fillMask.fillColor = CGColor(gray: 0, alpha: 1)
        for shape in [outlineLayer] + ribbonLayers + extraLayers { shape.strokeColor = ink }
        CATransaction.commit()
    }

    private static func path(_ points: [CGPoint], closed: Bool) -> CGPath {
        let p = CGMutablePath()
        guard let first = points.first else { return p }
        p.move(to: first)
        p.addLines(between: Array(points.dropFirst()))
        if closed { p.closeSubpath() }
        return p
    }
}
