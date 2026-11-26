import Foundation
import simd

/// Geometry: canvas (unit square) -> output window, and canvas -> source picture.
enum Warp {
    /// Corners (BL, BR, TR, TL) that fit a picture of videoAspect inside a window of viewAspect.
    static func fitCorners(viewAspect: Double, videoAspect: Double) -> [Double] {
        var w = 1.0, h = 1.0
        if videoAspect > 0 && viewAspect > 0 {
            if videoAspect > viewAspect { h = viewAspect / videoAspect } else { w = videoAspect / viewAspect }
        }
        let x0 = (1 - w) / 2, y0 = (1 - h) / 2
        return [x0, y0, x0 + w, y0, x0 + w, y0 + h, x0, y0 + h]
    }

    static func corners(_ s: DisplaySettings, viewAspect: Double, videoAspect: Double) -> [Double] {
        s.corners ?? fitCorners(viewAspect: viewAspect, videoAspect: videoAspect)
    }

    /// Projective map of the unit square onto the quad (Heckbert's square-to-quad).
    struct Homography {
        let a, b, c, d, e, f, g, h: Double
        init(_ q: [Double]) {
            let x0 = q[0], y0 = q[1], x1 = q[2], y1 = q[3], x2 = q[4], y2 = q[5], x3 = q[6], y3 = q[7]
            let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
            let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
            let den = dx1 * dy2 - dx2 * dy1
            if (abs(dx3) < 1e-12 && abs(dy3) < 1e-12) || abs(den) < 1e-12 {
                a = x1 - x0; b = x3 - x0; c = x0
                d = y1 - y0; e = y3 - y0; f = y0
                g = 0; h = 0
            } else {
                g = (dx3 * dy2 - dx2 * dy3) / den
                h = (dx1 * dy3 - dx3 * dy1) / den
                a = x1 - x0 + g * x1; b = x3 - x0 + h * x3; c = x0
                d = y1 - y0 + g * y1; e = y3 - y0 + h * y3; f = y0
            }
        }
        /// Inverse: the unit-square point that maps to (x, y), nil when there is none.
        func unmap(_ x: Double, _ y: Double) -> SIMD2<Double>? {
            let a11 = a - g * x, a12 = b - h * x, b1 = x - c
            let a21 = d - g * y, a22 = e - h * y, b2 = y - f
            let det = a11 * a22 - a12 * a21
            guard abs(det) > 1e-12 else { return nil }
            return SIMD2((b1 * a22 - a12 * b2) / det, (a11 * b2 - a21 * b1) / det)
        }
        func map(_ u: Double, _ v: Double) -> SIMD2<Double> {
            let w = g * u + h * v + 1
            return SIMD2((a * u + b * v + c) / w, (d * u + e * v + f) / w)
        }
    }

    private static func catmull(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
        let t2 = t * t, t3 = t2 * t
        return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
    }

    /// Smooth (Catmull-Rom) mesh offset at canvas point (u,v).
    static func meshOffset(_ s: DisplaySettings, _ m: [Double], _ u: Double, _ v: Double) -> SIMD2<Double> {
        let cols = s.meshCols, rows = s.meshRows
        if m.allSatisfy({ $0 == 0 }) { return .zero }
        let fx = u * Double(cols), fy = v * Double(rows)
        let ix = min(cols - 1, max(0, Int(floor(fx)))), iy = min(rows - 1, max(0, Int(floor(fy))))
        let tx = fx - Double(ix), ty = fy - Double(iy)
        func node(_ i: Int, _ j: Int, _ k: Int) -> Double {
            let ci = min(cols, max(0, i)), cj = min(rows, max(0, j))
            return m[(cj * (cols + 1) + ci) * 2 + k]
        }
        var out = SIMD2<Double>(0, 0)
        for k in 0..<2 {
            var col = [Double](repeating: 0, count: 4)
            for r in 0..<4 {
                let j = iy - 1 + r
                col[r] = catmull(node(ix - 1, j, k), node(ix, j, k), node(ix + 1, j, k), node(ix + 2, j, k), tx)
            }
            out[k] = catmull(col[0], col[1], col[2], col[3], ty)
        }
        return out
    }

    /// Where canvas point (u,v) lands in the window.
    static func output(_ s: DisplaySettings, _ H: Homography, _ m: [Double], _ u: Double, _ v: Double) -> SIMD2<Double> {
        H.map(u, v) + meshOffset(s, m, u, v)
    }

    /// Mesh node (i,j) position in the window (for the editor handles).
    static func meshNode(_ s: DisplaySettings, _ H: Homography, _ m: [Double], _ i: Int, _ j: Int) -> SIMD2<Double> {
        let k = (j * (s.meshCols + 1) + i) * 2
        return H.map(Double(i) / Double(s.meshCols), Double(j) / Double(s.meshRows)) + SIMD2(m[k], m[k + 1])
    }

    /// Position, scale and rotation move the whole layer on the Screen, corners and mesh included,
    /// like a layer's Transform in After Effects (Akira 2026-11-26). Before, they moved the picture
    /// inside the layer and the layer's edge cut it. Turns about the middle of the four corners;
    /// position is a fraction of the Screen's width / height.
    struct Place {
        let c: SIMD2<Double>, pos: SIMD2<Double>
        let A: Double, cs: Double, sn: Double, sc: Double

        init(_ s: DisplaySettings, corners q: [Double], viewAspect: Double) {
            c = SIMD2((q[0] + q[2] + q[4] + q[6]) / 4, (q[1] + q[3] + q[5] + q[7]) / 4)
            pos = SIMD2(s.posX, s.posY)
            A = viewAspect > 0 ? viewAspect : 16.0 / 9.0
            let th = s.rotation * .pi / 180
            cs = cos(th); sn = sin(th); sc = max(0.01, s.scale)
        }
        /// The linear part (scale and rotation) of a step d on the Screen.
        func turn(_ d: SIMD2<Double>) -> SIMD2<Double> {
            let x = d.x * A, y = d.y
            return SIMD2((x * cs - y * sn) * sc / A, (x * sn + y * cs) * sc)
        }
        /// Its inverse.
        func unturn(_ d: SIMD2<Double>) -> SIMD2<Double> {
            let x = d.x * A / sc, y = d.y / sc
            return SIMD2((x * cs + y * sn) / A, -x * sn + y * cs)
        }
        func map(_ p: SIMD2<Double>) -> SIMD2<Double> { c + turn(p - c) + pos }
        func unmap(_ p: SIMD2<Double>) -> SIMD2<Double> { c + unturn(p - pos - c) }
    }

    static func place(_ s: DisplaySettings, viewAspect: Double, videoAspect: Double) -> Place {
        Place(s, corners: corners(s, viewAspect: viewAspect, videoAspect: videoAspect), viewAspect: viewAspect)
    }

    /// The four corners where they land on the Screen (after position, scale and rotation).
    static func placedCorners(_ s: DisplaySettings, viewAspect: Double, videoAspect: Double) -> [SIMD2<Double>] {
        let q = corners(s, viewAspect: viewAspect, videoAspect: videoAspect)
        let P = Place(s, corners: q, viewAspect: viewAspect)
        return (0..<4).map { P.map(SIMD2(q[$0 * 2], q[$0 * 2 + 1])) }
    }

    /// The corners to store so that they land at Q on the Screen (Q in the same order). The middle
    /// moves with them, so the other corners stay where they are while one is dragged.
    static func cornersLanding(at Q: [SIMD2<Double>], _ s: DisplaySettings, viewAspect: Double) -> [Double] {
        let P = Place(s, corners: [0, 0, 0, 0, 0, 0, 0, 0], viewAspect: viewAspect)
        let mid = (Q[0] + Q[1] + Q[2] + Q[3]) / 4
        let c = mid - P.pos
        return Q.flatMap { q -> [Double] in let p = c + P.unturn(q - mid); return [p.x, p.y] }
    }

    /// The part of the movie that shows (the crop), in (u, v), in order; empty when nothing shows.
    static func pictureOutline(_ s: DisplaySettings) -> [SIMD2<Double>] {
        let l = s.cropL, r = 1 - s.cropR, b = s.cropB, t = 1 - s.cropT
        guard r > l, t > b else { return [] }
        return [SIMD2(l, b), SIMD2(r, b), SIMD2(r, t), SIMD2(l, t)]
    }
}
