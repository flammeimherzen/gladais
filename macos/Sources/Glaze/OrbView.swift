import SwiftUI

struct GlazeBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Color(red: 0.035, green: 0.04, blue: 0.055)
                Circle()
                    .fill(Color(red: 0.86, green: 0.62, blue: 0.28).opacity(0.22))
                    .frame(width: 560, height: 560)
                    .blur(radius: 90)
                    .offset(x: CGFloat(sin(time * 0.13)) * 90, y: -80 + CGFloat(cos(time * 0.1)) * 30)
                Circle()
                    .fill(Color(red: 0.42, green: 0.62, blue: 0.74).opacity(0.16))
                    .frame(width: 460, height: 460)
                    .blur(radius: 100)
                    .offset(x: -180, y: 160 + CGFloat(sin(time * 0.11)) * 40)
            }
        }
        .ignoresSafeArea()
    }
}

struct GlazeOrb: View {
    var level: CGFloat
    var phase: Phase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let half = min(size.width, size.height) / 2
                // The glow must hit full transparency before the canvas edge.
                // A blur that reaches the edge gets cut into a square.
                let radius = half * 0.34
                let pulse = 1 + level * 0.08 + (phase == .thinking ? CGFloat(sin(time * 2.2)) * 0.015 : 0)
                drawHalo(context, center: center, radius: radius * pulse, outer: half * 0.92)
                drawRings(context, center: center, radius: radius, time: time)
                drawCore(context, center: center, radius: radius * 0.72 * pulse, time: time)
                drawOrbit(context, center: center, radius: radius * 0.95, time: time)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var accent: Color {
        switch phase {
        case .listening: Color(red: 0.96, green: 0.74, blue: 0.42)
        case .thinking: Color(red: 0.62, green: 0.78, blue: 0.86)
        case .speaking: Color(red: 0.98, green: 0.9, blue: 0.74)
        case .transcribing: Color(red: 0.9, green: 0.78, blue: 0.55)
        default: Color(red: 0.93, green: 0.86, blue: 0.74)
        }
    }

    private func drawHalo(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, outer: CGFloat) {
        let rect = CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2)
        let glow = max(0.15, 0.34 + level * 0.2)
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: accent.opacity(glow), location: radius / outer),
                    .init(color: accent.opacity(glow * 0.35), location: min(0.72, (radius * 1.35) / outer)),
                    .init(color: accent.opacity(0), location: 1)
                ]),
                center: center,
                startRadius: 0,
                endRadius: outer
            )
        )
    }

    private func drawRings(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, time: Double) {
        for index in 0..<3 {
            var ring = Path()
            let spread = radius * (1.05 + CGFloat(index) * 0.16 + level * 0.12)
            let width = radius * 0.018
            ring.addEllipse(in: CGRect(x: center.x - spread, y: center.y - spread, width: spread * 2, height: spread * 2))
            var local = context
            local.translateBy(x: center.x, y: center.y)
            local.rotate(by: .degrees(time * (8 + Double(index) * 6) * (index.isMultiple(of: 2) ? 1 : -1)))
            local.translateBy(x: -center.x, y: -center.y)
            local.stroke(
                ring,
                with: .color(accent.opacity(0.28 - Double(index) * 0.07)),
                style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [18, 14 + CGFloat(index) * 8])
            )
        }
    }

    private func drawCore(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, time: Double) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let colors: [Color] = [
            Color(red: 1, green: 0.96, blue: 0.9),
            accent,
            Color(red: 0.18, green: 0.16, blue: 0.14)
        ]
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: colors),
                center: CGPoint(x: center.x - radius * 0.15, y: center.y - radius * 0.2),
                startRadius: 4,
                endRadius: radius
            )
        )
        let sheen = CGRect(
            x: center.x - radius * 0.42,
            y: center.y - radius * 0.55 + CGFloat(sin(time * 0.8)) * 4,
            width: radius * 0.7,
            height: radius * 0.38
        )
        var gloss = context
        gloss.addFilter(.blur(radius: 6))
        gloss.fill(Path(ellipseIn: sheen), with: .color(.white.opacity(0.55)))
        context.stroke(Path(ellipseIn: rect.insetBy(dx: 1.5, dy: 1.5)), with: .color(.white.opacity(0.35)), lineWidth: 1.2)
    }

    private func drawOrbit(_ context: GraphicsContext, center: CGPoint, radius: CGFloat, time: Double) {
        let count = 9
        for index in 0..<count {
            let angle = time * 0.6 + Double(index) / Double(count) * .pi * 2
            let wobble = radius + CGFloat(sin(time * 1.7 + Double(index))) * (8 + level * 18)
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle)) * wobble,
                y: center.y + CGFloat(sin(angle)) * wobble * 0.92
            )
            let dot = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.75)))
        }
    }
}
