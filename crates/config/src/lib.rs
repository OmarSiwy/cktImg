//! Opinion-based knobs, read once from `lint.toml` (cwd) per process.
//!
//! Spacing/density choices (how far apart columns sit, how wide a routing channel is) and
//! render style (colors, line weights, padding) are *opinions* — different houses draw
//! schematics differently. They live here, out of code constants, so they're tunable
//! without recompiling. Geometric invariants (`devices::CELL_WIDTH`) are NOT here: they
//! are load-bearing, not taste.
//!
//! Place a `lint.toml` next to where you run the tool. Any missing key falls back to the
//! default below, so a partial file is fine. Point `CKT_LINT` at another path to override.

use serde::Deserialize;
use std::sync::OnceLock;

/// The whole config tree. Absent sections/keys use their `Default`.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub layout: Layout,
    pub render: Render,
}

/// Placement & routing spacing (§4/§5). Units are placement-grid integers.
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Layout {
    /// Minimum vertical gap between stacked devices when optimallen = 0 (abut).
    pub abut_gap: i32,
    /// Extra vertical room per fan-out tap.
    pub tap_unit: i32,
    /// One wire gauge: channel width per wire/riser occupying an inter-column gap, and the
    /// one-gauge floor every gap reserves so a stub can always run a vertical line. No fixed
    /// channel base — width is the sum of the gauges actually reserved (ALGORITHM.md §Spacing).
    pub track_w: i32,
    /// Margin track pitch.
    pub track_h: i32,
    /// Clearance from device field to first margin track.
    pub margin_gap: i32,
    /// Clearance from device field to the VDD/GND rail bus.
    pub bus_gap: i32,
    /// Enumerate column orders up to this spline count; beyond it use a greedy
    /// nearest-neighbor heuristic. Higher = more search, factorial cost. (10! = 3 628 800.)
    pub enum_limit: usize,
}

impl Default for Layout {
    fn default() -> Self {
        Layout {
            abut_gap: 8,
            tap_unit: 12,
            track_w: 8,
            track_h: 10,
            margin_gap: 16,
            bus_gap: 24,
            enum_limit: 10,
        }
    }
}

/// Render style, shared by every backend (svg, latex). Colors are bare hex (no `#`).
#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Render {
    /// Device symbol stroke color (CSS color or bare hex).
    pub stroke: String,
    /// Wire / pin-dot / junction color, bare hex (svg prefixes `#`, latex uppercases).
    pub wire: String,
    /// Device symbol stroke width.
    pub sym_w: f32,
    /// Wire stroke width.
    pub wire_w: f32,
    /// Drawing padding around the schematic bounds.
    pub pad: i32,
}

impl Default for Render {
    fn default() -> Self {
        Render {
            stroke: "black".into(),
            wire: "1565c0".into(),
            sym_w: 1.2,
            wire_w: 1.5,
            pad: 24,
        }
    }
}

/// The process-wide config, loaded from `lint.toml` on first access.
// ponytail: one config per process, loaded once. If a library consumer ever needs a
// different config per call, thread a `&Config` through layout()/render() instead of this.
pub fn cfg() -> &'static Config {
    static C: OnceLock<Config> = OnceLock::new();
    C.get_or_init(load)
}

fn load() -> Config {
    let path = std::env::var("CKT_LINT").unwrap_or_else(|_| "lint.toml".into());
    match std::fs::read_to_string(&path) {
        Ok(src) => toml::from_str(&src).unwrap_or_else(|e| {
            eprintln!("config: {path}: {e}; using defaults");
            Config::default()
        }),
        Err(_) => Config::default(), // no file -> defaults, silently
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partial_file_keeps_other_defaults() {
        let c: Config = toml::from_str("[layout]\nabut_gap = 99\n").unwrap();
        assert_eq!(c.layout.abut_gap, 99); // overridden
        assert_eq!(c.layout.bus_gap, 24); // still default
        assert_eq!(c.render.wire, "1565c0"); // whole section defaulted
    }

    #[test]
    fn unknown_key_is_rejected() {
        assert!(toml::from_str::<Config>("[layout]\nbogus = 1\n").is_err());
    }
}
