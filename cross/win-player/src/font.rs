//! Small status text as an image (8×8 bitmap font, ASCII; other characters show as '?').
use font8x8::{UnicodeFonts, BASIC_FONTS};

/// Lines of text on a dark box, as opaque RGBA: (width, height, pixels).
pub fn render(lines: &[String], scale: u32) -> (u32, u32, Vec<u8>) {
    let lh = 8 * scale + 4;
    let cols = lines.iter().map(|l| l.chars().count()).max().unwrap_or(0) as u32;
    let (w, h) = ((cols * 8 * scale + 8).max(1), (lines.len() as u32 * lh + 4).max(1));
    let mut px = vec![0u8; (w * h * 4) as usize];
    for p in px.chunks_exact_mut(4) { p.copy_from_slice(&[16, 16, 16, 255]); }
    for (i, line) in lines.iter().enumerate() {
        let y0 = 4 + i as u32 * lh;
        let color: [u8; 4] = if line.starts_with('!') { [255, 176, 64, 255] } else { [232, 232, 232, 255] };
        for (j, ch) in line.chars().enumerate() {
            let g = BASIC_FONTS.get(ch).or_else(|| BASIC_FONTS.get('?')).unwrap();
            let x0 = 4 + j as u32 * 8 * scale;
            for (ry, row) in g.iter().enumerate() {
                for rx in 0..8u32 {
                    if row >> rx & 1 == 0 { continue; }
                    for dy in 0..scale { for dx in 0..scale {
                        let (x, y) = (x0 + rx * scale + dx, y0 + ry as u32 * scale + dy);
                        if x < w && y < h { let k = ((y * w + x) * 4) as usize; px[k..k + 4].copy_from_slice(&color); }
                    }}
                }
            }
        }
    }
    (w, h, px)
}
