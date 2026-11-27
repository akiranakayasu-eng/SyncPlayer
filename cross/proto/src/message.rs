use serde::{Deserialize, Serialize};

pub const BEACON_PORT: u16 = 47800;
pub const CLOCK_PORT: u16 = 47801;
/// Protocol version this crate implements (v0.3.7 of the Mac app = protocol 1).
pub const PROTOCOL: u32 = 1;

/// The show state the master announces. Seconds are f64; times are on the master's host clock.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Schedule {
    pub epoch: i64,
    pub playing: bool,
    pub anchor_host: f64,
    pub anchor_media: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cycle: Option<f64>,
}

/// One datagram (JSON). Every field except `k` is optional; unknown fields are ignored on read,
/// and absent ones are left out on write (as Swift's JSONEncoder does).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Message {
    pub k: String, // "b" beacon, "p" ping, "q" pong
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub s: Option<Schedule>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub t1: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub t2: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub t3: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dur: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ident: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ver: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub err: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warn: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seat: Option<String>,
}

impl Message {
    pub fn new(k: &str) -> Self {
        Message { k: k.to_string(), ..Default::default() }
    }
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }
    pub fn decode(d: &[u8]) -> Option<Message> {
        serde_json::from_slice(d).ok()
    }
}

impl Schedule {
    /// Timeline position (not wrapped) at local time `h`, given offset = master clock - local clock.
    /// Same formula as Mac v0.3.7 Transport.timeline.
    pub fn timeline(&self, local: f64, offset: f64) -> f64 {
        if !self.playing {
            return self.anchor_media;
        }
        self.anchor_media + (local + offset - self.anchor_host).max(0.0)
    }

    /// Position inside one clip of length `len` (> 0): wrapped by the common loop `cycle` when
    /// the master sets one (a clip shorter than the cycle holds its last frame), else by `len`.
    pub fn clip_position(&self, timeline: f64, len: f64) -> f64 {
        match self.cycle {
            Some(c) if c > 0.0 => {
                let t = timeline.rem_euclid(c);
                t.min(len)
            }
            _ => timeline.rem_euclid(len),
        }
    }
}
