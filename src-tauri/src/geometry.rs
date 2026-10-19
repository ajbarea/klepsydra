//! Window placement arithmetic, kept free of Tauri so it can be unit tested.
//! Everything is in physical desktop pixels.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub fn new(x: i32, y: i32, w: i32, h: i32) -> Self {
        Rect { x, y, w, h }
    }

    fn overlap(&self, o: &Rect) -> i64 {
        let w = (self.x + self.w).min(o.x + o.w) - self.x.max(o.x);
        let h = (self.y + self.h).min(o.y + o.h) - self.y.max(o.y);
        if w > 0 && h > 0 {
            w as i64 * h as i64
        } else {
            0
        }
    }

    /// Squared distance between centres, doubled to stay in integers.
    fn centre_distance(&self, o: &Rect) -> i64 {
        let dx = (2 * self.x + self.w) as i64 - (2 * o.x + o.w) as i64;
        let dy = (2 * self.y + self.h) as i64 - (2 * o.y + o.h) as i64;
        dx * dx + dy * dy
    }
}

/// A monitor as it was seen, enough to recognise it again, with its display
/// scale so a window's physical size there can be known before it moves.
#[derive(Clone, Debug, PartialEq)]
pub struct Display {
    pub name: Option<String>,
    pub bounds: Rect,
    pub scale: f64,
}

impl Display {
    /// A window of `w` x `h` CSS pixels, in this monitor's physical pixels.
    fn physical(&self, w: f64, h: f64) -> (i32, i32) {
        (
            (w * self.scale).round() as i32,
            (h * self.scale).round() as i32,
        )
    }
}

/// The window "Set home here" saved, with the monitor it was on.
#[derive(Clone, Debug, PartialEq)]
pub struct Home {
    pub rect: Rect,
    pub display: Display,
}

/// Shift `r` until it lies inside `bounds`. One larger than `bounds` keeps
/// its top-left corner on the bounds' own.
pub fn clamp_into(r: Rect, bounds: Rect) -> Rect {
    let x = r.x.min(bounds.x + bounds.w - r.w).max(bounds.x);
    let y = r.y.min(bounds.y + bounds.h - r.h).max(bounds.y);
    Rect { x, y, ..r }
}

/// Resize keeping fixed the edges nearest the monitor's: a gauge parked in the
/// lower half grows upward, one in the right half grows leftward.
pub fn grow_from_edges(old: Rect, w: i32, h: i32, monitor: Rect) -> Rect {
    let right_half = 2 * old.x + old.w > 2 * monitor.x + monitor.w;
    let lower_half = 2 * old.y + old.h > 2 * monitor.y + monitor.h;
    let x = if right_half { old.x + old.w - w } else { old.x };
    let y = if lower_half { old.y + old.h - h } else { old.y };
    Rect { x, y, w, h }
}

/// Resize around a point: the content under (`px`, `py`) stays under it when
/// everything grows by `ratio`, as a map zooms around the pointer.
pub fn grow_from_point(old: Rect, w: i32, h: i32, px: i32, py: i32, ratio: f64) -> Rect {
    let x = px - ((px - old.x) as f64 * ratio).round() as i32;
    let y = py - ((py - old.y) as f64 * ratio).round() as i32;
    Rect { x, y, w, h }
}

/// The monitor home was saved on, as attached now: the one at the same bounds
/// (names like `\\.\DISPLAY1` are reassigned on re-plugging), else the one
/// with the same name, else the one nearest where home was.
fn find_display<'a>(home: &Home, displays: &'a [Display]) -> Option<&'a Display> {
    let saved = &home.display;
    displays
        .iter()
        .find(|d| d.bounds == saved.bounds)
        .or_else(|| {
            let name = saved.name.as_ref()?;
            displays.iter().find(|d| d.name.as_ref() == Some(name))
        })
        .or_else(|| {
            displays.iter().max_by_key(|d| {
                (
                    d.bounds.overlap(&home.rect),
                    -d.bounds.centre_distance(&home.rect),
                )
            })
        })
}

/// Keep an edge that sat flush with the monitor's flush after a resize, so a
/// gauge docked on the screen edge over the taskbar stays docked through a
/// zoom around the pointer.
pub fn keep_docked(from: Rect, to: Rect, monitor: Rect) -> Rect {
    let flush = |a: i32, b: i32| (a - b).abs() <= 1;
    let mut r = to;
    if flush(from.x + from.w, monitor.x + monitor.w) {
        r.x = monitor.x + monitor.w - r.w;
    } else if flush(from.x, monitor.x) {
        r.x = monitor.x;
    }
    if flush(from.y + from.h, monitor.y + monitor.h) {
        r.y = monitor.y + monitor.h - r.h;
    } else if flush(from.y, monitor.y) {
        r.y = monitor.y;
    }
    r
}

/// Where home is now, for a window of `w` x `h` CSS pixels. Home keeps its
/// corner nearest the screen edges, as `grow_from_edges` does, so one parked
/// on the taskbar stays on it whatever the gauge's size; that corner's offset
/// is rescaled if the monitor's resolution changed, and the window is sized
/// at the monitor's own scale and kept wholly on it. `None` with no monitors.
pub fn home_rect(home: &Home, w: f64, h: f64, displays: &[Display]) -> Option<Rect> {
    let target = find_display(home, displays)?;
    let (saved, now) = (home.display.bounds, target.bounds);
    let was = home.rect;
    let right = 2 * was.x + was.w > 2 * saved.x + saved.w;
    let lower = 2 * was.y + was.h > 2 * saved.y + saved.h;
    let scaled = |offset: i32, to: i32, from: i32| {
        if from > 0 {
            (offset as f64 * to as f64 / from as f64).round() as i32
        } else {
            offset
        }
    };
    let ax = if right { was.x + was.w } else { was.x };
    let ay = if lower { was.y + was.h } else { was.y };
    let ax = now.x + scaled(ax - saved.x, now.w, saved.w);
    let ay = now.y + scaled(ay - saved.y, now.h, saved.h);
    let (w, h) = target.physical(w, h);
    let x = if right { ax - w } else { ax };
    let y = if lower { ay - h } else { ay };
    Some(clamp_into(Rect::new(x, y, w, h), now))
}

/// The spot with no home saved: over the taskbar of `primary`, 220 CSS pixels
/// in from its right edge, sized at its scale.
pub fn default_rect(primary: &Display, w: f64, h: f64) -> Rect {
    let m = primary.bounds;
    let (w, h) = primary.physical(w, h);
    let inset = (220.0 * primary.scale).round() as i32;
    clamp_into(Rect::new(m.x + m.w - w - inset, m.y + m.h - h, w, h), m)
}

/// A rectangle the frontend reported, in CSS pixels from the window's
/// top-left, as physical desktop edges (left, top, right, bottom) for a window
/// at `origin` of `size` and display `scale`: grown by `margin` each way, then,
/// when `band` is given, kept that far inside the window's own edges.
pub fn hit_area(
    css: [f64; 4],
    origin: (f64, f64),
    size: (f64, f64),
    scale: f64,
    margin: f64,
    band: Option<f64>,
) -> (f64, f64, f64, f64) {
    let left = origin.0 + css[0] * scale - margin;
    let top = origin.1 + css[1] * scale - margin;
    let right = left + css[2] * scale + margin * 2.0;
    let bottom = top + css[3] * scale + margin * 2.0;
    match band {
        None => (left, top, right, bottom),
        Some(b) => (
            left.max(origin.0 + b),
            top.max(origin.1 + b),
            right.min(origin.0 + size.0 - b),
            bottom.min(origin.1 + size.1 - b),
        ),
    }
}

/// Whether (`x`, `y`) lies within edges from `hit_area`, edges included.
pub fn contains((left, top, right, bottom): (f64, f64, f64, f64), x: f64, y: f64) -> bool {
    x >= left && x <= right && y >= top && y <= bottom
}

/// How far inside the window's edges tao's Linux resize band reaches, in
/// physical pixels at display `scale`.
pub fn resize_inset(scale: f64) -> f64 {
    const TAO_RESIZE_BORDER: f64 = 5.0; // tao's linux/event_loop.rs
    (TAO_RESIZE_BORDER + 1.0) * scale
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCREEN: Rect = Rect {
        x: 0,
        y: 0,
        w: 1920,
        h: 1080,
    };

    fn display(name: &str, bounds: Rect) -> Display {
        Display {
            name: Some(name.into()),
            bounds,
            scale: 1.0,
        }
    }

    fn home(rect: Rect, display: Display) -> Home {
        Home { rect, display }
    }

    #[test]
    fn clamp_pulls_an_overhang_back_on_screen() {
        assert_eq!(
            clamp_into(Rect::new(1700, 1050, 420, 100), SCREEN),
            Rect::new(1500, 980, 420, 100)
        );
        assert_eq!(
            clamp_into(Rect::new(-50, -20, 420, 100), SCREEN),
            Rect::new(0, 0, 420, 100)
        );
        assert_eq!(
            clamp_into(Rect::new(10, 10, 420, 100), SCREEN),
            Rect::new(10, 10, 420, 100)
        );
    }

    #[test]
    fn clamp_keeps_an_oversized_window_at_the_top_left() {
        assert_eq!(
            clamp_into(Rect::new(300, 300, 4000, 100), SCREEN),
            Rect::new(0, 300, 4000, 100)
        );
    }

    #[test]
    fn a_gauge_parked_low_grows_upward() {
        // Over the taskbar, bottom-right: a new row must not push it off screen.
        let old = Rect::new(1280, 1022, 420, 58);
        assert_eq!(
            grow_from_edges(old, 420, 100, SCREEN),
            Rect::new(1280, 980, 420, 100)
        );
        assert_eq!(
            grow_from_edges(old, 500, 58, SCREEN),
            Rect::new(1200, 1022, 500, 58)
        );
    }

    #[test]
    fn a_gauge_parked_high_and_left_grows_down_and_right() {
        let old = Rect::new(20, 20, 420, 58);
        assert_eq!(
            grow_from_edges(old, 500, 100, SCREEN),
            Rect::new(20, 20, 500, 100)
        );
    }

    #[test]
    fn edges_are_judged_against_the_gauges_own_monitor() {
        // Left half of a second monitor sitting to the right of the first.
        let right = Rect::new(1920, 0, 1920, 1080);
        let old = Rect::new(2000, 20, 420, 58);
        assert_eq!(
            grow_from_edges(old, 500, 100, right),
            Rect::new(2000, 20, 500, 100)
        );
    }

    #[test]
    fn zoom_keeps_the_point_under_the_pointer() {
        // Pointer on the grip, 20px in and 30px down from the window's corner.
        let old = Rect::new(1000, 900, 420, 100);
        let new = grow_from_point(old, 462, 110, 1020, 930, 1.1);
        assert_eq!(new, Rect::new(998, 897, 462, 110));
        // The grip point is 22px in and 33px down at the new size: still under the pointer.
        assert_eq!((1020 - new.x, 930 - new.y), (22, 33));
    }

    #[test]
    fn an_edge_flush_with_the_monitor_stays_flush() {
        // Bottom on the screen edge, over the taskbar; zooming out around the
        // pointer would lift it.
        let from = Rect::new(1280, 980, 420, 100);
        let zoomed = grow_from_point(from, 382, 91, 1290, 1050, 1.0 / 1.1);
        assert_ne!(zoomed.y + zoomed.h, 1080);
        let kept = keep_docked(from, zoomed, SCREEN);
        assert_eq!((kept.x, kept.y + kept.h), (zoomed.x, 1080));
    }

    #[test]
    fn a_right_edge_flush_with_the_monitor_stays_flush() {
        let from = Rect::new(1500, 400, 420, 100);
        let zoomed = grow_from_point(from, 462, 110, 1510, 450, 1.1);
        let kept = keep_docked(from, zoomed, SCREEN);
        assert_eq!(kept.x + kept.w, 1920);
    }

    #[test]
    fn a_floating_gauge_is_left_where_the_zoom_put_it() {
        let from = Rect::new(600, 400, 420, 100);
        let zoomed = grow_from_point(from, 462, 110, 610, 450, 1.1);
        assert_eq!(keep_docked(from, zoomed, SCREEN), zoomed);
    }

    #[test]
    fn zoom_out_then_in_returns_home() {
        let old = Rect::new(1000, 900, 420, 100);
        let out = grow_from_point(old, 382, 91, 1020, 930, 1.0 / 1.1);
        let back = grow_from_point(out, 420, 100, 1020, 930, 1.1);
        assert_eq!(back, old);
    }

    #[test]
    fn home_returns_exactly_where_it_was_saved() {
        let h = home(Rect::new(1280, 1022, 420, 58), display("DP-1", SCREEN));
        let now = [display("DP-1", SCREEN)];
        assert_eq!(
            home_rect(&h, 420.0, 58.0, &now),
            Some(Rect::new(1280, 1022, 420, 58))
        );
    }

    #[test]
    fn home_on_the_taskbar_stays_on_it_at_another_size() {
        // Saved zoomed in with two rows, bottom on the screen edge.
        let h = home(Rect::new(900, 880, 960, 200), display("DP-1", SCREEN));
        let now = [display("DP-1", SCREEN)];
        assert_eq!(
            home_rect(&h, 420.0, 58.0, &now),
            Some(Rect::new(1440, 1022, 420, 58))
        );
    }

    #[test]
    fn home_on_a_second_monitor_follows_it_by_name() {
        let second = Rect::new(1920, 0, 2560, 1440);
        let h = home(Rect::new(2100, 1300, 420, 58), display("DP-2", second));
        // The second monitor now sits to the left of the first.
        let moved = Rect::new(-2560, 0, 2560, 1440);
        let now = [display("DP-1", SCREEN), display("DP-2", moved)];
        assert_eq!(
            home_rect(&h, 420.0, 58.0, &now),
            Some(Rect::new(-2380, 1300, 420, 58))
        );
    }

    #[test]
    fn a_reassigned_name_does_not_beat_matching_bounds() {
        // Saved on the laptop panel as DISPLAY1; after docking, the external
        // monitor took that name and the panel became DISPLAY2.
        let h = home(Rect::new(100, 100, 420, 58), display("DISPLAY1", SCREEN));
        let now = [
            display("DISPLAY1", Rect::new(1920, 0, 2560, 1440)),
            display("DISPLAY2", SCREEN),
        ];
        assert_eq!(
            home_rect(&h, 420.0, 58.0, &now),
            Some(Rect::new(100, 100, 420, 58))
        );
    }

    #[test]
    fn home_on_an_unplugged_monitor_falls_to_the_nearest() {
        let second = Rect::new(1920, 0, 1920, 1080);
        let h = home(Rect::new(3000, 1000, 420, 58), display("DP-2", second));
        let now = [display("DP-1", SCREEN)];
        // Same corner offset on the remaining monitor, which is the same size.
        assert_eq!(
            home_rect(&h, 420.0, 58.0, &now),
            Some(Rect::new(1080, 1000, 420, 58))
        );
    }

    #[test]
    fn home_rescales_when_the_resolution_changes() {
        let h = home(Rect::new(1280, 1022, 420, 58), display("DP-1", SCREEN));
        let now = [display("DP-1", Rect::new(0, 0, 2560, 1440))];
        // The bottom-right corner keeps its relative place: still on the bottom edge.
        assert_eq!(
            home_rect(&h, 420.0, 58.0, &now),
            Some(Rect::new(1847, 1382, 420, 58))
        );
    }

    #[test]
    fn home_is_sized_at_the_target_monitors_scale() {
        let h = home(Rect::new(1280, 1022, 420, 58), display("DP-1", SCREEN));
        let hidpi = Display {
            scale: 1.5,
            ..display("DP-1", SCREEN)
        };
        // 420x58 CSS pixels are 630x87 there, and the bottom stays on the edge.
        assert_eq!(
            home_rect(&h, 420.0, 58.0, &[hidpi]),
            Some(Rect::new(1070, 993, 630, 87))
        );
    }

    #[test]
    fn home_is_kept_wholly_on_a_smaller_monitor() {
        let h = home(Rect::new(1700, 1050, 420, 58), display("DP-1", SCREEN));
        let now = [display("DP-1", SCREEN)];
        assert_eq!(
            home_rect(&h, 420.0, 58.0, &now),
            Some(Rect::new(1500, 1022, 420, 58))
        );
    }

    #[test]
    fn an_unnamed_monitor_is_matched_by_where_home_was() {
        let unnamed = |bounds| Display {
            name: None,
            bounds,
            scale: 1.0,
        };
        let h = home(Rect::new(100, 100, 420, 58), unnamed(SCREEN));
        let now = [unnamed(Rect::new(1920, 0, 1920, 1080)), unnamed(SCREEN)];
        assert_eq!(
            home_rect(&h, 420.0, 58.0, &now),
            Some(Rect::new(100, 100, 420, 58))
        );
    }

    #[test]
    fn the_default_spot_sits_on_the_primary_taskbar_at_its_scale() {
        assert_eq!(
            default_rect(&display("DP-1", SCREEN), 420.0, 58.0),
            Rect::new(1280, 1022, 420, 58)
        );
        let hidpi = Display {
            scale: 1.5,
            ..display("DP-1", SCREEN)
        };
        assert_eq!(
            default_rect(&hidpi, 420.0, 58.0),
            Rect::new(960, 993, 630, 87)
        );
    }

    #[test]
    fn no_monitors_means_no_home() {
        let h = home(Rect::new(0, 0, 420, 58), display("DP-1", SCREEN));
        assert_eq!(home_rect(&h, 420.0, 58.0, &[]), None);
    }

    #[test]
    fn a_hit_area_is_placed_and_scaled_with_the_window() {
        let a = hit_area(
            [14.0, 10.0, 12.0, 30.0],
            (100.0, 200.0),
            (630.0, 96.0),
            1.5,
            0.0,
            None,
        );
        assert_eq!(a, (121.0, 215.0, 139.0, 260.0));
        assert!(contains(a, 121.0, 260.0));
        assert!(!contains(a, 120.9, 230.0));
    }

    #[test]
    fn a_margin_grows_the_area_each_way() {
        let a = hit_area(
            [14.0, 10.0, 12.0, 30.0],
            (0.0, 0.0),
            (630.0, 64.0),
            1.0,
            8.0,
            None,
        );
        assert_eq!(a, (6.0, 2.0, 34.0, 48.0));
    }

    #[test]
    fn a_band_keeps_the_strip_off_the_window_edges() {
        // The strip runs to the window's right edge; a press in the resize
        // band there must pass through, as for the grip.
        let a = hit_area(
            [430.0, 0.0, 200.0, 64.0],
            (0.0, 0.0),
            (630.0, 64.0),
            1.0,
            0.0,
            Some(6.0),
        );
        assert_eq!(a, (430.0, 6.0, 624.0, 58.0));
        assert!(!contains(a, 627.0, 30.0));
        assert!(contains(a, 624.0, 6.0));
        assert!(contains(a, 430.0, 58.0));
        assert!(!contains(a, 624.1, 30.0));
        assert!(!contains(a, 500.0, 5.9));
    }

    #[test]
    fn a_band_clamps_all_four_edges_off_origin() {
        let (ox, oy) = (-1920.0, 100.0);
        let size = (945.0, 144.0);
        let b = 9.0;
        let a = hit_area([0.0, 0.0, 630.0, 96.0], (ox, oy), size, 1.5, 0.0, Some(b));
        assert_eq!(a, (ox + b, oy + b, ox + size.0 - b, oy + size.1 - b));
    }

    #[test]
    fn the_resize_band_is_tao_border_plus_one_scaled() {
        assert_eq!(resize_inset(1.0), 6.0);
        assert_eq!(resize_inset(1.5), 9.0);
    }
}
