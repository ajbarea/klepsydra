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

/// A monitor as it was seen, enough to recognise it again.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Display {
    pub name: Option<String>,
    pub bounds: Rect,
}

/// The position "Set home here" saved, with the monitor it was on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Home {
    pub x: i32,
    pub y: i32,
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

/// Where home is now. The saved monitor is matched by name, or failing that the
/// monitor nearest where home was; the offset within it is rescaled if its
/// resolution changed, and the window is kept wholly on it. `None` with no
/// monitors at all.
pub fn home_rect(home: &Home, w: i32, h: i32, displays: &[Display]) -> Option<Rect> {
    let saved = home.display.bounds;
    let was = Rect::new(home.x, home.y, w, h);
    let target = home
        .display
        .name
        .as_ref()
        .and_then(|n| displays.iter().find(|d| d.name.as_ref() == Some(n)))
        .or_else(|| {
            displays
                .iter()
                .max_by_key(|d| (d.bounds.overlap(&was), -d.bounds.centre_distance(&was)))
        })?
        .bounds;
    let scaled = |offset: i32, now: i32, then: i32| {
        if then > 0 {
            (offset as f64 * now as f64 / then as f64).round() as i32
        } else {
            offset
        }
    };
    let x = target.x + scaled(home.x - saved.x, target.w, saved.w);
    let y = target.y + scaled(home.y - saved.y, target.h, saved.h);
    Some(clamp_into(Rect::new(x, y, w, h), target))
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
        }
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
    fn zoom_out_then_in_returns_home() {
        let old = Rect::new(1000, 900, 420, 100);
        let out = grow_from_point(old, 382, 91, 1020, 930, 1.0 / 1.1);
        let back = grow_from_point(out, 420, 100, 1020, 930, 1.1);
        assert_eq!(back, old);
    }

    #[test]
    fn home_returns_exactly_where_it_was_saved() {
        let home = Home {
            x: 1280,
            y: 1022,
            display: display("\\\\.\\DISPLAY1", SCREEN),
        };
        let now = [display("\\\\.\\DISPLAY1", SCREEN)];
        assert_eq!(
            home_rect(&home, 420, 58, &now),
            Some(Rect::new(1280, 1022, 420, 58))
        );
    }

    #[test]
    fn home_on_a_second_monitor_follows_it_by_name() {
        let second = Rect::new(1920, 0, 2560, 1440);
        let home = Home {
            x: 2100,
            y: 1300,
            display: display("DP-2", second),
        };
        // The second monitor now sits to the left of the first.
        let moved = Rect::new(-2560, 0, 2560, 1440);
        let now = [display("DP-1", SCREEN), display("DP-2", moved)];
        assert_eq!(
            home_rect(&home, 420, 58, &now),
            Some(Rect::new(-2380, 1300, 420, 58))
        );
    }

    #[test]
    fn home_on_an_unplugged_monitor_falls_to_the_nearest() {
        let second = Rect::new(1920, 0, 1920, 1080);
        let home = Home {
            x: 3000,
            y: 1000,
            display: display("DP-2", second),
        };
        let now = [display("DP-1", SCREEN)];
        // Same offset on the remaining monitor, which is the same size.
        assert_eq!(
            home_rect(&home, 420, 58, &now),
            Some(Rect::new(1080, 1000, 420, 58))
        );
    }

    #[test]
    fn home_rescales_when_the_resolution_changes() {
        let home = Home {
            x: 1280,
            y: 1022,
            display: display("DP-1", SCREEN),
        };
        let now = [display("DP-1", Rect::new(0, 0, 2560, 1440))];
        // 1280/1920 of the way across and 1022/1080 down, then kept on screen.
        assert_eq!(
            home_rect(&home, 420, 58, &now),
            Some(Rect::new(1707, 1363, 420, 58))
        );
    }

    #[test]
    fn home_is_kept_wholly_on_a_smaller_monitor() {
        let home = Home {
            x: 1700,
            y: 1050,
            display: display("DP-1", SCREEN),
        };
        let now = [display("DP-1", SCREEN)];
        assert_eq!(
            home_rect(&home, 420, 58, &now),
            Some(Rect::new(1500, 1022, 420, 58))
        );
    }

    #[test]
    fn an_unnamed_monitor_is_matched_by_where_home_was() {
        let home = Home {
            x: 100,
            y: 100,
            display: Display {
                name: None,
                bounds: SCREEN,
            },
        };
        let now = [
            Display {
                name: None,
                bounds: Rect::new(1920, 0, 1920, 1080),
            },
            Display {
                name: None,
                bounds: SCREEN,
            },
        ];
        assert_eq!(
            home_rect(&home, 420, 58, &now),
            Some(Rect::new(100, 100, 420, 58))
        );
    }

    #[test]
    fn no_monitors_means_no_home() {
        let home = Home {
            x: 0,
            y: 0,
            display: display("DP-1", SCREEN),
        };
        assert_eq!(home_rect(&home, 420, 58, &[]), None);
    }
}
