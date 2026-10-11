//! cktimg (D26, amended): converts a SPICE netlist into Schemify files with cktImg
//! (`extern/cktimg`, a Zig library with a C ABI) as the layout engine: one `.shcomp` per
//! `.subckt`, a `.shbench` for a top level (its dot cards and `.control` blocks as a
//! `code` block), and generated `.shprim` leaves for cards the bundled `core` cells cannot
//! re-emit faithfully. cktImg places and routes each cell (supplies up, grounds down,
//! signal left to right, labels where a wire would cross the circuit); this crate maps
//! the devices onto Schemify symbols, tells cktImg their geometry and writes its result
//! as records. The output is connectivity-equivalent to the input (`tests/roundtrip.rs`
//! checks it through `elab` and `tools/spicecmp`).
//!
//! Spine ([`convert`]), one transform per line:
//!
//! ```text
//! spice::parse(text)                         → deck    cells, devices, nets, code text
//! recognize::recognize(&deck)                → rec     symbols + per-device overrides
//! layout::library(&rec)                      → lib     cktImg classes = the symbols' pins
//! per cell: layout::draw(&mut lib, .., c)    → drawn   cktImg placement as Schemify geometry
//!           emit::cell_file(.., &drawn)      → file
//! per generated leaf: emit::leaf_file        → file
//! ```
//!
//! [`ffi`] is the thin safe wrapper over cktImg's C ABI; the wasm32 build adds the plugin
//! glue (`plugin` module): a File menu item and command `cktimg.import <path>`.
//!
//! # Examples
//!
//! ```
//! let out = cktimg::convert("rc.sp", "* rc\nV1 in 0 1\nR1 in out 1k\nC1 out 0 1n\n.tran 1u 1m\n");
//! assert_eq!(out.files.len(), 1);
//! assert_eq!(out.files[0].name, "rc.shbench");
//! let text = String::from_utf8(out.files[0].bytes.clone()).unwrap();
//! assert!(text.contains("core:res") && text.contains("| .tran 1u 1m"));
//! ```

#![deny(unsafe_code)] // `forbid` would reject the guest SDK's `export!` and `ffi` (they allow it)
#![warn(missing_docs)]

pub mod emit;
pub mod ffi;
pub mod layout;
pub mod recognize;
pub mod spice;

#[cfg(target_arch = "wasm32")]
mod alloc;
#[cfg(target_arch = "wasm32")]
mod plugin;

pub use emit::OutFile;

/// Devices cktImg draws per conversion (cells in file order, each wholly drawn by cktImg
/// or wholly labelled). With [`CELL_DEVICES_MAX`] it bounds a native conversion's time
/// and memory; the wasm guest is bounded by its fuel instead (cktImg needs ~10^8 fuel per
/// millisecond of native layout time, so the default 10^8 fits cells of about ten devices).
// ponytail: guards from measurements (docs/upstream/cktimg-performance.md); cells past
// them are drawn on a grid with every pin labelled, which stays correct.
pub const DRAWN_DEVICES_MAX: usize = 400;

/// Devices of one cell cktImg draws; a bigger cell is labelled. Why: cktImg's layout time
/// grows steeply with a cell's size on irregular circuits (a random 100-MOSFET mesh takes
/// 3.9 s natively and 20 MB, a 200-MOSFET one 71 s and 90 MB), while the largest regular
/// cells of the fixtures and corpus (117 devices) take 0.9 s and 26 MB.
pub const CELL_DEVICES_MAX: usize = 120;

/// Counts for the import log and the layout report.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    /// Cell files written (components and the bench).
    pub cells: u32,
    /// Device instances placed.
    pub devices: u32,
    /// Wire segments drawn.
    pub wires: u32,
    /// Labels and ports drawn.
    pub markers: u32,
    /// Nets with ≥ 2 device pins that are not drawn as rails.
    pub nets_multi: u32,
    /// Of those, nets drawn as one wired tree.
    pub nets_wired: u32,
}

/// Result of [`convert`].
#[derive(Clone, Debug, Default)]
pub struct Conversion {
    /// Files to write next to the source netlist: cells first (subckts in file order,
    /// then the bench), then generated leaves.
    pub files: Vec<OutFile>,
    /// Lines kept as code, dropped parameters and other notes.
    pub warnings: Vec<String>,
    /// Counts.
    pub stats: Stats,
}

/// Converts SPICE netlist `text`, read from project-relative `source` (which seeds the
/// ids and names the bench). Deterministic: equal arguments give equal bytes, natively
/// and in the wasm guest.
///
/// Cost: parse O(n log n); cktImg's placement and routing per cell (cells past
/// [`DRAWN_DEVICES_MAX`] devices in all are drawn with labels instead).
///
/// # Panics
///
/// Panics if `text` exceeds [`spice::TEXT_MAX`] bytes.
pub fn convert(source: &str, text: &str) -> Conversion {
    let deck = spice::parse(text);
    let rec = recognize::recognize(&deck);
    let (mut lib, refused) = layout::library(&rec);
    let mut out = Conversion::default();
    out.warnings.extend(deck.warnings.iter().cloned());
    out.warnings.extend(rec.warnings.iter().cloned());
    out.warnings.extend(refused);

    let mut taken: Vec<String> = rec.syms.stem.clone();
    let file = source.rsplit('/').next().unwrap_or(source);
    let base = file.rsplit_once('.').map_or(file, |(b, _)| b);
    let bench = recognize::unique_stem(base, &mut taken);
    let has_top = !deck.devs(0).is_empty() || deck.code_cell.contains(&0);
    let mut budget = DRAWN_DEVICES_MAX;
    for c in (1..deck.cells()).chain(has_top.then_some(0)) {
        let stem = if c == 0 {
            bench.clone()
        } else {
            rec.syms.stem[recognize::sub_symbol(c)].clone()
        };
        let drawn = layout::draw(&mut lib, &deck, &rec, c, &mut budget);
        if let Some(why) = &drawn.fallback {
            out.warnings
                .push(format!("{stem}: drawn with labels only ({why})"));
        }
        if drawn.strays > 0 {
            out.warnings.push(format!(
                "{stem}: cktImg left {} pins unconnected; labelled",
                drawn.strays
            ));
        }
        let s = &mut out.stats;
        s.cells += 1;
        s.devices += drawn.x.len() as u32;
        s.wires += drawn.wire.len() as u32;
        s.markers += drawn.mark_net.len() as u32;
        s.nets_multi += drawn.nets_multi;
        s.nets_wired += drawn.nets_wired;
        out.files
            .push(emit::cell_file(source, &deck, &rec, c, &stem, &drawn));
    }
    for s in 0..rec.syms.stem.len() {
        if rec.syms.origin[s] == recognize::Origin::Leaf {
            out.files.push(emit::leaf_file(source, &rec, s));
        }
    }
    assert!(out.stats.nets_wired <= out.stats.nets_multi);
    assert_eq!(
        out.stats.cells as usize,
        out.files.iter().filter(|f| !f.shared).count()
    );
    out
}
