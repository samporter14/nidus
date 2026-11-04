import SwiftUI

/// The usual brain, with a resting expression during breaks. The transition
/// runs only when the state changes while visible; reopening a break shows
/// the settled mark immediately. No animation task or repeating clock.
struct FocusHeaderGlyph: View {
    let isOnBreak: Bool
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let brain = FocusGlyph.image(.brain, pointSize: 17)

    var body: some View {
        ZStack {
            if isOnBreak {
                RestingFocusShape()
                    .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 20, height: 20)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -2)),
                                            removal: .opacity))
            } else {
                Image(nsImage: Self.brain)
                    .renderingMode(.template)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.32), value: isOnBreak)
        .foregroundStyle(isPaused || isOnBreak ? Solanum.inkMuted : Solanum.clayText)
        .frame(width: 35, height: 35)
        .background(Solanum.clay.opacity(0.12), in: .rect(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Solanum.clay.opacity(0.22)))
        .accessibilityHidden(true)
    }
}

/// A soft brain outline with closed eyes, resting on one curved line.
private struct RestingFocusShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 4.5, y: 15.3))
        path.addCurve(to: CGPoint(x: 3.5, y: 9), control1: CGPoint(x: 1.6, y: 14.8), control2: CGPoint(x: 1.3, y: 10.4))
        path.addCurve(to: CGPoint(x: 8.2, y: 5.1), control1: CGPoint(x: 3.2, y: 5.6), control2: CGPoint(x: 6.2, y: 3.5))
        path.addCurve(to: CGPoint(x: 14, y: 4.2), control1: CGPoint(x: 9.4, y: 2.2), control2: CGPoint(x: 12.6, y: 2.5))
        path.addCurve(to: CGPoint(x: 19.4, y: 7.6), control1: CGPoint(x: 17.2, y: 2.8), control2: CGPoint(x: 19.8, y: 4.8))
        path.addCurve(to: CGPoint(x: 20, y: 14.9), control1: CGPoint(x: 22.8, y: 8.9), control2: CGPoint(x: 22.6, y: 13.3))
        path.addCurve(to: CGPoint(x: 4.5, y: 15.3), control1: CGPoint(x: 17.1, y: 18.7), control2: CGPoint(x: 7.4, y: 18.4))
        path.closeSubpath()
        path.move(to: CGPoint(x: 6.1, y: 11))
        path.addQuadCurve(to: CGPoint(x: 10.2, y: 11), control: CGPoint(x: 8.2, y: 13.6))
        path.move(to: CGPoint(x: 14.1, y: 11))
        path.addQuadCurve(to: CGPoint(x: 18.2, y: 11), control: CGPoint(x: 16.2, y: 13.6))
        path.move(to: CGPoint(x: 5, y: 20.3))
        path.addQuadCurve(to: CGPoint(x: 19, y: 20.3), control: CGPoint(x: 12, y: 22.8))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// A static seven-day row. Empty days stay as faint dots; there is no count,
/// target or animation, and the enclosing surface hides an entirely empty row.
struct FocusBotanicalStampRow: View {
    let week: FocusBotanicalWeek

    var body: some View {
        HStack(spacing: 2) {
            ForEach(week.days) { day in
                Group {
                    if day.hasSession {
                        BotanicalStampShape(variant: day.variant)
                            .stroke(style: StrokeStyle(lineWidth: 1.05, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(Solanum.clayText.opacity(0.8))
                    } else {
                        Circle().fill(Solanum.inkFaint.opacity(0.35)).frame(width: 2, height: 2)
                    }
                }
                .frame(width: 12, height: 16)
                .help(dayLabel(day))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(dayLabel(day))
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The past seven days")
        .transaction { $0.animation = nil }
    }

    private func dayLabel(_ day: FocusBotanicalWeek.Day) -> Text {
        Text("\(day.date, format: .dateTime.weekday(.wide).month(.abbreviated).day()): \(day.hasSession ? "a focus session finished" : "no session recorded")")
    }
}

private struct BotanicalStampShape: Shape {
    let variant: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 12, y: 22))
        path.addQuadCurve(to: CGPoint(x: 12, y: variant == 2 ? 8 : 3), control: CGPoint(x: 10, y: 12))
        func leaf(from stem: CGPoint, to tip: CGPoint, outward: CGPoint, inward: CGPoint) {
            path.move(to: stem)
            path.addQuadCurve(to: tip, control: outward)
            path.addQuadCurve(to: stem, control: inward)
        }
        if variant == 0 {
            leaf(from: CGPoint(x: 11, y: 15), to: CGPoint(x: 3, y: 7),
                 outward: CGPoint(x: 2, y: 16), inward: CGPoint(x: 12, y: 6))
            leaf(from: CGPoint(x: 11.4, y: 11), to: CGPoint(x: 21, y: 3),
                 outward: CGPoint(x: 12, y: 2), inward: CGPoint(x: 22, y: 12))
        } else if variant == 1 {
            for y in [9.0, 16.0] {
                leaf(from: CGPoint(x: 11, y: y), to: CGPoint(x: 3, y: y - 5),
                     outward: CGPoint(x: 4, y: y + 1), inward: CGPoint(x: 10, y: y - 6))
                leaf(from: CGPoint(x: 11, y: y + 2), to: CGPoint(x: 21, y: y - 3),
                     outward: CGPoint(x: 14, y: y - 6), inward: CGPoint(x: 22, y: y + 3))
            }
        } else {
            path.addEllipse(in: CGRect(x: 9, y: 4, width: 6, height: 6))
            for point in [CGPoint(x: 12, y: 1), CGPoint(x: 17, y: 4), CGPoint(x: 17, y: 10),
                          CGPoint(x: 12, y: 13), CGPoint(x: 7, y: 10), CGPoint(x: 7, y: 4)] {
                path.move(to: CGPoint(x: 12 + (point.x - 12) * 0.7, y: 7 + (point.y - 7) * 0.7))
                path.addLine(to: point)
            }
            leaf(from: CGPoint(x: 11, y: 18), to: CGPoint(x: 3, y: 13),
                 outward: CGPoint(x: 4, y: 19), inward: CGPoint(x: 10, y: 12))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
