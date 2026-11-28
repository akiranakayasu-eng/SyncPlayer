//! Layer geometry, ported from the Mac app (Sources/SyncPlayer/Warp.swift, GPU.vertices): the movie
//! fills the layer's four corners (corner pin, a projective map), a Catmull-Rom mesh adds offsets,
//! and position / scale / rotation move the whole layer on the Screen. Coordinates are fractions of
//! the Screen with y pointing up (0 = bottom), as on the Mac.
use crate::show::Look;

pub const N: usize = 48; // grid subdivisions, as GPU.N

/// Corners (BL, BR, TR, TL) that fit a picture of `video` aspect inside a Screen of `view` aspect.
pub fn fit_corners(view: f64, video: f64) -> [f64; 8] {
    let (mut w, mut h) = (1.0, 1.0);
    if video > 0.0 && view > 0.0 {
        if video > view { h = view / video } else { w = video / view }
    }
    let (x0, y0) = ((1.0 - w) / 2.0, (1.0 - h) / 2.0);
    [x0, y0, x0 + w, y0, x0 + w, y0 + h, x0, y0 + h]
}

pub fn corners(s: &Look, view: f64, video: f64) -> [f64; 8] { s.corners.unwrap_or_else(|| fit_corners(view, video)) }

/// Projective map of the unit square onto the quad (Heckbert's square-to-quad).
pub struct Homography { a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f64, h: f64 }

impl Homography {
    pub fn new(q: &[f64; 8]) -> Self {
        let [x0, y0, x1, y1, x2, y2, x3, y3] = *q;
        let (dx1, dx2, dx3) = (x1 - x2, x3 - x2, x0 - x1 + x2 - x3);
        let (dy1, dy2, dy3) = (y1 - y2, y3 - y2, y0 - y1 + y2 - y3);
        let den = dx1 * dy2 - dx2 * dy1;
        if (dx3.abs() < 1e-12 && dy3.abs() < 1e-12) || den.abs() < 1e-12 {
            Homography { a: x1 - x0, b: x3 - x0, c: x0, d: y1 - y0, e: y3 - y0, f: y0, g: 0.0, h: 0.0 }
        } else {
            let g = (dx3 * dy2 - dx2 * dy3) / den;
            let h = (dx1 * dy3 - dx3 * dy1) / den;
            Homography { a: x1 - x0 + g * x1, b: x3 - x0 + h * x3, c: x0, d: y1 - y0 + g * y1, e: y3 - y0 + h * y3, f: y0, g, h }
        }
    }
    pub fn map(&self, u: f64, v: f64) -> (f64, f64) {
        let w = self.g * u + self.h * v + 1.0;
        ((self.a * u + self.b * v + self.c) / w, (self.d * u + self.e * v + self.f) / w)
    }
}

fn catmull(p0: f64, p1: f64, p2: f64, p3: f64, t: f64) -> f64 {
    let (t2, t3) = (t * t, t * t * t);
    0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
}

/// Smooth (Catmull-Rom) mesh offset at canvas point (u,v).
fn mesh_offset(s: &Look, m: &[f64], u: f64, v: f64) -> (f64, f64) {
    let (cols, rows) = (s.mesh_cols as i64, s.mesh_rows as i64);
    if m.iter().all(|x| *x == 0.0) { return (0.0, 0.0); }
    let (fx, fy) = (u * cols as f64, v * rows as f64);
    let ix = (fx.floor() as i64).clamp(0, cols - 1);
    let iy = (fy.floor() as i64).clamp(0, rows - 1);
    let (tx, ty) = (fx - ix as f64, fy - iy as f64);
    let node = |i: i64, j: i64, k: usize| {
        let (ci, cj) = (i.clamp(0, cols), j.clamp(0, rows));
        m[((cj * (cols + 1) + ci) * 2) as usize + k]
    };
    let mut out = [0.0; 2];
    for (k, o) in out.iter_mut().enumerate() {
        let mut col = [0.0; 4];
        for (r, c) in col.iter_mut().enumerate() {
            let j = iy - 1 + r as i64;
            *c = catmull(node(ix - 1, j, k), node(ix, j, k), node(ix + 1, j, k), node(ix + 2, j, k), tx);
        }
        *o = catmull(col[0], col[1], col[2], col[3], ty);
    }
    (out[0], out[1])
}

/// Position, scale and rotation of the whole layer (turns about the middle of the four corners;
/// position is a fraction of the Screen's width / height).
struct Place { c: (f64, f64), pos: (f64, f64), a: f64, cs: f64, sn: f64, sc: f64 }

impl Place {
    fn new(s: &Look, q: &[f64; 8], view: f64) -> Self {
        let th = s.rotation * std::f64::consts::PI / 180.0;
        Place {
            c: ((q[0] + q[2] + q[4] + q[6]) / 4.0, (q[1] + q[3] + q[5] + q[7]) / 4.0),
            pos: (s.pos_x, s.pos_y),
            a: if view > 0.0 { view } else { 16.0 / 9.0 },
            cs: th.cos(), sn: th.sin(), sc: s.scale.max(0.01),
        }
    }
    fn map(&self, p: (f64, f64)) -> (f64, f64) {
        let (x, y) = ((p.0 - self.c.0) * self.a, p.1 - self.c.1);
        let tx = (x * self.cs - y * self.sn) * self.sc / self.a;
        let ty = (x * self.sn + y * self.cs) * self.sc;
        (self.c.0 + tx + self.pos.0, self.c.1 + ty + self.pos.1)
    }
}

/// Grid vertices (output x,y + source u,v) for one layer's look, (N+1)² of them, row by row.
pub fn vertices(s: &Look, view: f64, video: f64) -> Vec<[f32; 4]> {
    let q = corners(s, view, video);
    let h = Homography::new(&q);
    let p = Place::new(s, &q, view);
    let m = s.mesh_offsets();
    let mut out = Vec::with_capacity((N + 1) * (N + 1));
    for j in 0..=N {
        for i in 0..=N {
            let (u, v) = (i as f64 / N as f64, j as f64 / N as f64);
            let o = h.map(u, v);
            let d = mesh_offset(s, &m, u, v);
            let o = p.map((o.0 + d.0, o.1 + d.1));
            out.push([o.0 as f32, o.1 as f32, u as f32, v as f32]);
        }
    }
    out
}

/// Triangle indices for the grid, as GPU.indexBuffer.
pub fn indices() -> Vec<u32> {
    let mut idx = Vec::with_capacity(N * N * 6);
    for j in 0..N {
        for i in 0..N {
            let a = (j * (N + 1) + i) as u32;
            let (b, c) = (a + 1, a + (N + 1) as u32);
            let d = c + 1;
            idx.extend_from_slice(&[a, b, d, a, d, c]);
        }
    }
    idx
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fit_and_identity() {
        // 16:9 movie on a 16:9 Screen fills it; corners of the grid are the Screen's corners.
        let v = vertices(&Look::default(), 16.0 / 9.0, 16.0 / 9.0);
        assert_eq!(v[0], [0.0, 0.0, 0.0, 0.0]);
        assert_eq!(v[(N + 1) * (N + 1) - 1], [1.0, 1.0, 1.0, 1.0]);
        // square movie: pillarbox
        let q = fit_corners(16.0 / 9.0, 1.0);
        assert!((q[0] - (1.0 - 9.0 / 16.0) / 2.0).abs() < 1e-12);
    }
    #[test]
    fn homography_hits_corners() {
        let q = [0.1, 0.2, 0.9, 0.1, 0.8, 0.9, 0.2, 0.7];
        let h = Homography::new(&q);
        for (k, (u, v)) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].iter().enumerate() {
            let p = h.map(*u, *v);
            assert!((p.0 - q[k * 2]).abs() < 1e-9 && (p.1 - q[k * 2 + 1]).abs() < 1e-9);
        }
    }
    #[test]
    fn place_moves_and_turns() {
        let mut s = Look::default();
        s.pos_x = 0.1; s.rotation = 90.0;
        let v = vertices(&s, 1.0, 1.0);
        // bottom-left corner of a full square layer turned 90° CCW about the middle lands bottom-right, then moves 0.1.
        let p = v[0];
        assert!((p[0] - 1.1).abs() < 1e-5 && (p[1] - 0.0).abs() < 1e-5, "{p:?}");
    }
}
