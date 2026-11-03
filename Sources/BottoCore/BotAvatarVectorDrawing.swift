import CoreGraphics

extension BotAvatarVectorPath {
    nonisolated public var cgPath: CGPath {
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero
        for command in commands {
            switch command {
            case .move(let x, let y):
                current = CGPoint(x: x, y: y); start = current; path.move(to: current)
            case .line(let x, let y):
                current = CGPoint(x: x, y: y); path.addLine(to: current)
            case .quadratic(let cx, let cy, let x, let y):
                current = CGPoint(x: x, y: y)
                path.addQuadCurve(to: current, control: CGPoint(x: cx, y: cy))
            case .cubic(let x1, let y1, let x2, let y2, let x, let y):
                current = CGPoint(x: x, y: y)
                path.addCurve(to: current, control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
            case .arc(let rx, let ry, let rotation, let large, let sweep, let x, let y):
                let end = CGPoint(x: x, y: y)
                Self.addArc(to: path, from: current, to: end, rx: rx, ry: ry,
                            rotation: rotation, large: large, sweep: sweep)
                current = end
            case .close:
                path.closeSubpath(); current = start
            }
        }
        return path
    }

    // SVG endpoint arcs become native ellipse arcs; curves are never flattened for painting.
    nonisolated private static func addArc(to path: CGMutablePath, from start: CGPoint, to end: CGPoint,
                               rx rawRX: Double, ry rawRY: Double, rotation: Double,
                               large: Bool, sweep: Bool) {
        guard rawRX != 0, rawRY != 0, start != end else { path.addLine(to: end); return }
        var rx = abs(rawRX), ry = abs(rawRY)
        let phi = rotation * .pi / 180, cosine = cos(phi), sine = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let xp = cosine * dx + sine * dy, yp = -sine * dx + cosine * dy
        let ratio = xp * xp / (rx * rx) + yp * yp / (ry * ry)
        if ratio > 1 { let scale = sqrt(ratio); rx *= scale; ry *= scale }
        let numerator = rx * rx * ry * ry - rx * rx * yp * yp - ry * ry * xp * xp
        let denominator = rx * rx * yp * yp + ry * ry * xp * xp
        var factor = sqrt(max(0, numerator / denominator))
        if large == sweep { factor = -factor }
        let cxp = factor * rx * yp / ry, cyp = -factor * ry * xp / rx
        let cx = cosine * cxp - sine * cyp + (start.x + end.x) / 2
        let cy = sine * cxp + cosine * cyp + (start.y + end.y) / 2
        let ux = (xp - cxp) / rx, uy = (yp - cyp) / ry
        let vx = (-xp - cxp) / rx, vy = (-yp - cyp) / ry
        let beginning = atan2(uy, ux)
        var delta = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let ellipse = CGAffineTransform(a: rx * cosine, b: rx * sine,
                                        c: -ry * sine, d: ry * cosine, tx: cx, ty: cy)
        path.addArc(center: .zero, radius: 1, startAngle: beginning,
                    endAngle: beginning + delta, clockwise: !sweep, transform: ellipse)
    }
}
