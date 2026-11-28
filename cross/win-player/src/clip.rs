//! One clip of the seat following the master's timeline (the iOS ClipNode, frame-based).
use crate::decoder::{Decoder, Frame, Media};
use std::sync::Arc;

pub struct ClipPlayer {
    pub id: String,
    pub media: Arc<Media>,
    dec: Option<Decoder>,
    /// Frame on screen, and the next one waiting for its time.
    pub cur: Option<Frame>,
    next: Option<Frame>,
    /// No frame of the current decoder shown yet / not yet caught up with the timeline.
    fresh: bool,
    settled: bool,
    err_ema: f64,
    pub last_err: f64,
    pub resyncs: u32,
    /// How far ahead of the timeline a (re)start aims; learned from how long ffmpeg takes.
    lead: f64,
    w: u32,
    h: u32,
    queue: usize,
}

impl ClipPlayer {
    pub fn new(id: String, media: Media, w: u32, h: u32) -> Self {
        // About 0.4 s of frames, at most 16 (memory: w*h*4 each).
        let queue = ((media.fps * 0.4).ceil() as usize).clamp(4, 16);
        ClipPlayer { id, media: Arc::new(media), dec: None, cur: None, next: None, fresh: true, settled: false,
            err_ema: 0.0, last_err: 0.0, resyncs: 0, lead: 0.25, w, h, queue }
    }

    fn restart(&mut self, tl: f64, playing: bool, cycle: Option<f64>, now: f64) {
        let t0 = if playing { tl + self.lead } else { tl };
        self.dec = None; // stops the old ffmpeg first
        self.dec = Some(Decoder::start(self.media.clone(), self.w, self.h, t0, cycle, now, self.queue));
        self.next = None;
        self.fresh = true;
        self.settled = false;
        self.err_ema = 0.0;
        self.last_err = 0.0;
        self.resyncs += 1;
    }

    /// No master: stop decoding and keep the last picture; before any picture, show the first frame
    /// (as the iOS follower parks on it), so the seat can be checked while waiting.
    pub fn idle(&mut self, now: f64) -> bool {
        if self.cur.is_none() {
            self.follow(0.0, false, None, now);
            if self.cur.is_some() { self.dec = None; self.next = None; self.resyncs = 0; return true; }
            return false;
        }
        self.dec = None; self.next = None;
        false
    }

    /// Brings the picture to timeline `tl` (master seconds, unwrapped). Returns true when the
    /// frame on screen changed.
    pub fn follow(&mut self, tl: f64, playing: bool, cycle: Option<f64>, now: f64) -> bool {
        let cyc = cycle.filter(|c| *c > 0.0);
        let need = match &self.dec { None => true, Some(d) => d.cycle != cyc };
        if need { self.restart(tl, playing, cyc, now); }
        let mut changed = false;
        loop {
            if self.next.is_none() {
                match self.dec.as_ref().unwrap().try_next() {
                    Ok(f) => self.next = f,
                    Err(()) => break, // ffmpeg finished or failed; the error check restarts it
                }
            }
            match &self.next {
                Some(f) if f.tag <= tl + 1e-4 => {
                    if self.fresh {
                        // Learn the start-up time: aim the next start a bit further than it took.
                        let took = now - self.dec.as_ref().unwrap().started_at;
                        self.lead = (took * 1.5).clamp(0.12, 1.0);
                    }
                    self.cur = self.next.take();
                    self.fresh = false;
                    changed = true;
                }
                _ => break,
            }
        }
        let started = self.dec.as_ref().map(|d| d.started_at).unwrap_or(now);
        if self.fresh {
            // Nothing from the new decoder yet. Its first frame is due no later than the start aim,
            // so one further ahead means the timeline went back (or the cycle moved): start again.
            let far = self.next.as_ref().map(|f| f.tag > tl + self.lead + 0.1).unwrap_or(false);
            if far || now - started > 3.0 { self.restart(tl, playing, cyc, now); }
            return changed;
        }
        let Some(c) = &self.cur else { return changed };
        // Error of the picture: 0 while the frame on screen is the one due now.
        let err = if tl < c.tag { c.tag - tl } else if tl >= c.tag + c.dur { c.tag + c.dur - tl } else { 0.0 };
        if !self.settled {
            // Right after a start the decoder may still be catching up: don't count that.
            if err == 0.0 || now - started > 2.0 { self.settled = true; } else { return changed; }
        }
        self.last_err = err;
        self.err_ema = 0.8 * self.err_ema + 0.2 * err;
        if self.err_ema.abs() > 0.004 || err.abs() > 0.040 { self.restart(tl, playing, cyc, now); }
        changed
    }
}
