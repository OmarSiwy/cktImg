//! Oracles for the cktimg plugin (TESTING.md style), native only:
//!
//! 1. **Connectivity round trip.** netlist → cktimg → Schemify files → `doc` + `elab` +
//!    the netlister (`schemify_run::prepare`) → SPICE, compared with the input under
//!    `tools/spicecmp`. Subckts are made comparable by *probes*: every generated component
//!    is instantiated once in the oracle bench and the input gets the same `X` lines, so
//!    unused subckts are netlisted on both sides and port order is checked.
//! 2. **Files.** Every output loads in `doc` with zero errors and round-trips
//!    (`interop::check_output`); no two wires overlap collinearly; every
//!    instance pin sits on a wire or a label/port; same input → same bytes.
//! 3. **Robustness.** Mutated netlists never panic (proptest).
//!
//! Layout metrics (wire crossings, total wire length, routed vs labelled nets, bounding
//! box) are printed per case; they are reported, not gating.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use proptest::prelude::*;
use schemify_doc::Project;
use schemify_elab::{Dialect, no_funcs};
use schemify_format::{Document, FileKind, IdRng, RecordKind, fresh_id, parse, parse_coord, write};
use schemify_run::{Jobs, NO_SAMPLE, Plan, Results, design, prepare};
use schemify_spicecmp::Section;

const MANIFEST: &str = "schemify 1 project\n\nlib n2s path n2s\n";

/// A netlist to convert: display name and text.
struct Case {
    name: String,
    text: String,
}

fn fixture_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

/// The salvaged fixtures (`<category>/<name>.sp`) and the hand-written ones.
fn fixtures() -> Vec<Case> {
    let mut out = Vec::new();
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(fixture_dir())
        .expect("fixture dir")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_dir())
        .collect();
    dirs.sort();
    for d in dirs {
        let mut files: Vec<PathBuf> = std::fs::read_dir(&d)
            .expect("category dir")
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "sp"))
            .collect();
        files.sort();
        for f in files {
            let name = format!(
                "{}/{}",
                d.file_name().unwrap().to_string_lossy(),
                f.file_stem().unwrap().to_string_lossy()
            );
            out.push(Case {
                name,
                text: std::fs::read_to_string(&f).expect("fixture text"),
            });
        }
    }
    assert!(out.len() >= 80, "{} fixtures", out.len());
    out
}

/// Golden netlists produced by running xschem (`tests/corpus/golden.sh`), used as input
/// only. `None` when the corpus cache is not fetched. `SCHEMIFY_CORPUS` points at another
/// checkout's `tests/corpus/.cache` (worktrees share one).
fn corpus(filter: impl Fn(&str) -> bool) -> Option<Vec<Case>> {
    let cache = std::env::var_os("SCHEMIFY_CORPUS").map_or_else(
        || Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/corpus/.cache"),
        PathBuf::from,
    );
    let dir = cache.join("golden");
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .ok()?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".spice") && filter(n))
        .collect();
    names.sort();
    Some(
        names
            .into_iter()
            .map(|n| Case {
                text: std::fs::read_to_string(dir.join(&n)).expect("golden"),
                name: format!("corpus/{}", n.trim_end_matches(".spice")),
            })
            .collect(),
    )
}

/// A few corpus netlists of every group, for the gating test.
const CORPUS_SAMPLE: &[&str] = &[
    "xs-ex-real_capa",
    "xs-ex-pump",
    "xs-logic-bf",
    "sky130-tb_bandgap",
    "gf180-test_nfet_03v3",
    "gf180-test_npn_00p54x02p00",
    "gf180-test_diode_dw2ps",
    "ihp-dc_lv_nmos",
    "ihp-dc_hbt_13g2",
    "ihp-inv_sweep_tb",
];

/// Annotated expected differences: (case, the only spicecmp section allowed to differ,
/// why). Connectivity must agree for every case.
const XFAIL: &[(&str, Section, &str)] = &[
    (
        "corpus/xs-ex-doublepin",
        Section::Directives,
        "`.subckt latch … delay=200 ps`: spicecmp keeps the stray token as a directive, the plugin drops it with a warning",
    ),
    (
        "corpus/xs-ex-test_doublepin",
        Section::Directives,
        "`.subckt latch … delay=200 ps`: spicecmp keeps the stray token as a directive, the plugin drops it with a warning",
    ),
    (
        "corpus/xs-ex-loading",
        Section::Directives,
        "`.subckt switch_rreal … del=2 ns`: spicecmp keeps the stray token as a directive, the plugin drops it with a warning",
    ),
    (
        "corpus/xs-logic-testbench",
        Section::Directives,
        "`.subckt latch … delay=200 ps`: spicecmp keeps the stray token as a directive, the plugin drops it with a warning",
    ),
    (
        "hand/default_after_override",
        Section::Connectivity,
        "spicecmp evaluates subckt defaults before the call's overrides; ngspice 45 (checked: \
         v(n1) = 10) and Schemify elab evaluate them after, so the generated netlist is right",
    ),
];

/// Outcome of one case.
#[derive(Default)]
struct Outcome {
    /// spicecmp agrees.
    agree: bool,
    /// Sections that differ.
    sections: Vec<Section>,
    /// Why not (first lines).
    why: String,
    /// File-oracle problems.
    problems: Vec<String>,
    metrics: Metrics,
}

#[derive(Default, Clone, Copy)]
struct Metrics {
    crossings: u32,
    length: i64,
    nets_multi: u32,
    nets_wired: u32,
    area: i64,
    wires: u32,
    markers: u32,
}

fn source_of(case: &Case) -> String {
    format!("n2s/{}.sp", case.name.rsplit('/').next().unwrap())
}

/// Runs every oracle on `case`.
fn run(case: &Case) -> Outcome {
    let source = source_of(case);
    let conv = cktimg::convert(&source, &case.text);
    let again = cktimg::convert(&source, &case.text);
    let mut out = Outcome::default();
    if conv.files != again.files {
        out.problems
            .push("output bytes differ between two runs".into());
    }
    let files: Vec<(String, Vec<u8>)> =
        std::iter::once(("schemify.project".to_owned(), MANIFEST.as_bytes().to_vec()))
            .chain(
                conv.files
                    .iter()
                    .map(|f| (format!("n2s/{}", f.name), f.bytes.clone())),
            )
            .collect();
    out.problems.extend(interop::check_output(&files));
    let geo = geometry(&conv.files);
    out.problems.extend(geo.1);
    out.metrics = geo.0;
    out.metrics.nets_multi = conv.stats.nets_multi;
    out.metrics.nets_wired = conv.stats.nets_wired;
    out.metrics.wires = conv.stats.wires;
    out.metrics.markers = conv.stats.markers;

    // Probes: one instance per generated component, in deck order.
    let deck = cktimg::spice::parse(&case.text);
    let comps: Vec<&cktimg::OutFile> = conv
        .files
        .iter()
        .filter(|f| f.name.ends_with(".shcomp"))
        .collect();
    assert_eq!(comps.len(), deck.cells() - 1);
    let mut probe_text = String::from("* cktimg probes\n");
    let bench_name = conv
        .files
        .iter()
        .find(|f| f.name.ends_with(".shbench"))
        .map(|f| f.name.clone());
    let mut bench = match &bench_name {
        Some(n) => {
            let b = &conv.files.iter().find(|f| &f.name == n).unwrap().bytes;
            let d = parse(b).expect("bench parses");
            let mut nd = Document::new(FileKind::Shbench);
            for r in 1..d.record_count() {
                nd.copy_record(&d, r);
            }
            nd
        }
        None => Document::new(FileKind::Shbench),
    };
    let mut taken: Vec<String> = Vec::new();
    let mut ordinal = 0u32;
    let mut id = || {
        ordinal += 1;
        let i = fresh_id(&mut IdRng::new(u64::from(ordinal) << 20 | 7), |s| {
            taken.iter().any(|t| t == s)
        });
        taken.push(i.as_str().to_owned());
        i.as_str().to_owned()
    };
    let mut py = 0i32;
    for (k, comp) in comps.iter().enumerate() {
        let c = k + 1;
        let d = parse(&comp.bytes).expect("component parses");
        let stem = comp.name.trim_end_matches(".shcomp");
        let px = -50_000;
        let pins = (1..d.record_count())
            .filter(|&r| d.record_kind(r) == RecordKind::Pin)
            .count() as i32;
        py += 10 * pins + 200; // half of this box below the previous one
        bench.begin_record(RecordKind::Inst);
        bench.push_field(&id());
        bench.push_field(&format!("./{stem}"));
        bench.push_attr("at");
        bench.push_value_coord(px * 1000);
        bench.push_value_coord(py * 1000);
        bench.push_value("R0");
        bench.push_attr("name");
        bench.push_value(&format!("n2s_probe{k}"));
        let mut nodes = Vec::new();
        for r in 1..d.record_count() {
            if d.record_kind(r) != RecordKind::Pin {
                continue;
            }
            let net = format!("n2s_probe{k}_{}", nodes.len());
            let x = parse_coord(d.field(r, 2).unwrap()).unwrap() / 1000;
            let y = parse_coord(d.field(r, 3).unwrap()).unwrap() / 1000;
            bench.begin_record(RecordKind::Label);
            bench.push_field(&id());
            bench.push_field_coord((px + x) * 1000);
            bench.push_field_coord((py + y) * 1000);
            bench.push_field("R0");
            bench.push_field(&net);
            nodes.push(net);
        }
        probe_text.push_str(&format!(
            "Xn2s_probe{k} {} {}\n",
            nodes.join(" "),
            deck.cell_name[c]
        ));
        py += 10 * pins + 200; // the other half, so the next box starts below this one
    }
    let bench_bytes = write(&bench).into_bytes();
    let input = format!("{probe_text}{}", case.text);
    match netlist(&conv.files, &bench_bytes) {
        Ok(ours) => {
            let report =
                schemify_spicecmp::compare(&input, &ours, &schemify_spicecmp::Options::default());
            let diffs = unspecialized(report.diffs, &ours);
            out.agree = diffs.is_empty();
            out.sections = diffs.iter().map(|d| d.section).collect();
            out.sections.dedup();
            if !out.agree {
                let lines: Vec<String> = diffs
                    .iter()
                    .take(8)
                    .map(|d| format!("{:?} {}", d.section, d.text))
                    .collect();
                out.why = format!(
                    "{}\n--- ours ---\n{}",
                    lines.join("\n"),
                    ours.lines().take(60).collect::<Vec<_>>().join("\n")
                );
            }
        }
        Err(e) => out.why = e,
    }
    out
}

/// Cancels directive differences that only reflect subckt specialization (netlist spec
/// §6): spicecmp keys a subckt's directives by subckt name, and the netlister emits one
/// copy of a cell per parameter tuple (`cell__h`, h = 6 id digits), each with the cell's
/// own text. A `+ cell__h: t` cancels against a `- cell: t`, or drops when `ours` emits
/// the base `cell` too (whose copy of `t` then matched the input).
fn unspecialized(diffs: Vec<schemify_spicecmp::Diff>, ours: &str) -> Vec<schemify_spicecmp::Diff> {
    let base = |t: &str| -> Option<(String, String)> {
        let (scope, rest) = t.strip_prefix("+ ")?.split_once(": ")?;
        let (cell, h) = scope.rsplit_once("__")?;
        let digits = h.len() == 6 && h.bytes().all(|b| schemify_format::ID_ALPHABET.contains(&b));
        digits.then(|| (cell.to_owned(), format!("{cell}: {rest}")))
    };
    let emits = |cell: &str| {
        ours.lines().any(|l| {
            let mut w = l.split_whitespace();
            w.next().is_some_and(|x| x.eq_ignore_ascii_case(".subckt"))
                && w.next().is_some_and(|n| n.eq_ignore_ascii_case(cell))
        })
    };
    let mut keep = vec![true; diffs.len()];
    for i in 0..diffs.len() {
        if diffs[i].section != Section::Directives {
            continue;
        }
        let Some((cell, b)) = base(&diffs[i].text) else {
            continue;
        };
        let minus = (0..diffs.len()).find(|&j| {
            keep[j]
                && diffs[j].section == Section::Directives
                && diffs[j].text.strip_prefix("- ") == Some(b.as_str())
        });
        match minus {
            Some(j) => {
                keep[i] = false;
                keep[j] = false;
            }
            None if emits(&cell) => keep[i] = false,
            None => {}
        }
    }
    diffs
        .into_iter()
        .zip(keep)
        .filter_map(|(d, k)| k.then_some(d))
        .collect()
}

/// Netlists the oracle bench `bench` over the generated `files` (ngspice dialect).
fn netlist(files: &[cktimg::OutFile], bench: &[u8]) -> Result<String, String> {
    let mut p = Project::new(Some(MANIFEST.as_bytes()), None, 1).map_err(|e| format!("{e:?}"))?;
    let core = schemify_doc::core_library();
    p.index_library("core", "test", core)
        .map_err(|e| format!("{e:?}"))?;
    let mut listing: Vec<(&str, &[u8])> = files
        .iter()
        .filter(|f| !f.name.ends_with(".shbench"))
        .map(|f| (f.name.as_str(), f.bytes.as_slice()))
        .collect();
    listing.push(("__oracle.shbench", bench));
    p.index_library("n2s", "test", &listing)
        .map_err(|e| format!("{e:?}"))?;
    for (name, bytes) in core {
        p.open("core", name, bytes, None)
            .map_err(|e| format!("core {name}: {e:?}"))?;
    }
    let mut top = None;
    for (name, bytes) in &listing {
        let o = p
            .open("n2s", name, bytes, None)
            .map_err(|e| format!("{name}: {e:?}"))?;
        if name.ends_with(".shbench") {
            top = Some(o.handle);
        }
    }
    let top = top.expect("oracle bench");
    let plan = Plan::read(p.doc(top).unwrap()).map_err(|e| format!("plan: {e:?}"))?;
    let mut jobs = Jobs::new();
    jobs.push(None, None, NO_SAMPLE, &[])
        .map_err(|e| format!("{e:?}"))?;
    let digest = design(&p, top, &jobs, &[], Dialect::Ngspice, &mut no_funcs)
        .map_err(|e| format!("blocked: {e:?}"))?;
    let mut results = Results::new(&plan, digest);
    match prepare(
        &p,
        top,
        &mut jobs,
        0,
        &[],
        Dialect::Ngspice,
        &mut no_funcs,
        &mut results,
    ) {
        Some(prep) => Ok(prep.netlist),
        None => Err(format!(
            "not netlisted: {:?}",
            results.errors().map(|e| e.2.to_owned()).collect::<Vec<_>>()
        )),
    }
}

/// Pin offsets of every cell the outputs use (core and generated), by cell reference.
fn pin_table(files: &[cktimg::OutFile]) -> BTreeMap<String, Vec<(i32, i32)>> {
    let mut t = BTreeMap::new();
    let core = schemify_doc::core_library().iter().map(|(n, b)| {
        (
            format!("core:{}", n.rsplit_once('.').unwrap().0),
            b.to_vec(),
        )
    });
    let ours = files
        .iter()
        .filter(|f| !f.name.ends_with(".shbench"))
        .map(|f| {
            (
                format!("./{}", f.name.rsplit_once('.').unwrap().0),
                f.bytes.clone(),
            )
        });
    for (cellref, bytes) in core.chain(ours) {
        let d = parse(&bytes).expect("cell parses");
        let pins = (1..d.record_count())
            .filter(|&r| d.record_kind(r) == RecordKind::Pin)
            .map(|r| {
                (
                    parse_coord(d.field(r, 2).unwrap()).unwrap(),
                    parse_coord(d.field(r, 3).unwrap()).unwrap(),
                )
            })
            .collect();
        t.insert(cellref, pins);
    }
    t
}

/// Maps a symbol-local point through an orientation word (format spec §3).
fn orient(o: &str, x: i32, y: i32) -> (i32, i32) {
    let (m, r) = match o.strip_prefix('M') {
        Some(rest) => (true, rest),
        None => (false, o),
    };
    let x = if m { -x } else { x };
    match r {
        "R0" => (x, y),
        "R90" => (-y, x),
        "R180" => (-x, -y),
        _ => (y, -x),
    }
}

/// Geometry oracles and layout metrics over every cell file (milli-units internally).
fn geometry(files: &[cktimg::OutFile]) -> (Metrics, Vec<String>) {
    let pins = pin_table(files);
    let mut m = Metrics::default();
    let mut problems = Vec::new();
    for f in files.iter().filter(|f| !f.shared) {
        let d = parse(&f.bytes).expect("cell parses");
        let c = |r: u32, i: usize| parse_coord(d.field(r, i).unwrap()).unwrap();
        let mut wires: Vec<[i32; 4]> = Vec::new();
        let mut marks: Vec<(i32, i32)> = Vec::new();
        let mut pin_pts: Vec<((i32, i32), String)> = Vec::new();
        for r in 1..d.record_count() {
            match d.record_kind(r) {
                RecordKind::Wire => wires.push([c(r, 1), c(r, 2), c(r, 3), c(r, 4)]),
                RecordKind::Label | RecordKind::Port | RecordKind::Noconn => {
                    marks.push((c(r, 1), c(r, 2)))
                }
                RecordKind::Inst => {
                    let at = d.find_attr(r, "at").unwrap();
                    let x = parse_coord(d.attr_value(at, 0).unwrap()).unwrap();
                    let y = parse_coord(d.attr_value(at, 1).unwrap()).unwrap();
                    let o = d.attr_value(at, 2).unwrap();
                    let name = d
                        .find_attr(r, "name")
                        .and_then(|a| d.attr_value(a, 0))
                        .unwrap_or("?");
                    for (k, &(px, py)) in pins[d.field(r, 1).unwrap()].iter().enumerate() {
                        let (dx, dy) = orient(o, px, py);
                        pin_pts.push(((x + dx, y + dy), format!("{name}.{k}")));
                    }
                }
                _ => {}
            }
        }
        let on = |p: (i32, i32), w: &[i32; 4]| {
            p.0 >= w[0].min(w[2])
                && p.0 <= w[0].max(w[2])
                && p.1 >= w[1].min(w[3])
                && p.1 <= w[1].max(w[3])
        };
        for (p, who) in &pin_pts {
            if !wires.iter().any(|w| on(*p, w)) && !marks.contains(p) {
                problems.push(format!(
                    "{}: pin {who} at {p:?} neither wired nor labelled",
                    f.name
                ));
            }
        }
        for (i, a) in wires.iter().enumerate() {
            for b in &wires[i + 1..] {
                let (ah, bh) = (a[1] == a[3], b[1] == b[3]);
                if ah == bh {
                    let same_line = if ah { a[1] == b[1] } else { a[0] == b[0] };
                    let (alo, ahi, blo, bhi) = if ah {
                        (a[0], a[2], b[0], b[2])
                    } else {
                        (a[1], a[3], b[1], b[3])
                    };
                    if same_line && alo.max(blo) < ahi.min(bhi) {
                        problems.push(format!("{}: wires {a:?} and {b:?} overlap", f.name));
                    }
                } else {
                    let (h, v) = if ah { (a, b) } else { (b, a) };
                    if v[0] > h[0] && v[0] < h[2] && h[1] > v[1] && h[1] < v[3] {
                        m.crossings += 1;
                    }
                }
            }
            m.length += i64::from((a[2] - a[0]) + (a[3] - a[1])) / 1000;
        }
        let pts = pin_pts
            .iter()
            .map(|p| p.0)
            .chain(marks.iter().copied())
            .chain(wires.iter().flat_map(|w| [(w[0], w[1]), (w[2], w[3])]));
        let (mut x0, mut y0, mut x1, mut y1) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
        for (x, y) in pts {
            (x0, y0, x1, y1) = (x0.min(x), y0.min(y), x1.max(x), y1.max(y));
        }
        if x0 <= x1 {
            m.area += i64::from((x1 - x0) / 1000) * i64::from((y1 - y0) / 1000);
        }
    }
    (m, problems)
}

/// Runs `cases`, prints the agreement table and metrics, returns the failures.
fn table(cases: &[Case]) -> Vec<String> {
    let mut failures = Vec::new();
    let (mut agree, mut clean, mut xfails) = (0, 0, 0);
    let mut total = Metrics::default();
    eprintln!(
        "{:<44} {:>5} {:>5} {:>6} {:>7} {:>9} {:>9}",
        "case", "cmp", "files", "cross", "length", "routed", "bbox"
    );
    for case in cases {
        let o = std::panic::catch_unwind(|| run(case)).unwrap_or_else(|_| Outcome {
            why: "panicked".into(),
            ..Outcome::default()
        });
        let m = o.metrics;
        let xfail = XFAIL.iter().find(|x| x.0 == case.name);
        let expected = !o.agree
            && !o.sections.is_empty()
            && xfail.is_some_and(|x| o.sections.iter().all(|s| *s == x.1));
        eprintln!(
            "{:<44} {:>5} {:>5} {:>6} {:>7} {:>4}/{:<4} {:>9}",
            case.name,
            if o.agree {
                "ok"
            } else if expected {
                "xfail"
            } else {
                "DIFF"
            },
            if o.problems.is_empty() { "ok" } else { "BAD" },
            m.crossings,
            m.length,
            m.nets_wired,
            m.nets_multi,
            m.area
        );
        agree += usize::from(o.agree);
        xfails += usize::from(expected);
        clean += usize::from(o.problems.is_empty());
        total.crossings += m.crossings;
        total.length += m.length;
        total.nets_wired += m.nets_wired;
        total.nets_multi += m.nets_multi;
        total.area += m.area;
        if let (true, Some(x)) = (expected, xfail) {
            eprintln!("  xfail ({:?} only): {}", x.1, x.2);
        } else if !o.agree {
            failures.push(format!("{}: spicecmp: {}", case.name, o.why));
        }
        for p in o.problems.iter().take(5) {
            eprintln!("  problem: {p}");
            failures.push(format!("{}: {p}", case.name));
        }
    }
    eprintln!(
        "agree {agree}/{n} (+{xfails} annotated xfail), files clean {clean}/{n}; crossings {}, wire length {}, nets wired {}/{} ({:.0}%), bbox area {}",
        total.crossings,
        total.length,
        total.nets_wired,
        total.nets_multi,
        100.0 * f64::from(total.nets_wired) / f64::from(total.nets_multi.max(1)),
        total.area,
        n = cases.len()
    );
    failures
}

#[test]
fn fixtures_round_trip_connectivity_equivalent() {
    let failures = table(&fixtures());
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

#[test]
fn corpus_sample_round_trips_connectivity_equivalent() {
    let Some(cases) = corpus(|n| CORPUS_SAMPLE.iter().any(|s| n == format!("{s}.spice"))) else {
        eprintln!("corpus cache not fetched; skipped");
        return;
    };
    assert_eq!(cases.len(), CORPUS_SAMPLE.len(), "sample names exist");
    let failures = table(&cases);
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

/// The whole golden corpus, for the agreement count (`--ignored --nocapture`);
/// `SCHEMIFY_CORPUS_FILTER=<substring>` narrows it to matching netlist names.
#[test]
#[ignore = "slow: every corpus netlist; run for the report"]
fn corpus_all_report() {
    let only = std::env::var("SCHEMIFY_CORPUS_FILTER").unwrap_or_default();
    let Some(cases) = corpus(|n| n.contains(&only)) else {
        return;
    };
    let failures = table(&cases);
    for f in failures.iter().filter(|f| f.contains("spicecmp")).take(40) {
        eprintln!("{}", f.lines().take(4).collect::<Vec<_>>().join(" | "));
    }
}

/// The pin tables the plugin places core cells with match `lib/core`.
#[test]
fn core_pin_tables_match_the_bundled_library() {
    let lib = pin_table(&[]);
    for (cell, pins) in cktimg::recognize::core_table() {
        let want: Vec<(i32, i32)> = pins.iter().map(|p| (p.1 * 1000, p.2 * 1000)).collect();
        assert_eq!(lib[&format!("core:{cell}")], want, "{cell}");
        let bytes = schemify_doc::core_library()
            .iter()
            .find(|f| f.0 == format!("{cell}.shprim"))
            .unwrap()
            .1;
        let d = parse(bytes).unwrap();
        let names: Vec<&str> = (1..d.record_count())
            .filter(|&r| d.record_kind(r) == RecordKind::Pin)
            .map(|r| d.field(r, 0).unwrap())
            .collect();
        assert_eq!(
            names,
            pins.iter().map(|p| p.0).collect::<Vec<_>>(),
            "{cell}"
        );
    }
}

/// Mutations of a fixture: deleted, duplicated and spliced lines, flipped bytes.
fn mutated() -> impl Strategy<Value = String> {
    let texts: Vec<String> = fixtures().into_iter().map(|c| c.text).collect();
    (
        0..texts.len(),
        proptest::collection::vec((0usize..400, 0u8..5, any::<u8>()), 1..12),
    )
        .prop_map(move |(i, edits)| {
            let mut lines: Vec<String> = texts[i].lines().map(str::to_owned).collect();
            for (at, op, byte) in edits {
                if lines.is_empty() {
                    lines.push(String::new());
                }
                let k = at % lines.len();
                match op {
                    0 => {
                        lines.remove(k);
                    }
                    1 => lines.insert(k, lines[k].clone()),
                    2 => {
                        let s = &mut lines[k];
                        let pos = usize::from(byte) % (s.len() + 1);
                        let ch = b"+.{}'= x0*"[usize::from(byte) % 10] as char;
                        if s.is_char_boundary(pos) {
                            s.insert(pos, ch);
                        }
                    }
                    3 => lines.insert(
                        k,
                        [
                            ".subckt s a b",
                            ".ends",
                            ".control",
                            "+ cont",
                            "X1 a s",
                            ".global a",
                        ][usize::from(byte) % 6]
                            .to_owned(),
                    ),
                    _ => {
                        let t: Vec<&str> = lines[k].split_whitespace().collect();
                        lines[k] = t.iter().rev().copied().collect::<Vec<_>>().join(" ");
                    }
                }
            }
            lines.join("\n")
        })
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn mutated_netlists_never_panic_and_load(text in mutated()) {
        let conv = cktimg::convert("n2s/mutant.sp", &text);
        let files: Vec<(String, Vec<u8>)> = std::iter::once(("schemify.project".to_owned(), MANIFEST.as_bytes().to_vec()))
            .chain(conv.files.iter().map(|f| (format!("n2s/{}", f.name), f.bytes.clone())))
            .collect();
        let problems = interop::check_output(&files);
        prop_assert!(problems.is_empty(), "{problems:?}");
    }
}
