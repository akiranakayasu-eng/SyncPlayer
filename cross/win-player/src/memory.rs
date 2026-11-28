//! What the player remembers between launches (for exhibitions: switch on, and it plays): the last
//! show opened and the seat chosen for each show. Kept in %APPDATA%\SyncPlayer\win-player.json.
use serde_json::{json, Value};
use std::path::PathBuf;

fn file() -> Option<PathBuf> {
    let base = std::env::var_os("APPDATA").map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("SyncPlayer").join("win-player.json"))
}

fn load() -> Value {
    file().and_then(|f| std::fs::read_to_string(f).ok())
        .and_then(|t| serde_json::from_str(t.trim_start_matches('\u{feff}')).ok())
        .unwrap_or_else(|| json!({}))
}

fn save(v: &Value) {
    let Some(f) = file() else { return };
    if let Some(d) = f.parent() { let _ = std::fs::create_dir_all(d); }
    // Write next to it and rename, so a power cut never leaves half a file.
    let tmp = f.with_extension("json.tmp");
    if std::fs::write(&tmp, serde_json::to_vec_pretty(v).unwrap_or_default()).is_ok() { let _ = std::fs::rename(&tmp, &f); }
}

/// The show opened last time (if it still exists).
pub fn last_show() -> Option<PathBuf> {
    load().get("lastShow").and_then(|s| s.as_str()).map(PathBuf::from).filter(|p| p.is_file())
}

/// The seat chosen last time for this show.
pub fn seat_for(show: &std::path::Path) -> Option<String> {
    let key = show.to_string_lossy().to_string();
    load().get("seats").and_then(|s| s.get(&key)).and_then(|s| s.as_str()).map(String::from)
}

/// Remember this show (by its full path) and its seat.
pub fn remember(show: &std::path::Path, seat: &str) {
    let mut v = load();
    let key = show.to_string_lossy().to_string();
    v["lastShow"] = json!(key);
    if !v.get("seats").map(|s| s.is_object()).unwrap_or(false) { v["seats"] = json!({}); }
    v["seats"][key] = json!(seat);
    save(&v);
}
