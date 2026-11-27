//! SyncPlayer sync protocol "1" (the one Mac v0.3.7 speaks). See docs/protocol.md.
pub mod clock;
pub mod message;
pub mod follower;

pub use clock::ClockSync;
pub use message::{Message, Schedule, BEACON_PORT, CLOCK_PORT};
