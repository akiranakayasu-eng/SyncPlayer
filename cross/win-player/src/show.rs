//! The parts of a Mac `.syncshow` (version 3, also reads 1–2) that the Windows player uses: clips,
//! seats, and each seat's first output's layers (order, visible, opacity). Warp, crop, mask, edge
//! blend and sound are ignored for now (same scope as the iOS follower, ios/SyncFollower/ShowModel.swift).
#![allow(dead_code)]
use serde_json::Value;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Clip { pub id: String, pub path: String }
#[derive(Debug, Clone)]
pub struct Layer { pub clip_id: String, pub visible: bool, pub opacity: f64, pub name: Option<String> }
#[derive(Debug, Clone)]
pub struct Output { pub name: String, pub layers: Vec<Layer> }
#[derive(Debug, Clone)]
pub struct Seat { pub id: String, pub name: String, pub outputs: Vec<Output> }

#[derive(Debug, Clone)]
pub struct ShowFile {
    pub folder: PathBuf,
    pub title: String,
    pub clips: Vec<Clip>,
    pub seats: Vec<Seat>,
}

fn outputs_of(v: Option<&Value>) -> Vec<Output> {
    v.and_then(|o| o.as_array()).map(|outs| outs.iter().map(|o| {
        let layers = o.get("layers").and_then(|l| l.as_array()).map(|ls| ls.iter().filter_map(|l| {
            Some(Layer {
                clip_id: l.get("clipID")?.as_str()?.to_string(),
                visible: l.get("visible").and_then(|v| v.as_bool()).unwrap_or(true),
                opacity: l.get("opacity").and_then(|v| v.as_f64()).unwrap_or(1.0),
                name: l.get("name").and_then(|v| v.as_str()).map(String::from),
            })
        }).collect()).unwrap_or_default();
        Output { name: o.get("name").and_then(|v| v.as_str()).unwrap_or("Screen").to_string(), layers }
    }).collect()).unwrap_or_default()
}

impl ShowFile {
    pub fn read(path: &Path) -> Result<ShowFile, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        Self::parse(&text, path)
    }

    pub fn parse(text: &str, path: &Path) -> Result<ShowFile, String> {
        let j: Value = serde_json::from_str(text).map_err(|e| format!("not a SyncPlayer show: {e}"))?;
        let clips: Vec<Clip> = j.get("clips").and_then(|c| c.as_array()).ok_or("no clips")?.iter().filter_map(|c| {
            Some(Clip { id: c.get("id")?.as_str()?.to_string(), path: c.get("path")?.as_str()?.to_string() })
        }).collect();
        let mut seats: Vec<Seat> = j.get("seats").and_then(|s| s.as_array()).map(|ss| ss.iter().enumerate().map(|(k, s)| Seat {
            id: s.get("id").and_then(|v| v.as_str()).map(String::from).unwrap_or(format!("seat{k}")),
            name: s.get("name").and_then(|v| v.as_str()).unwrap_or("A").to_string(),
            outputs: outputs_of(s.get("outputs")),
        }).collect()).unwrap_or_default();
        // Versions 1–2 have no seats: their top-level outputs are seat "A" (as Show.swift reads them).
        if seats.is_empty() {
            let outs = outputs_of(j.get("outputs"));
            if !outs.is_empty() { seats.push(Seat { id: "A".into(), name: "A".into(), outputs: outs }); }
        }
        if seats.is_empty() { return Err("the show has no seats".into()); }
        Ok(ShowFile {
            folder: path.parent().map(Path::to_path_buf).unwrap_or_default(),
            title: path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default(),
            clips, seats,
        })
    }

    pub fn clip(&self, id: &str) -> Option<&Clip> { self.clips.iter().find(|c| c.id == id) }

    /// Relative paths (a Collect Files folder) are next to the show; Mac absolute paths are looked
    /// up by file name next to the show and in its `movies` folder.
    pub fn clip_path(&self, id: &str) -> Option<PathBuf> {
        let c = self.clip(id)?;
        let name = c.path.rsplit(['/', '\\']).next().unwrap_or(&c.path).to_string();
        let mut cands = vec![];
        if !c.path.starts_with('/') { cands.push(self.folder.join(&c.path)); }
        cands.push(self.folder.join(&name));
        cands.push(self.folder.join("movies").join(&name));
        cands.into_iter().find(|p| p.is_file())
    }

    pub fn clip_label(&self, l: &Layer) -> String {
        l.name.clone().or_else(|| self.clip(&l.clip_id).map(|c| c.path.rsplit(['/', '\\']).next().unwrap_or(&c.path).to_string()))
            .unwrap_or(l.clip_id.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reads_v1_without_seats() {
        let s = ShowFile::parse(r#"{"version":1,"clips":[{"id":"c1","path":"/Users/x/a.mp4"}],
            "outputs":[{"name":"o","layers":[{"clipID":"c1","look":{}}]}]}"#, Path::new("C:/t/s.syncshow")).unwrap();
        assert_eq!(s.seats.len(), 1);
        assert_eq!(s.seats[0].outputs[0].layers[0].clip_id, "c1");
        assert_eq!(s.seats[0].outputs[0].layers[0].opacity, 1.0);
    }
    #[test]
    fn reads_v3_seats() {
        let s = ShowFile::parse(r#"{"version":3,"clips":[{"id":"c1","path":"a.mp4"},{"id":"c2","path":"b.mp4"}],
            "seats":[{"id":"s1","name":"A","outputs":[{"name":"o","layers":[{"clipID":"c1"}]}]},
                     {"id":"s2","name":"B","outputs":[{"name":"o","layers":[{"clipID":"c1"},{"clipID":"c2","opacity":0.5,"visible":false}]}]}]}"#,
            Path::new("C:/t/s.syncshow")).unwrap();
        assert_eq!(s.seats[1].name, "B");
        let l = &s.seats[1].outputs[0].layers[1];
        assert_eq!((l.opacity, l.visible), (0.5, false));
    }
}
