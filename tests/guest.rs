//! The built guest (`plugins/cktimg/cktimg.wasm`, refreshed by `plugins/build.sh`)
//! end to end through the real host (`schemify_plugin`, wasmi) with the default fuel:
//! contributions compose without faults; the import command reads, probes and writes
//! through inverted I/O; the wasm output equals the native conversion byte for byte; an
//! existing cell is never overwritten. Skips when the module has not been built.

use std::path::Path;

use schemify_plugin::abi::{Code, Event, FUEL_DEFAULT, Kind, Level};
use schemify_plugin::{IoOp, PluginEvents, PluginId, Plugins, RequestQueues, Snapshots, deliver};

struct World {
    plugins: Plugins,
    events: PluginEvents,
    snap: Snapshots,
    queues: RequestQueues,
    id: PluginId,
}

impl World {
    fn new() -> Option<World> {
        World::with_fuel(FUEL_DEFAULT)
    }

    fn with_fuel(fuel: u64) -> Option<World> {
        let wasm = std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("cktimg.wasm")).ok()?;
        let mut plugins = Plugins::new();
        let id = plugins
            .load("cktimg", &wasm, &["read_project", "write_project"], fuel)
            .expect("loads");
        let mut w = World {
            plugins,
            events: PluginEvents::new(),
            snap: Snapshots::new(),
            queues: RequestQueues::default(),
            id,
        };
        w.frame();
        Some(w)
    }

    fn frame(&mut self) {
        deliver(
            &mut self.plugins,
            &self.events,
            &mut self.snap,
            &mut self.queues,
        );
        self.events.clear();
    }

    fn send(&mut self, ev: Event<'_>) {
        self.events.push(Some(self.id), &ev).expect("queued");
        self.frame();
    }

    /// Takes the queued I/O and log requests.
    fn take(&mut self) -> RequestQueues {
        std::mem::take(&mut self.queues)
    }

    fn faults(&self) -> Vec<String> {
        self.plugins
            .health()
            .faults()
            .iter()
            .map(|f| format!("{f:?}"))
            .collect()
    }
}

/// Files written: (path, bytes).
type Files = Vec<(String, Vec<u8>)>;
/// Logged lines.
type Logs = Vec<(Level, String)>;

/// Runs an import of `text` as `source`, answering every probe with `exists(path)`.
/// Returns the written files (path, bytes) and the logs.
fn import(w: &mut World, source: &str, text: &str, exists: impl Fn(&str) -> bool) -> (Files, Logs) {
    w.take();
    w.send(Event::Command {
        name: "cktimg.import",
        args: source,
    });
    let mut written = Vec::new();
    let mut logs = Vec::new();
    let mut q = w.take();
    for _ in 0..1000 {
        logs.extend(q.logs.iter().map(|l| (l.level, l.text.clone())));
        if q.io.is_empty() {
            break;
        }
        for r in &q.io {
            let path = r.args[0].clone();
            let (status, bytes): (i32, Vec<u8>) = match r.op {
                IoOp::FsRead if path == source => (0, text.as_bytes().to_vec()),
                IoOp::FsRead if exists(&path) => (0, b"schemify 1 shcomp\n".to_vec()),
                IoOp::FsRead => (Code::Gone.neg(), Vec::new()),
                IoOp::FsWrite => {
                    written.push((path, r.data.clone()));
                    (0, Vec::new())
                }
                op => panic!("unexpected {op:?}"),
            };
            w.events
                .push(
                    Some(w.id),
                    &Event::IoDone {
                        handle: r.handle,
                        status,
                        bytes: &bytes,
                    },
                )
                .expect("queued");
        }
        w.frame();
        q = w.take();
    }
    (written, logs)
}

#[test]
fn contributes_menu_command_and_key() {
    let Some(mut w) = World::new() else {
        eprintln!("cktimg.wasm not built (plugins/build.sh); skipped");
        return;
    };
    assert!(w.faults().is_empty(), "{:?}", w.faults());
    let c = w.plugins.composed();
    assert!(
        c.of(Kind::Ui)
            .iter()
            .any(|r| r.text.contains("parent menu.file") && r.text.contains("cktimg.import"))
    );
    assert!(
        c.of(Kind::Commands)
            .iter()
            .any(|r| r.text.contains("cktimg.import"))
    );
    assert!(
        c.of(Kind::Keymap)
            .iter()
            .any(|r| r.text.contains("Ctrl+Shift+I"))
    );
    // No argument: the path panel appears (and closes again).
    w.send(Event::Command {
        name: "cktimg.import",
        args: "",
    });
    assert!(
        w.plugins
            .composed()
            .of(Kind::Ui)
            .iter()
            .any(|r| r.text.contains("text_input"))
    );
    w.send(Event::Command {
        name: "cktimg.close",
        args: "",
    });
    assert!(
        !w.plugins
            .composed()
            .of(Kind::Ui)
            .iter()
            .any(|r| r.text.contains("text_input"))
    );
    assert!(w.faults().is_empty(), "{:?}", w.faults());
}

/// Fixtures whose cktImg layout needs more than the default fuel (10^8) under wasmi, with
/// the measured need (`fuel_report`, ReleaseSmall guest): the import aborts with `E_FUEL`,
/// writes nothing, and the plugin imports the next netlist as if it had not happened.
/// cktImg's layout rounds (`layout.place`, L6) dominate; see docs/upstream/README.md.
const OVER_BUDGET: &[(&str, &str)] = &[
    ("bus_sram_cell_array", "> 4·10^10"),
    ("bus_parallel_adder", "2.5·10^10"),
    ("bus_4bit_flash_adc", "1.3·10^10"),
    ("bus_shift_register", "2.1·10^9"),
    ("bus_current_dac", "1.6·10^9"),
    ("raw_cards", "1.0·10^9"),
    ("bus_data_bus_driver", "7.2·10^8"),
    ("bus_mux_4to1", "2.5·10^8"),
    ("bus_decoder_2to4", "1.7·10^8"),
    ("phase_detector", "1.6·10^8"),
    ("sr_latch", "1.1·10^8"),
];

#[test]
fn imports_every_fixture_like_the_native_build() {
    let Some(mut w) = World::new() else {
        eprintln!("cktimg.wasm not built (plugins/build.sh); skipped");
        return;
    };
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let mut cases: Vec<_> = std::fs::read_dir(&root)
        .unwrap()
        .flat_map(|d| std::fs::read_dir(d.unwrap().path()).into_iter().flatten())
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|x| x == "sp"))
        .collect();
    cases.sort();
    assert!(cases.len() >= 80);
    let mut over: Vec<String> = Vec::new();
    for path in cases {
        let text = std::fs::read_to_string(&path).unwrap();
        let stem = path.file_stem().unwrap().to_string_lossy().into_owned();
        let source = format!("n2s/{}", path.file_name().unwrap().to_string_lossy());
        let faults = w.faults().len();
        let (written, logs) = import(&mut w, &source, &text, |_| false);
        if w.faults().len() > faults {
            let fault = w.faults().last().cloned().unwrap_or_default();
            assert!(fault.contains("code: Fuel"), "{source}: {fault}");
            assert!(
                written.is_empty(),
                "{source}: an aborted import writes nothing"
            );
            over.push(stem);
            continue;
        }
        let native = cktimg::convert(&source, &text);
        let want: Vec<(String, Vec<u8>)> = native
            .files
            .iter()
            .map(|f| (format!("n2s/{}", f.name), f.bytes.clone()))
            .collect();
        assert_eq!(written, want, "{source}: wasm and native outputs differ");
        let summary = logs
            .iter()
            .find(|l| l.0 == Level::Info)
            .map(|l| l.1.as_str())
            .unwrap_or("");
        assert!(
            summary.starts_with(&format!("cktimg: {source} → {} files", want.len())),
            "{source}: {logs:?}"
        );
    }
    eprintln!("over the default fuel: {over:?}");
    for name in &over {
        assert!(
            OVER_BUDGET.iter().any(|o| o.0 == name),
            "{name} newly needs more than the default fuel"
        );
    }
    for (name, need) in OVER_BUDGET {
        if !over.iter().any(|o| o == name) {
            eprintln!(
                "note: {name} (measured {need}) now fits the default fuel; drop it from OVER_BUDGET"
            );
        }
    }
}

#[test]
fn refuses_to_overwrite_and_reports_missing_input() {
    let Some(mut w) = World::new() else {
        return;
    };
    let text = ".subckt inv a y\nM1 y a 0 0 nch w=1u l=1u\n.ends\nX1 in out inv\nV1 in 0 1\n";
    let (written, logs) = import(&mut w, "n2s/t.sp", text, |p| p == "n2s/inv.shprim");
    assert!(written.is_empty());
    assert!(
        logs.iter().any(|l| l.0 == Level::Error
            && l.1.contains("already exist")
            && l.1.contains("inv.shcomp")),
        "{logs:?}"
    );
    // A stub of an undefined subckt that already exists in the directory is kept.
    let text = "X1 in out dut\nV1 in 0 1\n";
    let (written, _) = import(&mut w, "n2s/u.sp", text, |p| p == "n2s/dut.shcomp");
    assert_eq!(
        written.iter().map(|f| f.0.as_str()).collect::<Vec<_>>(),
        ["n2s/u.shbench"]
    );
    // A netlist over the card limit is refused with a log before any work.
    let big: String = (0..300)
        .map(|i| format!("R{i} n{i} n{} 1k\n", i + 1))
        .collect();
    let (written, logs) = import(&mut w, "n2s/big.sp", &big, |_| false);
    assert!(written.is_empty());
    assert!(
        logs.iter()
            .any(|l| l.0 == Level::Error && l.1.contains("300 element cards")),
        "{logs:?}"
    );
    // A missing input file is an error log, not a fault.
    w.take();
    w.send(Event::Command {
        name: "cktimg.import",
        args: "n2s/missing.sp",
    });
    let q = w.take();
    let h = q.io[0].handle;
    w.send(Event::IoDone {
        handle: h,
        status: Code::Gone.neg(),
        bytes: b"",
    });
    assert!(
        w.take()
            .logs
            .iter()
            .any(|l| l.level == Level::Error && l.text.contains("cannot read n2s/missing.sp"))
    );
    assert!(w.faults().is_empty(), "{:?}", w.faults());
}

/// Fuel the conversion event of each named fixture needs (bisection), for the report.
#[test]
#[ignore = "slow; run for the fuel report"]
fn fuel_report() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let bisect = |fits: &dyn Fn(u64) -> bool| {
        let (mut lo, mut hi) = (1_000u64, 2_000_000_000u64);
        while hi - lo > hi / 50 {
            let mid = (lo + hi) / 2;
            if fits(mid) { hi = mid } else { lo = mid }
        }
        hi
    };
    let load_only = bisect(&|fuel| World::with_fuel(fuel).is_some_and(|w| w.faults().is_empty()));
    let panel = bisect(&|fuel| {
        let mut w = World::with_fuel(fuel).expect("built");
        w.send(Event::Command {
            name: "cktimg.import",
            args: "",
        });
        w.faults().is_empty()
    });
    let read_missing = bisect(&|fuel| {
        let mut w = World::with_fuel(fuel).expect("built");
        w.send(Event::Command {
            name: "cktimg.import",
            args: "n2s/a.sp",
        });
        let h = w.take().io.first().map_or(0, |r| r.handle);
        w.send(Event::IoDone {
            handle: h,
            status: Code::Gone.neg(),
            bytes: b"",
        });
        w.faults().is_empty()
    });
    eprintln!("load {load_only}, panel {panel}, read-missing {read_missing}");
    let chain: String = (0..200)
        .map(|i| format!("R{i} n{i} n{} 1k\n", i + 1))
        .collect();
    let cells: String = (0..8)
        .map(|c| {
            format!(
                ".subckt c{c} a b\n{}.ends\n",
                (0..24)
                    .map(|i| format!("M{i} n{i} a b n{} nch w=1u l=1u\n", i + 1))
                    .collect::<String>()
            )
        })
        .collect();
    let tiny = [
        ("tiny/one_r", "R1 a b 1k\n".to_owned()),
        ("tiny/empty", "* nothing\n.op\n".to_owned()),
        ("limit/chain_200", chain),
        ("limit/cells_8x24", cells),
    ];
    // Every fixture (`CKTIMG_FUEL_FILTER=<substring>` narrows them), largest first.
    let only = std::env::var("CKTIMG_FUEL_FILTER").unwrap_or_default();
    let mut named: Vec<(String, String)> = std::fs::read_dir(&root)
        .unwrap()
        .flat_map(|d| std::fs::read_dir(d.unwrap().path()).into_iter().flatten())
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|x| x == "sp") && p.to_string_lossy().contains(&only))
        .map(|p| {
            (
                p.file_stem().unwrap().to_string_lossy().into_owned(),
                std::fs::read_to_string(&p).unwrap(),
            )
        })
        .collect();
    named.sort_by_key(|n| std::cmp::Reverse(n.1.len()));
    let tiny = tiny.into_iter().map(|(n, t)| (n.to_owned(), t));
    for (name, text) in tiny.chain(named) {
        let fits = |fuel: u64| {
            let mut w = World::with_fuel(fuel).expect("built");
            import(&mut w, "n2s/x.sp", &text, |_| false);
            w.faults().is_empty()
        };
        let (mut lo, mut hi) = (1_000_000u64, 40_000_000_000u64);
        if !fits(hi) {
            eprintln!("{name}: over {:.0}M fuel", hi as f64 / 1e6);
            continue;
        }
        while hi - lo > hi / 20 {
            let mid = (lo + hi) / 2;
            if fits(mid) { hi = mid } else { lo = mid }
        }
        eprintln!("{name}: ~{:.1}M fuel", hi as f64 / 1e6);
    }
}
