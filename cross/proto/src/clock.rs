/// NTP-style clock estimate: offset = master clock - local clock.
/// Mirrors ClockSync.swift: keeps 120 samples, averages the 5 with the shortest round trips,
/// ready after 8 samples, rejects rtt < 0 or >= 0.5 s.
#[derive(Default)]
pub struct ClockSync {
    samples: Vec<(f64, f64)>, // (rtt, offset)
    pub offset: f64,
    pub rtt: f64,
}

impl ClockSync {
    pub fn new() -> Self { Self::default() }
    pub fn reset(&mut self) { *self = Self::default(); }
    pub fn count(&self) -> usize { self.samples.len() }
    pub fn ready(&self) -> bool { self.samples.len() >= 8 }

    /// t1 local send, t2 master receive, t3 master send, t4 local receive.
    pub fn add(&mut self, t1: f64, t2: f64, t3: f64, t4: f64) {
        let rtt = (t4 - t1) - (t3 - t2);
        let off = ((t2 - t1) + (t3 - t4)) / 2.0;
        if !(rtt >= 0.0 && rtt < 0.5) { return; }
        self.samples.push((rtt, off));
        if self.samples.len() > 120 {
            let n = self.samples.len() - 120;
            self.samples.drain(0..n);
        }
        let mut best = self.samples.clone();
        best.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
        best.truncate(5);
        self.offset = best.iter().map(|s| s.1).sum::<f64>() / best.len() as f64;
        self.rtt = best[0].0;
    }
}
