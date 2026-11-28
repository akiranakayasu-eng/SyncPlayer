//! The parts of a Mac `.syncshow` (version 3, also reads 1–2) that the Windows player uses: clips,
//! seats, and each seat's first output: its layers (order, visible, opacity, look = position /
//! scale / rotation / crop / feather / corner pin / mesh, mask) and the Screen's edge blend.
//! Defaults and the reading of old files follow Show.swift / Settings.swift. Sound is not used yet.
#![allow(dead_code)]
use serde_json::Value;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Clip { pub id: String, pub path: String }

/// DisplaySettings of the Mac (only what drawing needs).
#[derive(Debug, Clone, PartialEq)]
pub struct Look {
    pub pos_x: f64, pub pos_y: f64, pub scale: f64, pub rotation: f64,
    pub crop_l: f64, pub crop_r: f64, pub crop_t: f64, pub crop_b: f64,
    pub feather: f64,
    pub corners: Option<[f64; 8]>,
    pub mesh_cols: usize, pub mesh_rows: usize, pub mesh: Vec<f64>,
    // edge blend of 0.3.4 and before (read only to build the Screen's blend)
    pub blend_l: f64, pub blend_r: f64, pub blend_t: f64, pub blend_b: f64, pub blend_gamma: f64,
}

impl Default for Look {
    fn default() -> Self {
        Look { pos_x: 0.0, pos_y: 0.0, scale: 1.0, rotation: 0.0, crop_l: 0.0, crop_r: 0.0, crop_t: 0.0, crop_b: 0.0,
            feather: 0.0, corners: None, mesh_cols: 4, mesh_rows: 4, mesh: vec![],
            blend_l: 0.0, blend_r: 0.0, blend_t: 0.0, blend_b: 0.0, blend_gamma: 2.2 }
    }
}

impl Look {
    fn read(v: Option<&Value>) -> Look {
        let mut s = Look::default();
        let Some(v) = v else { return s };
        let n = |k: &str, d: f64| v.get(k).and_then(|x| x.as_f64()).unwrap_or(d);
        s.pos_x = n("posX", 0.0); s.pos_y = n("posY", 0.0); s.scale = n("scale", 1.0); s.rotation = n("rotation", 0.0);
        s.crop_l = n("cropL", 0.0); s.crop_r = n("cropR", 0.0); s.crop_t = n("cropT", 0.0); s.crop_b = n("cropB", 0.0);
        s.blend_l = n("blendL", 0.0); s.blend_r = n("blendR", 0.0); s.blend_t = n("blendT", 0.0); s.blend_b = n("blendB", 0.0);
        s.blend_gamma = n("blendGamma", 2.2);
        s.feather = n("feather", 0.0).clamp(0.0, 0.5);
        s.corners = v.get("corners").and_then(|c| c.as_array()).and_then(|a| {
            let f: Vec<f64> = a.iter().filter_map(|x| x.as_f64()).collect();
            (f.len() == 8).then(|| [f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7]])
        });
        s.mesh_cols = v.get("meshCols").and_then(|x| x.as_i64()).unwrap_or(4) as usize;
        s.mesh_rows = v.get("meshRows").and_then(|x| x.as_i64()).unwrap_or(4) as usize;
        s.mesh = v.get("mesh").and_then(|m| m.as_array()).map(|a| a.iter().filter_map(|x| x.as_f64()).collect()).unwrap_or_default();
        // Values from a hand-edited file: keep the mesh in the range the controls allow.
        if !(2..=8).contains(&s.mesh_cols) || !(2..=8).contains(&s.mesh_rows) { s.mesh_cols = 4; s.mesh_rows = 4; s.mesh = vec![]; }
        s
    }
    /// Mesh offsets, always the right length (zeros when the stored list does not fit).
    pub fn mesh_offsets(&self) -> Vec<f64> {
        let n = (self.mesh_cols + 1) * (self.mesh_rows + 1) * 2;
        if self.mesh.len() == n { self.mesh.clone() } else { vec![0.0; n] }
    }
}

#[derive(Debug, Clone)]
pub struct Layer {
    pub clip_id: String, pub visible: bool, pub opacity: f64, pub name: Option<String>,
    pub look: Look, pub mask: Option<String>, pub mask_invert: bool,
}

/// The Screen's edge blend (fractions of its width / height, and the gamma of the fade).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Blend { pub l: f64, pub r: f64, pub t: f64, pub b: f64, pub gamma: f64 }
impl Default for Blend { fn default() -> Self { Blend { l: 0.0, r: 0.0, t: 0.0, b: 0.0, gamma: 2.2 } } }

#[derive(Debug, Clone)]
pub struct Output { pub name: String, pub layers: Vec<Layer>, pub blend: Blend }
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
        let layers: Vec<Layer> = o.get("layers").and_then(|l| l.as_array()).map(|ls| ls.iter().filter_map(|l| {
            Some(Layer {
                clip_id: l.get("clipID")?.as_str()?.to_string(),
                visible: l.get("visible").and_then(|v| v.as_bool()).unwrap_or(true),
                opacity: l.get("opacity").and_then(|v| v.as_f64()).unwrap_or(1.0),
                name: l.get("name").and_then(|v| v.as_str()).map(String::from),
                look: Look::read(l.get("look")),
                mask: l.get("mask").and_then(|v| v.as_str()).map(String::from),
                mask_invert: l.get("maskInvert").and_then(|v| v.as_bool()).unwrap_or(false),
            })
        }).collect()).unwrap_or_default();
        let mut blend = Blend::default();
        if let Some(b) = o.get("blend") {
            let n = |k: &str, d: f64| b.get(k).and_then(|x| x.as_f64()).unwrap_or(d);
            blend = Blend { l: n("l", 0.0), r: n("r", 0.0), t: n("t", 0.0), b: n("b", 0.0), gamma: n("gamma", 2.2) };
        } else {
            // 0.3.4 and before kept the edge blend on each layer: the Screen takes the widest of each side.
            let mx = |f: fn(&Look) -> f64| layers.iter().map(|l| f(&l.look)).fold(0.0, f64::max);
            blend.l = mx(|s| s.blend_l); blend.r = mx(|s| s.blend_r); blend.t = mx(|s| s.blend_t); blend.b = mx(|s| s.blend_b);
            if let Some(l) = layers.iter().find(|l| l.look.blend_l + l.look.blend_r + l.look.blend_t + l.look.blend_b > 0.0) {
                blend.gamma = l.look.blend_gamma;
            }
        }
        blend.gamma = blend.gamma.clamp(0.5, 4.0);
        Output { name: o.get("name").and_then(|v| v.as_str()).unwrap_or("Screen").to_string(), layers, blend }
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
    pub fn clip_path(&self, id: &str) -> Option<PathBuf> { self.find(&self.clip(id)?.path) }

    /// A file the show names (movie or mask): relative to the show, else by name next to it or in
    /// its `movies` / `masks` folder.
    pub fn find(&self, path: &str) -> Option<PathBuf> {
        let c = Clip { id: String::new(), path: path.to_string() };
        let name = c.path.rsplit(['/', '\\']).next().unwrap_or(&c.path).to_string();
        let mut cands = vec![];
        if !c.path.starts_with('/') { cands.push(self.folder.join(&c.path)); }
        cands.push(self.folder.join(&name));
        cands.push(self.folder.join("movies").join(&name));
        cands.push(self.folder.join("masks").join(&name));
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
