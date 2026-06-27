//! E2E: SPICE fixture → place → xschem .sch → xschem netlist → re-parse → topology check.
//!
//! Requires xschem on PATH. Roundtrip tests are `#[ignore]` by default; run with:
//!   cargo test -p e2e -- --ignored
//! or get xschem via:
//!   cd tests/e2e/xschembackend && nix develop

use devices::class_at;
use ir::ids::DeviceIdx;
use std::path::{Path, PathBuf};
use std::process::Command;

const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../fixtures");

// ---------------------------------------------------------------------------
// Connectivity fingerprint (name-independent)
// ---------------------------------------------------------------------------

/// Per-device signature: (class_index, per-pin sorted neighbor list).
/// Neighbors are (class_index, pin_slot) of every OTHER real-device pin on the same net.
type DeviceSig = (usize, Vec<Vec<(usize, usize)>>);

/// Name-independent connectivity fingerprint of the real (non-rail) devices.
/// Two circuits have equivalent connectivity iff their sorted fingerprints are equal.
// ponytail: single-round Weisfeiler-Leman; iterative refinement if symmetric false-positive ever appears.
fn connectivity(ir: &ir::Ir) -> Vec<DeviceSig> {
    let is_real = |d: usize| class_at(ir.devices.symbol[d].index()).prefix != ' ';

    let mut net_pins: Vec<Vec<(usize, usize)>> = vec![vec![]; ir.nets.len()];
    for d in 0..ir.devices.len() {
        if !is_real(d) {
            continue;
        }
        for (slot, pi) in ir.devices.pin_range(DeviceIdx(d as u32)).enumerate() {
            if let Some(net) = ir.pins.net[pi] {
                net_pins[net.index()].push((d, slot));
            }
        }
    }

    let mut sigs: Vec<DeviceSig> = (0..ir.devices.len())
        .filter(|&d| is_real(d))
        .map(|d| {
            let class = ir.devices.symbol[d].index();
            let pins: Vec<Vec<(usize, usize)>> = ir
                .devices
                .pin_range(DeviceIdx(d as u32))
                .enumerate()
                .map(|(slot, pi)| {
                    let mut neighbors: Vec<(usize, usize)> = match ir.pins.net[pi] {
                        Some(net) => net_pins[net.index()]
                            .iter()
                            .filter(|&&(od, os)| od != d || os != slot)
                            .map(|&(od, os)| (ir.devices.symbol[od].index(), os))
                            .collect(),
                        None => vec![],
                    };
                    neighbors.sort();
                    neighbors
                })
                .collect();
            (class, pins)
        })
        .collect();

    sigs.sort();
    sigs
}

// ---------------------------------------------------------------------------
// Named connectivity (strict: device names + net names must match)
// ---------------------------------------------------------------------------

type NamedDeviceSig = (usize, String, Vec<(usize, Option<String>)>);

fn named_connectivity(ir: &ir::Ir, strings: &ir::Strings) -> Vec<NamedDeviceSig> {
    let is_real = |d: usize| class_at(ir.devices.symbol[d].index()).prefix != ' ';

    let mut sigs: Vec<NamedDeviceSig> = (0..ir.devices.len())
        .filter(|&d| is_real(d))
        .map(|d| {
            let class = ir.devices.symbol[d].index();
            let name = strings.get(ir.devices.name[d]).to_string();
            let pins: Vec<(usize, Option<String>)> = ir
                .devices
                .pin_range(DeviceIdx(d as u32))
                .enumerate()
                .map(|(slot, pi)| {
                    let net =
                        ir.pins.net[pi].map(|n| strings.get(ir.nets.name[n.index()]).to_string());
                    (slot, net)
                })
                .collect();
            (class, name, pins)
        })
        .collect();

    sigs.sort();
    sigs
}

/// Count real (non-rail/port) devices in an IR.
fn real_device_count(ir: &ir::Ir) -> usize {
    (0..ir.devices.len())
        .filter(|&d| class_at(ir.devices.symbol[d].index()).prefix != ' ')
        .count()
}

// ---------------------------------------------------------------------------
// xschem helpers
// ---------------------------------------------------------------------------

fn xschem_bin() -> Option<PathBuf> {
    which::which("xschem").ok()
}

/// Derive the xschem devices/ symbol directory from the binary location.
/// Layout: <prefix>/bin/xschem → <prefix>/share/xschem/xschem_library/devices
fn xschem_devices_dir() -> Option<PathBuf> {
    let bin = xschem_bin()?;
    let prefix = bin.parent()?.parent()?;
    let devices = prefix.join("share/xschem/xschem_library/devices");
    devices.is_dir().then_some(devices)
}

/// Rewrite portable `{devices/foo.sym}` refs to absolute paths so batch-mode xschem finds them.
fn resolve_symbols(sch: &str, devices_dir: &Path) -> String {
    sch.replace("{devices/", &format!("{{{}/", devices_dir.display()))
}

/// Parse a .spice fixture, place, render to xschem .sch.
fn fixture(path: &Path) -> (ir::Ir, ir::Strings, String) {
    let mut interner = ir::Interner::default();
    let (sch, report) = netlist::parse_path(path, &mut interner).expect("read fixture");
    assert!(
        report.is_clean(),
        "{}: fixture has skipped lines:\n{}",
        path.display(),
        report.summary()
    );

    let placed = build::layout(sch);
    let doc = xschembackend::render(placed.ir(), interner.pool());
    assert!(doc.starts_with("v {xschem"), "missing xschem header");

    let mut interner2 = ir::Interner::default();
    let (sch2, _) = netlist::parse_path(path, &mut interner2).expect("re-parse");
    (sch2.into_ir(), interner2.finish(), doc)
}

fn xschem_netlist(sch_doc: &str, stem: &str) -> (ir::Ir, ir::Strings) {
    let devices_dir = xschem_devices_dir().expect("cannot find xschem devices/ directory");
    let resolved = resolve_symbols(sch_doc, &devices_dir);

    let dir = tempfile::tempdir().expect("tmpdir");
    let sch_path = dir.path().join(format!("{stem}.sch"));
    std::fs::write(&sch_path, &resolved).expect("write .sch");

    let output = Command::new("xschem")
        .args(["--netlist", "--quit", "--no_x"])
        .arg(&sch_path)
        .arg("--tcl")
        .arg(format!("set netlist_dir {}", dir.path().display()))
        .output()
        .expect("run xschem");

    // xschem batch mode exits 10 on success (not 0)
    assert!(
        matches!(output.status.code(), Some(0) | Some(10)),
        "xschem failed (exit {:?}): {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stderr)
    );

    let spice_out = dir.path().join(format!("{stem}.spice"));
    assert!(
        spice_out.exists(),
        "xschem produced no netlist at {}",
        spice_out.display()
    );

    let mut interner = ir::Interner::default();
    let (sch, _) = netlist::parse_path(&spice_out, &mut interner).expect("re-parse xschem output");
    (sch.into_ir(), interner.finish())
}

/// Collect all .spice files in the fixtures directory, sorted for determinism.
fn all_fixtures() -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(FIXTURES)
        .expect("read fixtures dir")
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|ext| ext == "spice"))
        .collect();
    files.sort();
    files
}

// ---------------------------------------------------------------------------
// Generic: render sanity (no xschem needed)
// ---------------------------------------------------------------------------

#[test]
fn all_fixtures_render() {
    let files = all_fixtures();
    assert!(!files.is_empty(), "no .spice fixtures found");

    for path in &files {
        let stem = path.file_stem().unwrap().to_str().unwrap();
        let (ir, _, doc) = fixture(path);
        let n = real_device_count(&ir);
        assert!(n > 0, "{stem}: no real devices parsed");
        assert!(
            doc.contains("C {devices/"),
            "{stem}: .sch has no component lines"
        );
        assert!(
            doc.contains("lab_pin.sym"),
            "{stem}: .sch has no pin labels"
        );
        eprintln!("  render ok: {stem} ({n} devices)");
    }
}

// ---------------------------------------------------------------------------
// Generic: connectivity self-check (no xschem needed)
// ---------------------------------------------------------------------------

#[test]
fn all_fixtures_connectivity_deterministic() {
    for path in &all_fixtures() {
        let stem = path.file_stem().unwrap().to_str().unwrap();
        let (ir1, _, _) = fixture(path);
        let (ir2, _, _) = fixture(path);
        let c1 = connectivity(&ir1);
        let c2 = connectivity(&ir2);
        assert!(!c1.is_empty(), "{stem}: empty connectivity");
        assert!(
            c1.iter().any(|(_, pins)| pins.iter().any(|n| !n.is_empty())),
            "{stem}: no connections at all"
        );
        assert_eq!(c1, c2, "{stem}: connectivity not deterministic");
    }
}

// ---------------------------------------------------------------------------
// Generic round-trip: connectivity only (needs xschem)
// ---------------------------------------------------------------------------

#[test]
#[ignore]
fn all_fixtures_roundtrip_connectivity() {
    let files = all_fixtures();
    assert!(!files.is_empty(), "no .spice fixtures found");

    for path in &files {
        let stem = path.file_stem().unwrap().to_str().unwrap();
        let (ir_orig, _, doc) = fixture(path);
        let (ir_rt, _) = xschem_netlist(&doc, stem);

        let n = real_device_count(&ir_orig);
        let c_orig = connectivity(&ir_orig);
        let c_rt = connectivity(&ir_rt);

        assert_eq!(c_orig.len(), n, "{stem}: orig fingerprint device count wrong");
        assert_eq!(c_rt.len(), n, "{stem}: roundtrip fingerprint device count wrong ({} != {n})", c_rt.len());
        assert!(
            c_orig.iter().any(|(_, pins)| pins.iter().any(|nb| !nb.is_empty())),
            "{stem}: orig has no connections"
        );
        assert!(
            c_rt.iter().any(|(_, pins)| pins.iter().any(|nb| !nb.is_empty())),
            "{stem}: roundtrip has no connections"
        );
        assert_eq!(c_orig, c_rt, "{stem}: connectivity mismatch after round-trip");
        eprintln!("  roundtrip connectivity ok: {stem} ({n} devices)");
    }
}

// ---------------------------------------------------------------------------
// Generic round-trip: strict names (needs xschem)
// ---------------------------------------------------------------------------

#[test]
#[ignore]
fn all_fixtures_roundtrip_named() {
    let files = all_fixtures();
    assert!(!files.is_empty(), "no .spice fixtures found");

    for path in &files {
        let stem = path.file_stem().unwrap().to_str().unwrap();
        let (ir_orig, strings_orig, doc) = fixture(path);
        let (ir_rt, strings_rt) = xschem_netlist(&doc, stem);

        let n = real_device_count(&ir_orig);
        let named_orig = named_connectivity(&ir_orig, &strings_orig);
        let named_rt = named_connectivity(&ir_rt, &strings_rt);

        assert_eq!(named_orig.len(), n, "{stem}: orig device count wrong");
        assert_eq!(named_rt.len(), n, "{stem}: roundtrip device count wrong ({} != {n})", named_rt.len());
        for (_, name, pins) in &named_orig {
            assert!(
                pins.iter().any(|(_, net)| net.is_some()),
                "{stem}: orig device {name} has no nets"
            );
        }
        for (_, name, pins) in &named_rt {
            assert!(
                pins.iter().any(|(_, net)| net.is_some()),
                "{stem}: roundtrip device {name} has no nets"
            );
        }
        assert_eq!(named_orig, named_rt, "{stem}: named connectivity mismatch");
        eprintln!("  roundtrip named ok: {stem} ({n} devices)");
    }
}
