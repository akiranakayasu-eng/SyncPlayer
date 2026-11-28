//! Video frames from ffmpeg.exe (child process, raw RGBA on its stdout pipe; no C bindings).
//!
//! A decoder is started at a timeline position and then keeps decoding *ahead* (no `-re`): the pipe
//! and a small queue block it once it is far enough ahead. Every frame carries the (unwrapped)
//! timeline time at which it becomes due, so the window only has to show the newest frame whose time
//! has come. Looping is done here: the clip restarts at its origin every loop span (the master's
//! `cycle`, else the clip length); a clip shorter than the cycle holds its last frame until the next
//! cycle (the last frame's `dur` covers the gap). The next ffmpeg (always from frame 0) is started
//! while the current one plays, so the seam costs no start-up time.
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, TryRecvError};
use std::sync::{Arc, Mutex};

#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

fn quiet(cmd: &mut Command) -> &mut Command {
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);
    cmd
}

/// ffmpeg / ffprobe: $SYNCPLAYER_FFMPEG_DIR, else next to this exe, else PATH.
pub fn tool(name: &str) -> PathBuf {
    let exe = format!("{name}{}", std::env::consts::EXE_SUFFIX);
    if let Ok(d) = std::env::var("SYNCPLAYER_FFMPEG_DIR") {
        let p = Path::new(&d).join(&exe);
        if p.is_file() { return p; }
    }
    if let Some(d) = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf)) {
        let p = d.join(&exe);
        if p.is_file() { return p; }
    }
    PathBuf::from(exe)
}

/// What the timing needs to know about a movie (constant frame rate assumed).
#[derive(Debug, Clone)]
pub struct Media {
    pub path: PathBuf,
    pub fps: f64,
    /// Length in seconds (stream duration, else container duration), as the Mac's asset duration.
    pub len: f64,
}

impl Media {
    pub fn probe(path: &Path) -> Result<Media, String> {
        let out = quiet(Command::new(tool("ffprobe")).args(["-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=avg_frame_rate,r_frame_rate,duration", "-show_entries", "format=duration",
            "-of", "json"]).arg(path))
            .output().map_err(|e| format!("ffprobe could not start ({e}); is ffmpeg installed?"))?;
        let j: serde_json::Value = serde_json::from_slice(&out.stdout).map_err(|e| format!("ffprobe: {e}"))?;
        let st = j.get("streams").and_then(|s| s.get(0)).ok_or(format!("no video in {}", path.display()))?;
        let rate = |k: &str| st.get(k).and_then(|v| v.as_str()).and_then(|r| {
            let (a, b) = r.split_once('/')?;
            let (a, b): (f64, f64) = (a.parse().ok()?, b.parse().ok()?);
            (a > 0.0 && b > 0.0).then_some(a / b)
        });
        let fps = rate("avg_frame_rate").or_else(|| rate("r_frame_rate")).filter(|f| *f > 1.0 && *f < 300.0).unwrap_or(30.0);
        let num = |v: Option<&serde_json::Value>| v.and_then(|d| d.as_str()).and_then(|d| d.parse::<f64>().ok()).filter(|d| *d > 0.0);
        let len = num(st.get("duration")).or_else(|| num(j.get("format").and_then(|f| f.get("duration"))))
            .ok_or(format!("no duration for {}", path.display()))?;
        Ok(Media {
            path: path.to_path_buf(), fps, len,
        })
    }

    /// Number of frames that start before `limit` seconds.
    fn frames_before(&self, limit: f64) -> i64 { ((limit * self.fps) - 1e-6).ceil().max(1.0) as i64 }
}

pub struct Frame {
    /// Timeline time (unwrapped, master seconds) at which this frame is due.
    pub tag: f64,
    /// How long it stays (1/fps, longer for a last frame that holds).
    pub dur: f64,
    pub rgba: Vec<u8>,
}

pub struct Decoder {
    rx: Receiver<Frame>,
    stop: Arc<AtomicBool>,
    children: Arc<Mutex<Vec<Child>>>,
    /// The loop the frames were laid out for (a different master cycle needs a new decoder).
    pub cycle: Option<f64>,
    pub started_at: f64,
}

impl Drop for Decoder {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Ok(mut ch) = self.children.lock() {
            for c in ch.iter_mut() { let _ = c.kill(); let _ = c.wait(); }
            ch.clear();
        }
    }
}

/// Spawns ffmpeg for frames [first, first + count) of the clip, scaled into w×h (aspect kept,
/// transparent bars) as RGBA.
fn spawn(m: &Media, first: i64, count: i64, w: u32, h: u32) -> std::io::Result<Child> {
    let mut cmd = Command::new(tool("ffmpeg"));
    cmd.args(["-hide_banner", "-loglevel", "error", "-nostdin"]);
    // Seek half a frame before the wanted frame: the accurate seek drops frames before -ss, so the
    // first frame out is exactly frame `first`.
    if first > 0 { cmd.args(["-ss", &format!("{:.6}", (first as f64 - 0.5) / m.fps)]); }
    cmd.arg("-i").arg(&m.path);
    let vf = format!("scale={w}:{h}:force_original_aspect_ratio=decrease:flags=bilinear,\
        pad={w}:{h}:(ow-iw)/2:(oh-ih)/2:color=black@0,format=rgba");
    cmd.args(["-an", "-sn", "-vf", &vf, "-fps_mode", "passthrough", "-frames:v", &count.to_string(),
        "-f", "rawvideo", "-pix_fmt", "rgba", "-"]);
    quiet(&mut cmd).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()
}

impl Decoder {
    /// Starts decoding so that the frame due at timeline `t0` comes first. `cycle` as in the schedule.
    pub fn start(media: Arc<Media>, w: u32, h: u32, t0: f64, cycle: Option<f64>, started_at: f64, queue: usize) -> Decoder {
        let (tx, rx) = sync_channel::<Frame>(queue.max(2));
        let stop = Arc::new(AtomicBool::new(false));
        let children = Arc::new(Mutex::new(Vec::<Child>::new()));
        let (stop2, children2) = (stop.clone(), children.clone());
        let cyc = cycle.filter(|c| *c > 0.0);
        std::thread::spawn(move || {
            let m = &*media;
            let fd = 1.0 / m.fps;
            // Loop span on the timeline, and how much of the clip plays in each span.
            let span = cyc.unwrap_or(m.len);
            let limit = cyc.map(|c| c.min(m.len)).unwrap_or(m.len);
            let total = m.frames_before(limit);
            // Origin (timeline time of clip position 0) of the span holding t0.
            let mut origin = (t0 / span).floor() * span;
            let p0 = (t0 - origin).min(limit);
            let first = ((p0 * m.fps + 1e-6).floor() as i64).clamp(0, total - 1);
            let size = (w * h * 4) as usize;
            // Start a few frames early and drop them: a seek to (near) the very last frame can give
            // nothing, and then the frame to hold would be missing.
            let back = first.min(12);
            let mut seg_first = first - back;
            let mut skip_below = first;
            let mut child = match spawn(m, seg_first, total - seg_first, w, h) { Ok(c) => c, Err(_) => return };
            let mut next: Option<Child> = None;
            let mut pending: Option<Frame> = None;
            let mut pending_early = false;
            loop {
                if stop2.load(Ordering::SeqCst) { break; }
                let mut out = child.stdout.take().unwrap();
                children2.lock().unwrap().push(child);
                // The next span always starts at frame 0: start it now; it waits on its full pipe.
                if next.is_none() { next = spawn(m, 0, total, w, h).ok(); }
                let mut i = seg_first;
                loop {
                    let mut buf = vec![0u8; size];
                    if out.read_exact(&mut buf).is_err() { break; }
                    let f = Frame { tag: origin + i as f64 * fd, dur: fd, rgba: buf };
                    let early = i < skip_below;
                    // An early frame is only kept in case the clip ends before the wanted one.
                    let prev = pending.replace(f);
                    if let Some(p) = prev { if !pending_early && tx.send(p).is_err() { return; } }
                    pending_early = early;
                    i += 1;
                }
                if stop2.load(Ordering::SeqCst) { return; }
                // End of this span: the last frame holds until the next origin.
                origin += span;
                if let Some(mut p) = pending.take() {
                    p.dur = (origin - p.tag).max(fd);
                    if tx.send(p).is_err() { return; }
                }
                pending_early = false;
                if let Ok(mut ch) = children2.lock() { for c in ch.iter_mut() { let _ = c.wait(); } ch.clear(); }
                seg_first = 0;
                skip_below = 0;
                child = match next.take() { Some(c) => c, None => match spawn(m, 0, total, w, h) { Ok(c) => c, Err(_) => return } };
            }
        });
        Decoder { rx, stop, children, cycle: cyc, started_at }
    }

    /// The next decoded frame, if one is ready. Err(()) when the decoder has stopped for good.
    pub fn try_next(&self) -> Result<Option<Frame>, ()> {
        match self.rx.try_recv() {
            Ok(f) => Ok(Some(f)),
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => Err(()),
        }
    }
}
