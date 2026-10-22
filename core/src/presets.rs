use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> Self { Rect { x, y, w, h } }
    pub fn max_x(&self) -> f64 { self.x + self.w }
    pub fn max_y(&self) -> f64 { self.y + self.h }
    pub fn is_empty(&self) -> bool { self.w <= 0.0 || self.h <= 0.0 }
    pub fn intersects(&self, o: &Rect) -> bool {
        self.x < o.max_x() && o.x < self.max_x() && self.y < o.max_y() && o.y < self.max_y()
    }
    pub fn intersection(&self, o: &Rect) -> Rect {
        let x0 = self.x.max(o.x);
        let y0 = self.y.max(o.y);
        let x1 = self.max_x().min(o.max_x());
        let y1 = self.max_y().min(o.max_y());
        Rect::new(x0, y0, (x1 - x0).max(0.0), (y1 - y0).max(0.0))
    }
    pub fn union(&self, o: &Rect) -> Rect {
        let x0 = self.x.min(o.x);
        let y0 = self.y.min(o.y);
        Rect::new(x0, y0, self.max_x().max(o.max_x()) - x0, self.max_y().max(o.max_y()) - y0)
    }
    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= self.x && px < self.max_x() && py >= self.y && py < self.max_y()
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "lowercase")]
pub enum RedactMode {
    Pixellate { scale: u32 },
    Blur { radius: f32 },
    Solid { color: [f32; 4] },
}

impl Default for RedactMode {
    fn default() -> Self { RedactMode::Pixellate { scale: 24 } }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Shape {
    #[default]
    Rect,
    Ellipse,
}

/// A region normalised to the window frame [0,1], origin top-left.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PresetRegion {
    pub name: String,
    pub rect: Rect,
    #[serde(flatten)]
    pub mode: RedactMode,
    #[serde(default)]
    pub shape: Shape,
}

#[derive(Clone, Debug, PartialEq, Default, Serialize, Deserialize)]
pub struct AppPreset {
    pub regions: Vec<PresetRegion>,
    #[serde(default)]
    pub when_frontmost_only: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MaskRule {
    pub name: String,
    #[serde(default)]
    pub bundle_id: Option<String>,
    #[serde(default)]
    pub title_contains: Option<String>,
    pub regions: Vec<PresetRegion>,
    #[serde(default)]
    pub when_frontmost_only: bool,
}

#[derive(Clone, Debug, PartialEq, Default, Serialize, Deserialize)]
pub struct Presets {
    #[serde(default)]
    pub default_mode: Option<RedactMode>,
    #[serde(default)]
    pub apps: HashMap<String, AppPreset>,
    #[serde(default)]
    pub rules: Vec<MaskRule>,
    #[serde(default)]
    pub allowlist: Vec<String>,
    #[serde(default = "default_true")]
    pub mask_notifications: bool,
}

fn default_true() -> bool { true }

impl Presets {
    pub fn default_mode(&self) -> RedactMode { self.default_mode.clone().unwrap_or_default() }
}
