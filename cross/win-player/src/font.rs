//! Small status text (8×8 bitmap font, 2× on wide windows, ASCII; other characters show as '?').
use font8x8::{UnicodeFonts, BASIC_FONTS};

pub fn draw_lines(buf: &mut [u32], w: u32, h: u32, x0: u32, y0: u32, lines: &[String]) {
    // 2× on big windows, 1× on small ones
    #[allow(non_snake_case)]
    let SCALE: u32 = if w >= 1600 { 2 } else { 1 };
    let lh = 8 * SCALE + 4;
    let cols = lines.iter().map(|l| l.chars().count()).max().unwrap_or(0) as u32;
    // dark box behind the text
    let (bw, bh) = (cols * 8 * SCALE + 8, lines.len() as u32 * lh + 4);
    for y in y0.saturating_sub(4)..(y0 + bh).min(h) {
        for x in x0.saturating_sub(4)..(x0 + bw).min(w) {
            let p = &mut buf[(y * w + x) as usize];
            *p = (*p >> 2) & 0x3f3f3f; // darken to a quarter
        }
    }
    for (i, line) in lines.iter().enumerate() {
        let y = y0 + i as u32 * lh;
        let color = if line.starts_with('!') { 0xffb040 } else { 0xe8e8e8 };
        for (j, ch) in line.chars().enumerate() {
            let g = BASIC_FONTS.get(ch).or_else(|| BASIC_FONTS.get('?')).unwrap();
            let x = x0 + j as u32 * 8 * SCALE;
            for (ry, row) in g.iter().enumerate() {
                for rx in 0..8u32 {
                    if row >> rx & 1 == 0 { continue; }
                    for dy in 0..SCALE { for dx in 0..SCALE {
                        let (px, py) = (x + rx * SCALE + dx, y + ry as u32 * SCALE + dy);
                        if px < w && py < h { buf[(py * w + px) as usize] = color; }
                    }}
                }
            }
        }
    }
}
