use crate::presets::*;
use std::collections::HashSet;

/// Geometry of the captured display: bounds in points (top-left origin, global), scale, pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Display {
    pub bounds: Rect,
    pub scale: f64,
    pub pixel_w: f64,
    pub pixel_h: f64,
}

/// One on-screen window; the slice passed to `resolve` must be front-to-back.
#[derive(Clone, Debug, PartialEq)]
pub struct Window {
    pub id: u64,
    pub pid: i64,
    pub app_id: Option<String>,
    pub bounds: Rect,
    /// 0 = normal application window.
    pub layer: i32,
    pub alpha: f64,
    /// false if the window is invisible to screen capture (so it must not occlude).
    pub capturable: bool,
    pub title: Option<String>,
}

impl Window {
    fn is_normal_visible(&self) -> bool { self.layer == 0 && self.alpha > 0.0 && !self.bounds.is_empty() }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PixelRegion {
    pub rect: Rect,
    pub mode: RedactMode,
    pub shape: Shape,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Options {
    pub allowlist_mode: bool,
    pub revealed: HashSet<String>,
    pub disabled: HashSet<String>,
    /// Emit bottom-left-origin rects (Core Image). Default: top-left like the frame buffer.
    pub flip_y: bool,
    pub ignore_pids: HashSet<i64>,
    pub frontmost_app_id: Option<String>,
}

pub const MAX_REGIONS: usize = 64;
pub const NOTIFICATION_CENTER_ID: &str = "com.apple.notificationcenterui";

/// `a` minus `b` as ≤ 4 non-overlapping rects.
pub fn subtract(b: &Rect, a: &Rect) -> Vec<Rect> {
    let i = a.intersection(b);
    if i.is_empty() {
        return vec![*a];
    }
    let mut out = Vec::with_capacity(4);
    if i.y > a.y { out.push(Rect::new(a.x, a.y, a.w, i.y - a.y)); }
    if i.max_y() < a.max_y() { out.push(Rect::new(a.x, i.max_y(), a.w, a.max_y() - i.max_y())); }
    if i.x > a.x { out.push(Rect::new(a.x, i.y, i.x - a.x, i.h)); }
    if i.max_x() < a.max_x() { out.push(Rect::new(i.max_x(), i.y, a.max_x() - i.max_x(), i.h)); }
    out.into_iter().filter(|r| !r.is_empty()).collect()
}

/// Points (top-left, global) → frame pixels, snapped outwards to whole pixels.
pub fn to_pixels(r: &Rect, d: &Display, flip_y: bool) -> Rect {
    let x0 = ((r.x - d.bounds.x) * d.scale).floor();
    let x1 = ((r.max_x() - d.bounds.x) * d.scale).ceil();
    let y0 = ((r.y - d.bounds.y) * d.scale).floor();
    let y1 = ((r.max_y() - d.bounds.y) * d.scale).ceil();
    let frame = Rect::new(0.0, 0.0, d.pixel_w, d.pixel_h);
    let top_left = Rect::new(x0, y0, x1 - x0, y1 - y0).intersection(&frame);
    if flip_y {
        Rect::new(top_left.x, d.pixel_h - top_left.max_y(), top_left.w, top_left.h)
    } else {
        top_left
    }
}

pub fn resolve(presets: &Presets, windows: &[Window], display: &Display, opts: &Options) -> Vec<PixelRegion> {
    let mut out: Vec<PixelRegion> = Vec::new();
    let mut overflow: Vec<PixelRegion> = Vec::new();
    let frame = Rect::new(0.0, 0.0, display.pixel_w, display.pixel_h);
    let ignored = |w: &Window| opts.ignore_pids.contains(&w.pid);

    let mut emit = |out: &mut Vec<PixelRegion>, pieces: &[Rect], unoccluded: &Rect, mode: &RedactMode, shape: Shape| {
        if out.len() + pieces.len() > MAX_REGIONS {
            overflow.push(PixelRegion { rect: to_pixels(unoccluded, display, opts.flip_y), mode: mode.clone(), shape: Shape::Rect });
            return;
        }
        for p in pieces {
            out.push(PixelRegion { rect: to_pixels(p, display, opts.flip_y), mode: mode.clone(), shape });
        }
    };

    // 1. Allowlist mode: whole frame minus visible parts of allowed windows.
    if opts.allowlist_mode {
        let allowed: HashSet<&str> = presets.allowlist.iter().map(|s| s.as_str()).chain(opts.revealed.iter().map(|s| s.as_str())).collect();
        let is_allowed = |w: &Window| w.app_id.as_deref().map(|a| allowed.contains(a)).unwrap_or(false);
        let mut visible: Vec<Rect> = Vec::new();
        for (index, w) in windows.iter().enumerate() {
            if !w.is_normal_visible() || ignored(w) || !is_allowed(w) { continue; }
            let mut pieces: Vec<Rect> = vec![w.bounds.intersection(&display.bounds)].into_iter().filter(|r| !r.is_empty()).collect();
            for front in &windows[..index] {
                if front.is_normal_visible() && !ignored(front) && !is_allowed(front) && front.bounds.intersects(&w.bounds) {
                    pieces = pieces.iter().flat_map(|p| subtract(&front.bounds, p)).collect();
                }
            }
            visible.extend(pieces);
        }
        let mut masked = vec![display.bounds];
        for v in &visible {
            masked = masked.iter().flat_map(|m| subtract(v, m)).collect();
        }
        if masked.len() > MAX_REGIONS / 2 {
            out.push(PixelRegion { rect: frame, mode: presets.default_mode(), shape: Shape::Rect });
        } else {
            emit(&mut out, &masked, &display.bounds, &presets.default_mode(), Shape::Rect);
        }
    }

    // 2. Per-app presets and title rules.
    for (index, window) in windows.iter().enumerate() {
        if !window.is_normal_visible() || ignored(window) { continue; }
        let app_id = window.app_id.clone().unwrap_or_default();
        if opts.revealed.contains(&app_id) || opts.disabled.contains(&app_id) { continue; }
        let is_front = opts.frontmost_app_id.as_deref() == Some(app_id.as_str());

        let mut regions: Vec<(&PresetRegion, String)> = Vec::new();
        if let Some(app) = presets.apps.get(&app_id) {
            if !(app.when_frontmost_only && !is_front) {
                regions.extend(app.regions.iter().map(|r| (r, format!("{}/{}", app_id, r.name))));
            }
        }
        for rule in &presets.rules {
            let matches_bundle = rule.bundle_id.as_deref().map(|b| b == app_id).unwrap_or(true);
            let matches_title = match &rule.title_contains {
                Some(t) => window.title.as_deref().map(|title| title.to_lowercase().contains(&t.to_lowercase())).unwrap_or(false),
                None => true,
            };
            let has_criteria = rule.bundle_id.is_some() || rule.title_contains.is_some();
            if has_criteria && matches_bundle && matches_title && !(rule.when_frontmost_only && !is_front)
                && !opts.disabled.contains(&format!("rule:{}", rule.name)) {
                regions.extend(rule.regions.iter().map(|r| (r, format!("rule:{}/{}", rule.name, r.name))));
            }
        }
        if regions.is_empty() { continue; }

        let occluders: Vec<&Window> = windows[..index].iter()
            .filter(|o| o.is_normal_visible() && o.id != window.id && o.capturable && !ignored(o) && o.bounds.intersects(&window.bounds))
            .collect();

        for (region, key) in regions {
            if opts.disabled.contains(&key) { continue; }
            let w = window.bounds;
            let absolute = Rect::new(w.x + region.rect.x * w.w, w.y + region.rect.y * w.h, region.rect.w * w.w, region.rect.h * w.h);
            let clipped = absolute.intersection(&display.bounds);
            if clipped.is_empty() { continue; }
            let mut pieces = vec![clipped];
            for o in &occluders {
                pieces = pieces.iter().flat_map(|p| subtract(&o.bounds, p)).collect();
                if pieces.is_empty() { break; }
            }
            if region.shape == Shape::Ellipse && pieces.len() == 1 && pieces[0] == clipped && clipped == absolute {
                emit(&mut out, &[clipped], &clipped, &region.mode, Shape::Ellipse);
                continue;
            }
            emit(&mut out, &pieces, &clipped, &region.mode, Shape::Rect);
        }
    }

    // 3. Notification banners (any layer, solid black, no occlusion).
    if presets.mask_notifications && !opts.disabled.contains(NOTIFICATION_CENTER_ID) {
        for w in windows.iter().filter(|w| w.app_id.as_deref() == Some(NOTIFICATION_CENTER_ID) && w.alpha > 0.0) {
            let r = w.bounds.intersection(&display.bounds);
            if r.w > 8.0 && r.h > 8.0 {
                emit(&mut out, &[r], &r, &RedactMode::Solid { color: [0.0, 0.0, 0.0, 1.0] }, Shape::Rect);
            }
        }
    }

    if !overflow.is_empty() {
        let union = overflow[1..].iter().fold(overflow[0].rect, |acc, r| acc.union(&r.rect));
        if out.len() < MAX_REGIONS {
            out.push(PixelRegion { rect: union, mode: overflow[0].mode.clone(), shape: Shape::Rect });
        } else {
            let last = out.len() - 1;
            out[last] = PixelRegion { rect: out[last].rect.union(&union), mode: RedactMode::Solid { color: [0.0, 0.0, 0.0, 1.0] }, shape: Shape::Rect };
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn display_1000() -> Display { Display { bounds: Rect::new(0.0, 0.0, 1000.0, 1000.0), scale: 1.0, pixel_w: 1000.0, pixel_h: 1000.0 } }
    fn retina() -> Display { Display { bounds: Rect::new(0.0, 0.0, 1470.0, 956.0), scale: 2.0, pixel_w: 2940.0, pixel_h: 1912.0 } }
    fn win(id: u64, app: &str, r: Rect) -> Window {
        Window { id, pid: 1, app_id: Some(app.into()), bounds: r, layer: 0, alpha: 1.0, capturable: true, title: None }
    }
    fn chat_presets() -> Presets {
        let mut p = Presets::default();
        p.apps.insert("chat".into(), AppPreset { regions: vec![PresetRegion { name: "list".into(), rect: Rect::new(0.0, 0.0, 0.5, 1.0), mode: RedactMode::default(), shape: Shape::Rect }], when_frontmost_only: false });
        p
    }

    #[test]
    fn retina_scales_and_flips() {
        let out = resolve(&chat_presets(), &[win(1, "chat", Rect::new(100.0, 200.0, 400.0, 300.0))], &retina(), &Options { flip_y: true, ..Default::default() });
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].rect, Rect::new(200.0, 912.0, 400.0, 600.0));
        let tl = resolve(&chat_presets(), &[win(1, "chat", Rect::new(100.0, 200.0, 400.0, 300.0))], &retina(), &Options::default());
        assert_eq!(tl[0].rect, Rect::new(200.0, 400.0, 400.0, 600.0));
    }

    #[test]
    fn occluder_in_front_is_subtracted() {
        let target = win(1, "chat", Rect::new(0.0, 0.0, 1000.0, 1000.0));
        let terminal = win(2, "term", Rect::new(200.0, 200.0, 600.0, 200.0));
        let out = resolve(&chat_presets(), &[terminal, target], &display_1000(), &Options::default());
        assert_eq!(out.len(), 3);
        let hole = Rect::new(201.0, 201.0, 598.0, 198.0);
        assert!(out.iter().all(|r| !r.rect.intersects(&hole)));
        let area: f64 = out.iter().map(|r| r.rect.w * r.rect.h).sum();
        assert_eq!(area, 500.0 * 1000.0 - 300.0 * 200.0);
    }

    #[test]
    fn non_capturable_window_does_not_punch_hole() {
        let target = win(1, "chat", Rect::new(0.0, 0.0, 1000.0, 1000.0));
        let mut hidden = win(2, "pw", Rect::new(0.0, 0.0, 400.0, 400.0));
        hidden.capturable = false;
        let out = resolve(&chat_presets(), &[hidden, target], &display_1000(), &Options::default());
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].rect, Rect::new(0.0, 0.0, 500.0, 1000.0));
    }

    #[test]
    fn allowlist_masks_everything_but_allowed() {
        let mut p = chat_presets();
        p.allowlist = vec!["slides".into()];
        let slides = win(1, "slides", Rect::new(200.0, 200.0, 400.0, 400.0));
        let front = win(2, "other", Rect::new(100.0, 100.0, 200.0, 600.0));
        let out = resolve(&p, &[front, slides], &display_1000(), &Options { allowlist_mode: true, ..Default::default() });
        let masked = |x: f64, y: f64| out.iter().any(|r| r.rect.contains(x, y));
        assert!(masked(50.0, 50.0));
        assert!(masked(150.0, 300.0));
        assert!(masked(250.0, 300.0));
        assert!(!masked(450.0, 400.0));
    }

    #[test]
    fn title_rule_and_reveal() {
        let mut p = Presets::default();
        p.rules.push(MaskRule { name: "wa".into(), bundle_id: None, title_contains: Some("whatsapp".into()),
            regions: vec![PresetRegion { name: "all".into(), rect: Rect::new(0.0, 0.0, 1.0, 1.0), mode: RedactMode::default(), shape: Shape::Rect }], when_frontmost_only: false });
        let mut w = win(1, "browser", Rect::new(0.0, 0.0, 200.0, 200.0));
        w.title = Some("WhatsApp Web".into());
        assert_eq!(resolve(&p, &[w.clone()], &display_1000(), &Options::default()).len(), 1);
        let revealed: HashSet<String> = ["browser".to_string()].into_iter().collect();
        assert!(resolve(&p, &[w], &display_1000(), &Options { revealed, ..Default::default() }).is_empty());
    }

    #[test]
    fn overflow_collapses_safely() {
        let mut windows: Vec<Window> = (0..70).map(|i| win(10 + i, "x", Rect::new(10.0 + i as f64 * 6.0, 10.0 + i as f64 * 12.0, 3.0, 3.0))).collect();
        windows.push(win(1, "chat", Rect::new(0.0, 0.0, 1000.0, 1000.0)));
        let out = resolve(&chat_presets(), &windows, &display_1000(), &Options::default());
        assert!(out.len() <= MAX_REGIONS);
        let union = out[1..].iter().fold(out[0].rect, |a, r| a.union(&r.rect));
        assert!(union.contains(0.0, 0.0) && union.contains(499.0, 999.0));
    }

    #[test]
    fn presets_parse_from_json() {
        let json = r#"{"apps":{"a":{"regions":[{"name":"r","rect":{"x":0,"y":0,"w":0.5,"h":1},"mode":"blur","radius":30}]}},"rules":[{"name":"wa","title_contains":"WhatsApp","regions":[{"name":"all","rect":{"x":0,"y":0,"w":1,"h":1},"mode":"pixellate","scale":24,"shape":"ellipse"}]}]}"#;
        let p: Presets = serde_json::from_str(json).unwrap();
        assert_eq!(p.apps["a"].regions[0].mode, RedactMode::Blur { radius: 30.0 });
        assert_eq!(p.rules[0].regions[0].shape, Shape::Ellipse);
        assert!(p.mask_notifications);
    }
}
