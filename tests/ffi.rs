//! The C ABI wrapper (`cktimg::ffi`) against cktImg's own invariants, on its own symbol
//! set (`plugins/cktimg/vendor/tests/symbols.zon`) and on decks the library's tests draw:
//!
//! - every pin sits where its class terminal lands under the device's orientation;
//! - every polyline is Manhattan and both its ends touch its own net (a pin, a terminal
//!   symbol, a label, or another polyline of the net);
//! - every net of two or more pins is one wired tree, or every piece carries a name
//!   (label or terminal symbol);
//! - the same deck gives the same document (JSON) twice;
//! - refusals come back as `Err`/`None`, never a panic, including for mutated decks.

use cktimg::ffi::{Lib, Op, Role, Sch, Terminal};
use proptest::prelude::*;

const SYMBOLS: &str = include_str!("../vendor/tests/symbols.zon");

const DECKS: &[&str] = &[
    "* divider\nV1 in 0 dc 1\nR1 in out 1k\nR2 out 0 1k\n",
    "* diff pair\nVdd vdd 0 1.8\nVin inp 0 ac 1\nVinn inn 0 0.9\nR1 vdd outn 10k\nR2 vdd outp 10k\n\
     M1 outn inp tail 0 nmos\nM2 outp inn tail 0 nmos\nI1 tail 0 100u\n.model nmos nmos\n",
    "* cs amp\nVdd vdd 0 1.8\nVin in 0 sin(0.9 0.1 1k)\nRd vdd out 5k\nM1 out in 0 0 nch\nCl out 0 1p\n.model nch nmos\n",
    "* rc ladder\nV1 a 0 pulse(0 1 0 1n 1n 5n 10n)\nR1 a b 1k\nC1 b 0 1p\nR2 b c 1k\nC2 c 0 1p\nR3 c d 1k\nC3 d 0 1p\n",
];

fn lib() -> Lib {
    let mut lib = Lib::new();
    lib.load_zon(SYMBOLS).expect("cktImg's own symbols load");
    assert!(lib.len() > 20);
    lib
}

/// Applies (rot, mirror) like the header says: mirror x, then clockwise quarter turns.
fn orient((rot, mirror): (u8, bool), x: i32, y: i32) -> [i32; 2] {
    let x = if mirror { -x } else { x };
    match rot % 4 {
        0 => [x, y],
        1 => [-y, x],
        2 => [-x, -y],
        _ => [y, -x],
    }
}

fn on(p: [i32; 2], poly: &[[i32; 2]]) -> bool {
    poly.windows(2).any(|s| {
        let (a, b) = (s[0], s[1]);
        (a[0].min(b[0])..=a[0].max(b[0])).contains(&p[0])
            && (a[1].min(b[1])..=a[1].max(b[1])).contains(&p[1])
    })
}

/// The invariants of the module comment, on one placed deck.
fn check(sch: &Sch, terms: &dyn Fn(&str) -> Vec<[i32; 2]>) {
    let n = sch.net_count();
    let net_of = |name: &str| {
        (0..n)
            .find(|&k| sch.net_name(k) == name)
            .expect("a pin's net is listed")
    };
    // Points that carry a net's name, and every pin point, per net.
    let mut named: Vec<Vec<[i32; 2]>> = vec![Vec::new(); n];
    let mut pins: Vec<Vec<[i32; 2]>> = vec![Vec::new(); n];
    for d in 0..sch.device_count() {
        let pos = sch.device_pos(d);
        let o = sch.device_orient(d);
        let anchors = terms(sch.device_class(d));
        for p in 0..sch.pin_count(d) {
            let at = sch.pin_xy(d, p);
            if let Some(a) = anchors.get(p) {
                let q = orient(o, a[0], a[1]);
                assert_eq!(
                    at,
                    [pos[0] + q[0], pos[1] + q[1]],
                    "{} pin {p}",
                    sch.device_name(d)
                );
            }
            // A card pin the class has no terminal for (a MOS bulk on a three-terminal
            // symbol) sits at the origin and gets no wire.
            let Some(net) = sch.pin_net(d, p).filter(|_| !sch.pin_term(d, p).is_empty()) else {
                continue;
            };
            let k = net_of(net);
            if sch.device_role(d) == Role::None {
                pins[k].push(at);
            } else {
                assert_eq!(sch.pin_count(d), 1, "a terminal symbol has one pin");
                named[k].push(at);
            }
        }
    }
    for l in 0..sch.label_count() {
        named[net_of(sch.label_net(l))].push(sch.label_xy(l));
        assert!(sch.label_side(l) < 4);
    }
    for k in 0..n {
        let polys: Vec<&[[i32; 2]]> = (0..sch.wire_segment_count(k))
            .map(|s| sch.wire_segment(k, s))
            .collect();
        for (i, poly) in polys.iter().enumerate() {
            assert!(
                poly.windows(2)
                    .all(|s| s[0][0] == s[1][0] || s[0][1] == s[1][1]),
                "Manhattan"
            );
            for end in [poly[0], poly[poly.len() - 1]] {
                let touches = pins[k].contains(&end)
                    || named[k].contains(&end)
                    || polys
                        .iter()
                        .enumerate()
                        .any(|(j, other)| j != i && on(end, other));
                assert!(
                    touches,
                    "net {}: wire end {end:?} touches nothing of its net",
                    sch.net_name(k)
                );
            }
        }
        if pins[k].len() < 2 {
            continue;
        }
        // One wired tree, or a name on every piece (a piece: polylines joined end to line).
        let reach = |p: [i32; 2]| polys.iter().position(|poly| on(p, poly));
        let mut parent: Vec<usize> = (0..polys.len()).collect();
        fn root(p: &mut [usize], mut i: usize) -> usize {
            while p[i] != i {
                i = p[i];
            }
            i
        }
        for i in 0..polys.len() {
            for j in 0..polys.len() {
                let ends = [polys[j][0], polys[j][polys[j].len() - 1]];
                if i != j && ends.iter().any(|&e| on(e, polys[i])) {
                    let (a, b) = (root(&mut parent, i), root(&mut parent, j));
                    parent[a] = b;
                }
            }
        }
        let roots: Vec<Option<usize>> = pins[k]
            .iter()
            .map(|&p| reach(p).map(|i| root(&mut parent, i)))
            .collect();
        let wired_tree = roots.iter().all(|r| r.is_some() && *r == roots[0]);
        let named_roots: Vec<usize> = named[k]
            .iter()
            .filter_map(|&q| reach(q).map(|i| root(&mut parent, i)))
            .collect();
        let every_piece_named = pins[k]
            .iter()
            .zip(&roots)
            .all(|(p, r)| named[k].contains(p) || r.is_some_and(|r| named_roots.contains(&r)));
        assert!(
            wired_tree || every_piece_named,
            "net {} is neither wired nor named on every piece",
            sch.net_name(k)
        );
    }
}

/// Terminal anchors per class name, from the symbol file (classes `load_zon` added).
fn anchors() -> impl Fn(&str) -> Vec<[i32; 2]> {
    // Each class line of symbols.zon lists `.name = "<class>"` then its terminals' `.at`.
    let mut table: Vec<(String, Vec<[i32; 2]>)> = Vec::new();
    for line in SYMBOLS.lines().filter(|l| l.contains(".name = \"")) {
        let name = line
            .split(".name = \"")
            .nth(1)
            .unwrap()
            .split('"')
            .next()
            .unwrap()
            .to_owned();
        let terms = line.split(".draw").next().unwrap();
        let pts = terms
            .split(".at = .{ .x = ")
            .skip(1)
            .map(|t| {
                let x: i32 = t.split(',').next().unwrap().trim().parse().unwrap();
                let y: i32 = t
                    .split(".y = ")
                    .nth(1)
                    .unwrap()
                    .split(' ')
                    .next()
                    .unwrap()
                    .trim()
                    .parse()
                    .unwrap();
                [x, y]
            })
            .collect();
        table.push((name, pts));
    }
    move |class: &str| {
        table
            .iter()
            .find(|t| t.0 == class)
            .map(|t| t.1.clone())
            .unwrap_or_default()
    }
}

#[test]
fn placed_decks_keep_cktimgs_invariants() {
    let terms = anchors();
    let mut lib = lib();
    for deck in DECKS {
        let sch = lib
            .place(deck, None)
            .unwrap_or_else(|e| panic!("{deck}: {e}"));
        assert_eq!(sch.report(), "");
        let devices = deck
            .lines()
            .filter(|l| l.starts_with(|c: char| c.is_ascii_alphabetic()))
            .count();
        // The netlist's devices are named, the terminal symbols cktImg adds are not (a
        // driver island's source comes after the symbols added before it).
        let named = (0..sch.device_count()).filter(|&d| !sch.device_name(d).is_empty());
        assert_eq!(named.clone().count(), devices);
        for d in 0..sch.device_count() {
            let device = !sch.device_name(d).is_empty();
            assert_eq!(
                sch.device_role(d) == Role::None,
                device,
                "{}",
                sch.device_class(d)
            );
            assert!(sch.device_op_count(d) > 0);
            let b = sch.device_bounds(d);
            assert!(b[0] <= b[2] && b[1] <= b[3]);
        }
        assert!(
            named.take(1).all(|d| d == 0),
            "the netlist's first device comes first"
        );
        let b = sch.bounds().expect("a drawing");
        for d in 0..sch.device_count() {
            let p = sch.device_pos(d);
            assert!((b[0]..=b[2]).contains(&p[0]) && (b[1]..=b[3]).contains(&p[1]));
        }
        check(&sch, &terms);
        let (findings, errors) = sch.lint();
        assert_eq!(errors, 0, "{findings}");
    }
}

#[test]
fn same_deck_same_document() {
    let mut lib = lib();
    for deck in DECKS {
        let a = lib.place(deck, None).unwrap().json();
        let b = lib.place(deck, None).unwrap().json();
        assert!(a.starts_with('{') && a.len() > 100);
        assert_eq!(a, b, "{deck}");
    }
    // A fresh library gives the same document as a used one.
    let fresh = Lib::new().place(DECKS[1], None).map(|s| s.json());
    let used = {
        let mut l = Lib::new();
        let _ = l.place(DECKS[0], None).unwrap();
        l.place(DECKS[1], None).map(|s| s.json())
    };
    assert_eq!(fresh, used);
}

#[test]
fn placed_strokes_and_anchors_follow_the_devices() {
    let mut lib = lib();
    let mut sch = lib.place(DECKS[1], None).unwrap();
    for d in 0..sch.device_count() {
        let b = sch.device_bounds(d);
        let inside = |p: [i32; 2]| (b[0]..=b[2]).contains(&p[0]) && (b[1]..=b[3]).contains(&p[1]);
        for o in 0..sch.device_op_count(d) {
            match sch.device_op_kind(d, o) {
                cktimg::ffi::OP_LINE | cktimg::ffi::OP_POLYLINE => {
                    let pts = sch.device_op_points(d, o);
                    assert!(pts.len() >= 2 && pts.iter().all(|&p| inside(p)));
                }
                cktimg::ffi::OP_CIRCLE => assert!(
                    sch.device_op_circle(d, o)
                        .is_some_and(|(c, r)| r > 0 && inside(c))
                ),
                _ => assert!(sch.device_op_text(d, o).is_some()),
            }
        }
        let _ = sch.device_refdes_anchor(d);
    }
    for j in 0..sch.junction_count() {
        let p = sch.junction(j);
        assert!(
            (0..sch.net_count())
                .any(|n| (0..sch.wire_segment_count(n)).any(|s| on(p, sch.wire_segment(n, s))))
        );
    }
    for k in 0..sch.noconnect_count() {
        let _ = sch.noconnect(k);
    }
}

#[test]
fn refusals_are_errors_not_panics() {
    let mut lib = Lib::new();
    let ab = [
        Terminal {
            name: "a",
            x: -20,
            y: 0,
            flags: 0,
        },
        Terminal {
            name: "b",
            x: 20,
            y: 0,
            flags: 0,
        },
    ];
    let id = lib.add("res", Role::None, &ab, &[Op::Line([-20, 0, 20, 0])]);
    assert_eq!(id, Some(0));
    assert_eq!(
        lib.add("RES", Role::None, &ab, &[]),
        Some(0),
        "an exact repeat (names fold case)"
    );
    let moved = [ab[0], Terminal { x: 30, ..ab[1] }];
    assert_eq!(
        lib.add("res", Role::None, &moved, &[]),
        None,
        "same name, other terminals"
    );
    let same_point = [ab[0], Terminal { x: -20, ..ab[1] }];
    assert_eq!(
        lib.add("cap", Role::None, &same_point, &[]),
        None,
        "two terminals on one point"
    );
    assert_eq!(lib.add("ind", Role::None, &[], &[]), None, "no terminals");
    assert_eq!(lib.add("nul\0", Role::None, &ab, &[]), None);
    assert_eq!(
        lib.add("ind", Role::None, &ab, &[Op::Polyline(&[[0, 0]])]),
        None,
        "a one-point polyline"
    );
    assert_eq!(lib.len(), 1);
    assert!(!lib.set_unit(0) && lib.set_unit(60));
    assert!(lib.load_zon(".{ .classes = 3 }").is_err());

    let e = lib
        .place("* t\n.include models.lib\nR1 a b 1k\n", None)
        .unwrap_err();
    assert!(e.contains("line 2") && e.contains("Include"), "{e}");
    assert!(lib.place("* t\nR1 a\0 b 1k\n", None).is_err());
    let sch = lib
        .place("* t\nR1 a b 1k\n", Some(".{ .layout = .{ .bogus = 1.0 } }"))
        .unwrap();
    assert!(sch.report().contains("bogus"), "{}", sch.report());
    drop(sch);
    // An unknown device kind is a generated box, not an error.
    let sch = lib.place("* t\nL1 a b 1u\n", None).unwrap();
    assert!(sch.device_class(0).starts_with("generic"));
}

/// Mutations of the decks: deleted and duplicated lines, spliced punctuation.
fn mutated() -> impl Strategy<Value = String> {
    (
        0..DECKS.len(),
        proptest::collection::vec((0usize..64, 0u8..4, any::<u8>()), 1..10),
    )
        .prop_map(|(i, edits)| {
            let mut lines: Vec<String> = DECKS[i].lines().map(str::to_owned).collect();
            for (at, op, byte) in edits {
                let k = at % lines.len().max(1);
                if lines.is_empty() {
                    lines.push("* t".to_owned());
                }
                match op {
                    0 if lines.len() > 1 => {
                        lines.remove(k);
                    }
                    1 => lines.insert(k, lines[k].clone()),
                    2 => {
                        let s = &mut lines[k];
                        let pos = usize::from(byte) % (s.len() + 1);
                        let ch = b"(){}='\"+.*x0 "[usize::from(byte) % 13] as char;
                        if s.is_char_boundary(pos) {
                            s.insert(pos, ch);
                        }
                    }
                    _ => lines.insert(
                        k,
                        [
                            ".subckt s a b",
                            ".ends",
                            "X1 a b s",
                            "M9 a b c d e f g",
                            ".tran 1n 1u",
                        ][usize::from(byte) % 5]
                            .to_owned(),
                    ),
                }
            }
            lines.join("\n")
        })
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 48, ..ProptestConfig::default() })]

    #[test]
    fn mutated_decks_never_panic(deck in mutated()) {
        let mut lib = lib();
        if let Ok(sch) = lib.place(&deck, None) {
            for d in 0..sch.device_count() {
                for p in 0..sch.pin_count(d) {
                    let _ = (sch.pin_term(d, p), sch.pin_net(d, p), sch.pin_xy(d, p));
                }
            }
            prop_assert!(!sch.json().is_empty());
        }
    }
}
