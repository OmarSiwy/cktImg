//! Layout transform: one deck cell → cktImg → a [`Drawn`] cell (instance origins and
//! orientations, wires, labels/ports, no-connects), in xschem units.
//!
//! cktImg is told what every Schemify symbol looks like ([`library`]): one class per
//! symbol family, terminals at the symbol's pin positions turned into cktImg's canonical
//! frame (principal terminals on the x axis) by [`to_canonical`], one pin-to-pin unit
//! being [`UNIT`] — so cktImg's integer grid is xschem units and every wire it draws ends
//! exactly on a Schemify pin. Each cell becomes a small SPICE deck of its own ([`cell_deck`]):
//! one card per device, written so cktImg picks the class with the device's geometry
//! (`R`/`C`/`L`/`V`/`I`/`D` as themselves, any other two-pin card as a `B`, MOSFETs and
//! BJTs with a model word naming their polarity, generated boxes as `X` instances of a
//! `.subckt b<symbol>` stub), with the cell's own net names where cktImg can read them, so
//! its supply/ground/input/output heuristics see the names the designer wrote.
//!
//! Translating back: devices keep cktImg's position; the Schemify orientation is cktImg's
//! composed with the family's turn, and every pin is asserted to land where cktImg put
//! it. Wires are its polylines split into segments; its labels, rail and port symbols and
//! hidden pins (a MOS bulk) become `label` records (the first on a subckt port's net
//! becomes the `port`); its no-connect crosses become `noconn`; junction dots are dropped
//! (Schemify derives them). A net nothing names but the cell needs by name (a port, a
//! `.global`, a net its code text mentions) gets a label on its first pin.

use crate::ffi::{Lib, Op, Role, Sch, TERM_HIDDEN, Terminal};
use crate::recognize::{Family, Origin, Recognized};
use crate::spice::{Deck, Interner};

/// One pin-to-pin length of a two-pin core symbol (`res`: `p` at y = -30, `n` at y = 30),
/// in xschem units: the unit cktImg measures its wire lengths in.
pub const UNIT: i32 = 60;

/// Orientation words indexed by `quarter_turns + 4 * mirrored` (format spec §3).
pub const ORIENT_WORDS: [&str; 8] = ["R0", "R90", "R180", "R270", "MR0", "MR90", "MR180", "MR270"];

/// Maps a symbol-local point through orientation `o` (mirror x, then clockwise quarter
/// turns, y down): format spec §3, and the same as cktImg's `Orient.apply`.
pub fn xform(o: u8, x: i32, y: i32) -> (i32, i32) {
    assert!(o < 8, "orientation index {o}");
    let x = if o >= 4 { -x } else { x };
    match o % 4 {
        0 => (x, y),
        1 => (-y, x),
        2 => (-x, -y),
        _ => (y, -x),
    }
}

/// The orientation that applies `b`, then `a`.
pub fn compose(a: u8, b: u8) -> u8 {
    let probes = [(1, 0), (0, 1)];
    let want = |p: (i32, i32)| {
        let q = xform(b, p.0, p.1);
        xform(a, q.0, q.1)
    };
    let o = (0..8u8)
        .find(|&o| probes.iter().all(|&p| xform(o, p.0, p.1) == want(p)))
        .expect("the eight orientations are closed under composition");
    assert!(o < 8);
    o
}

/// The label orientation whose text runs away from a symbol placed with orientation `o`,
/// at its pin `(px, py)` (symbol-local): along the pin's dominant axis, outwards.
pub fn facing(o: u8, px: i32, py: i32) -> u8 {
    let d = if px.abs() >= py.abs() {
        (px.signum(), 0)
    } else {
        (0, py.signum())
    };
    let d = if d == (0, 0) { (1, 0) } else { d };
    let f = (0..4u8)
        .find(|&k| xform(k, 1, 0) == xform(o, d.0, d.1))
        .expect("a quarter turn");
    assert!(f < 4);
    f
}

/// Turn from a family's Schemify symbol frame (vertical, like xschem's devices) into
/// cktImg's canonical frame (principal terminals on the x axis): R90 for the core
/// families, none for the transmission line (already horizontal) and generated boxes.
pub fn to_canonical(fam: Family) -> u8 {
    match fam {
        Family::Tline | Family::Box => 0,
        _ => 1,
    }
}

/// cktImg class names a family registers (all with the family's geometry): the device
/// vocabulary names of the cards [`cell_deck`] writes for it. Boxes register `b<symbol>`.
fn class_names(fam: Family) -> &'static [&'static str] {
    match fam {
        Family::Two => &[
            "res", "cap", "ind", "vsource", "isource", "diode", "bsource",
        ],
        Family::Nmos => &["nmos"],
        Family::Pmos => &["pmos"],
        Family::Npn => &["npn"],
        Family::Pnp => &["pnp"],
        Family::Vcxs => &["cvsource", "cisource"],
        Family::Vsw => &["switch"],
        Family::Tline => &["tline"],
        Family::Box => &[],
    }
}

/// Builds cktImg's class library for the symbols of `rec`: each family's geometry under
/// its vocabulary names, one `b<s>` class per generated box symbol, and the rail and
/// port symbols cktImg adds (one terminal each, at their origin).
///
/// Cost: one `Lib::add` per family name and per box symbol.
///
/// A class cktImg refuses (two pins of one symbol on one point, a NUL in a name) is left
/// out and named in the returned warnings: a cell using it then fails placement and is
/// drawn with labels (`Drawn::fallback`), so a hostile netlist never panics the import.
pub fn library(rec: &Recognized) -> (Lib, Vec<String>) {
    let mut lib = Lib::new();
    let mut refused = Vec::new();
    assert!(lib.set_unit(UNIT));
    let syms = &rec.syms;
    for s in 0..syms.stem.len() {
        if syms.pins(s).is_empty() {
            continue; // a subckt with no ports: only node-less calls, which cktImg never draws
        }
        let fam = syms.family[s];
        let t = to_canonical(fam);
        let pins: Vec<(i32, i32)> = syms
            .pins(s)
            .map(|k| xform(t, syms.pin_x[k], syms.pin_y[k]))
            .collect();
        let hidden = |k: usize| matches!(fam, Family::Nmos | Family::Pmos) && k == 3;
        let terms: Vec<Terminal> = syms
            .pins(s)
            .zip(&pins)
            .enumerate()
            .map(|(k, (row, p))| Terminal {
                name: &syms.pin_name[row],
                x: p.0,
                y: p.1,
                flags: if hidden(k) { TERM_HIDDEN } else { 0 },
            })
            .collect();
        // The body outline, for cktImg's spacing: pins sit on it (`Symbols::body`).
        let b = syms.body[s];
        let corners = [
            (b[0], b[1]),
            (b[2], b[1]),
            (b[2], b[3]),
            (b[0], b[3]),
            (b[0], b[1]),
        ];
        let outline: Vec<[i32; 2]> = corners
            .iter()
            .map(|&(x, y)| {
                let p = xform(t, x, y);
                [p.0, p.1]
            })
            .collect();
        let ops = [Op::Polyline(&outline)];
        let block = format!("b{s}");
        let names: &[&str] = if fam == Family::Box {
            &[&block]
        } else {
            class_names(fam)
        };
        for name in names {
            if lib.add(name, Role::None, &terms, &ops).is_none() {
                refused.push(format!(
                    "cktImg refused class {name} ({}); its cells are drawn with labels",
                    syms.stem[s]
                ));
            }
        }
    }
    let rails = [
        ("vdd", Role::PowerRail),
        ("gnd", Role::GroundRail),
        ("ipin", Role::InputPort),
        ("opin", Role::OutputPort),
    ];
    let p = [Terminal {
        name: "p",
        x: 0,
        y: 0,
        flags: 0,
    }];
    for (name, role) in rails {
        assert!(
            lib.add(name, role, &p, &[Op::Line([-10, 0, 10, 0])])
                .is_some()
        );
    }
    assert!(lib.len() >= rails.len());
    (lib, refused)
}

/// One drawn cell: instance rows parallel to `deck.devs(c)`, wire segments, name markers
/// (labels and ports) and no-connect marks, xschem units. Lifetime: one cell's emit.
#[derive(Debug, Default)]
pub struct Drawn {
    /// Instance origin x.
    pub x: Vec<i32>,
    /// Instance origin y.
    pub y: Vec<i32>,
    /// Instance orientation, an index into [`ORIENT_WORDS`].
    pub orient: Vec<u8>,
    /// Wire segments `[x1, y1, x2, y2]`, axis-aligned, non-zero length.
    pub wire: Vec<[i32; 4]>,
    /// Marker anchors.
    pub mark_x: Vec<i32>,
    /// Marker anchors.
    pub mark_y: Vec<i32>,
    /// Cell-local net each marker names.
    pub mark_net: Vec<u32>,
    /// Marker orientation index (text/arrow direction).
    pub mark_orient: Vec<u8>,
    /// `true` for a `port` record, `false` for a `label`.
    pub mark_port: Vec<bool>,
    /// No-connect marks.
    pub noconn: Vec<[i32; 2]>,
    /// Bounding box of everything drawn `[x0, y0, x1, y1]` (all zero when empty).
    pub bounds: [i32; 4],
    /// Nets with ≥ 2 device pins that cktImg did not draw as a rail.
    pub nets_multi: u32,
    /// Of those, nets whose pins one tree of wires connects (no label needed).
    pub nets_wired: u32,
    /// Why cktImg was not used for this cell (then every pin is labelled), if it was not.
    pub fallback: Option<String>,
    /// Pins cktImg left with neither a wire nor a name (a cktImg bug); each got a label.
    pub strays: u32,
}

impl Drawn {
    fn mark(&mut self, p: [i32; 2], net: u32, orient: u8) {
        self.mark_x.push(p[0]);
        self.mark_y.push(p[1]);
        self.mark_net.push(net);
        self.mark_orient.push(orient);
        self.mark_port.push(false);
    }

    fn has_mark(&self, net: u32) -> bool {
        self.mark_net.contains(&net)
    }
}

/// Label orientation per cktImg text side (0 left, 1 right, 2 up, 3 down): the editor
/// writes a label's text along its orientation's +x. A port draws its arrow and text the
/// other way (along -x), so a marker that becomes a port turns by R180.
const LABEL_ORIENT: [u8; 4] = [2, 0, 3, 1];

/// cktImg's name for each local net of cell `c` (lowercase): the deck's own name where
/// cktImg's tokenizer reads it as one field, `0` for ground (`gnd` too when the cell has
/// no `0`), else a fresh `n2s_<n>`.
fn net_names(deck: &Deck, c: usize) -> Vec<String> {
    let n = deck.net_count(c);
    let has_zero = (0..n as u32).any(|k| deck.net_key(c, k) == "0");
    let mut taken = Interner::default();
    let mut out: Vec<String> = Vec::with_capacity(n);
    for k in 0..n as u32 {
        let key = deck.net_key(c, k);
        let safe = !key.is_empty()
            && key
                .bytes()
                .all(|b| b.is_ascii_graphic() && !b",(){}='\";".contains(&b))
            && !key.starts_with('$')
            && !key.contains("//");
        let mut name = match key {
            "gnd" if !has_zero => "0".to_owned(),
            "gnd" => format!("n2s_{k}"),
            _ if safe => key.to_owned(),
            _ => format!("n2s_{k}"),
        };
        while !taken.intern(&name).1 {
            name.push('_');
        }
        out.push(name);
    }
    assert_eq!(out.len(), n);
    out
}

/// `text` with every byte cktImg's tokenizer would treat specially turned into a space:
/// the words of a source specification (`dc 0 ac 1 pulse 0 1 …`) survive, so cktImg can
/// tell a signal source from a supply.
fn plain_words(text: &str) -> String {
    text.chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || "._+-".contains(ch) {
                ch
            } else {
                ' '
            }
        })
        .collect()
}

/// The SPICE deck cktImg places for cell `c`: a title, a `.subckt b<s>` stub per box
/// symbol the cell uses, then one card per device in deck order (`<letter><row>`, so the
/// names are unique and cktImg's device `i` is the cell's device `i`). Node-less devices
/// (an `X` on globals only) have nothing to lay out and are left out ([`draw`] places
/// them).
pub fn cell_deck(deck: &Deck, rec: &Recognized, c: usize, names: &[String]) -> String {
    let syms = &rec.syms;
    let mut text = format!("* {}\n", if c == 0 { "top" } else { &deck.cell_name[c] });
    let mut boxes: Vec<usize> = deck
        .devs(c)
        .filter(|&d| !deck.nets_of(d).is_empty())
        .map(|d| rec.parts.sym[d] as usize)
        .filter(|&s| syms.family[s] == Family::Box)
        .collect();
    boxes.sort_unstable();
    boxes.dedup();
    for &s in &boxes {
        text.push_str(&format!(".subckt b{s}"));
        for k in 1..=syms.pins(s).len() {
            text.push_str(&format!(" p{k}"));
        }
        text.push_str("\n.ends\n");
    }
    for (i, d) in deck.devs(c).enumerate() {
        if deck.nets_of(d).is_empty() {
            continue;
        }
        let s = rec.parts.sym[d] as usize;
        let letter = deck.dev_name[d].as_bytes()[0].to_ascii_lowercase();
        let (card, tail): (u8, String) = match syms.family[s] {
            Family::Two => match letter {
                b'r' | b'c' | b'l' | b'd' => (letter, String::new()),
                b'v' | b'i' => (letter, plain_words(&deck.dev_rest[d])),
                _ => (b'b', "v=0".to_owned()),
            },
            Family::Nmos => (b'm', "nmos".to_owned()),
            Family::Pmos => (b'm', "pmos".to_owned()),
            Family::Npn => (b'q', "npn".to_owned()),
            Family::Pnp => (b'q', "pnp".to_owned()),
            Family::Vcxs => (if letter == b'g' { b'g' } else { b'e' }, "1".to_owned()),
            Family::Vsw => (b's', "sw".to_owned()),
            Family::Tline => (b't', "z0=50 td=1n".to_owned()),
            Family::Box => (b'x', format!("b{s}")),
        };
        text.push(card as char);
        text.push_str(&i.to_string());
        for &n in deck.nets_of(d) {
            text.push(' ');
            text.push_str(&names[n as usize]);
        }
        text.push(' ');
        text.push_str(&tail);
        text.push('\n');
    }
    assert!(text.starts_with('*'));
    text
}

/// Draws cell `c` with cktImg (or, when cktImg refuses its deck, the cell has more than
/// [`crate::CELL_DEVICES_MAX`] devices or `budget` of devices is spent, with every pin
/// labelled): see the module comment. `budget` drops by the cell's device count when
/// cktImg draws it.
///
/// # Panics
///
/// Panics if cktImg's result contradicts the deck it was given (device or pin counts, a
/// pin off its symbol's position), which would mean a wrong class library.
pub fn draw(lib: &mut Lib, deck: &Deck, rec: &Recognized, c: usize, budget: &mut usize) -> Drawn {
    let devs = deck.devs(c);
    let names = net_names(deck, c);
    let mut out = Drawn::default();
    // Node-less devices (an `X` on globals only) are placed below the drawing.
    let wired = devs
        .clone()
        .filter(|&d| !deck.nets_of(d).is_empty())
        .count();
    if wired == 0 {
        for _ in devs {
            out.x.push(0);
            out.y.push(0);
            out.orient.push(0);
        }
        name_nets(&mut out, deck, rec, c, &[]);
        grow_bounds(&mut out);
        place_free(&mut out, deck, rec, c);
        return out;
    }
    if wired > *budget || wired > crate::CELL_DEVICES_MAX {
        out.fallback = Some(format!(
            "over the {} devices cktImg draws per cell, or the {} per import",
            crate::CELL_DEVICES_MAX,
            crate::DRAWN_DEVICES_MAX
        ));
        labelled(&mut out, deck, rec, c);
        return out;
    }
    let text = cell_deck(deck, rec, c, &names);
    let sch = match lib.place(&text, None) {
        Ok(sch) => sch,
        Err(e) => {
            out.fallback = Some(format!("cktImg refused the cell: {}", e.trim()));
            labelled(&mut out, deck, rec, c);
            return out;
        }
    };
    *budget -= wired;
    translate(&mut out, &sch, deck, rec, c, &names);
    place_free(&mut out, deck, rec, c);
    assert_eq!(out.x.len(), deck.devs(c).len());
    out
}

/// Places the node-less devices of cell `c` (nothing to wire, so cktImg never sees them)
/// in a row below everything drawn, each pin no-connected: a 0-port subckt's call has
/// none, a stub's one pin is a placeholder its template never prints.
fn place_free(out: &mut Drawn, deck: &Deck, rec: &Recognized, c: usize) {
    let syms = &rec.syms;
    assert_eq!(out.x.len(), deck.devs(c).len());
    let mut x = out.bounds[0].div_euclid(10) * 10;
    let y = out.bounds[3].div_euclid(10) * 10 + 2 * UNIT;
    for (i, d) in deck.devs(c).enumerate() {
        if !deck.nets_of(d).is_empty() {
            continue;
        }
        let s = rec.parts.sym[d] as usize;
        let b = syms.body[s];
        // The body's top-left corner at the cursor.
        let (ox, oy) = (x - b[0], y - b[1]);
        (out.x[i], out.y[i], out.orient[i]) = (ox, oy, 0);
        for k in syms.pins(s) {
            out.noconn.push([ox + syms.pin_x[k], oy + syms.pin_y[k]]);
        }
        x += b[2] - b[0] + UNIT;
    }
    grow_bounds(out);
    assert!(out.bounds[1] <= out.bounds[3]);
}

/// Fills `out` from cktImg's placement `sch` of cell `c`.
fn translate(
    out: &mut Drawn,
    sch: &Sch,
    deck: &Deck,
    rec: &Recognized,
    c: usize,
    names: &[String],
) {
    let syms = &rec.syms;
    let devs = deck.devs(c);
    let n = devs.len();
    // Node-less rows are not in cktImg's deck (`cell_deck`); `place_free` places them.
    let wired: Vec<bool> = devs.clone().map(|d| !deck.nets_of(d).is_empty()).collect();
    assert!(
        sch.device_count() >= wired.iter().filter(|&&w| w).count(),
        "cktImg dropped devices"
    );
    let mut ids = Interner::default();
    for name in names {
        assert!(ids.intern(name).1);
    }
    // cktImg reports only the nets it was given, plus its ground `0` when the cell has none.
    let local = |name: &str| ids.get(name);
    // cktImg lists a driver island's source after the symbols it added, so devices are
    // matched by name: `<letter><row>` (see `cell_deck`), the added symbols unnamed.
    let mut at_row: Vec<usize> = vec![usize::MAX; n];
    let mut added: Vec<usize> = Vec::new();
    for i in 0..sch.device_count() {
        match sch
            .device_name(i)
            .get(1..)
            .and_then(|r| r.parse::<usize>().ok())
        {
            Some(row) => {
                assert!(
                    row < n && at_row[row] == usize::MAX,
                    "cktImg device {}",
                    sch.device_name(i)
                );
                at_row[row] = i;
            }
            None => added.push(i),
        }
    }
    assert!(
        at_row
            .iter()
            .zip(&wired)
            .all(|(&i, &w)| (i != usize::MAX) == w),
        "cktImg dropped devices"
    );
    // Pins per local net, in device order (for naming, wiredness and no-connects).
    let mut pin_pts: Vec<Vec<[i32; 2]>> = vec![Vec::new(); names.len()];
    let mut hidden_pts: Vec<([i32; 2], u32, u8)> = Vec::new();
    // Every pin point with the orientation a label there reads best in.
    let mut faces: Vec<([i32; 2], u8)> = Vec::new();
    for (row, d) in devs.enumerate() {
        if !wired[row] {
            out.x.push(0);
            out.y.push(0);
            out.orient.push(0);
            continue;
        }
        let i = at_row[row];
        let s = rec.parts.sym[d] as usize;
        let pos = sch.device_pos(i);
        let (rot, mirror) = sch.device_orient(i);
        let o = compose(rot + 4 * u8::from(mirror), to_canonical(syms.family[s]));
        out.x.push(pos[0]);
        out.y.push(pos[1]);
        out.orient.push(o);
        assert_eq!(
            sch.pin_count(i),
            syms.pins(s).len(),
            "pins of {}",
            deck.dev_name[d]
        );
        for (k, row) in syms.pins(s).enumerate() {
            let (dx, dy) = xform(o, syms.pin_x[row], syms.pin_y[row]);
            let at = [pos[0] + dx, pos[1] + dy];
            assert_eq!(sch.pin_xy(i, k), at, "{} pin {k}", deck.dev_name[d]);
            let net = deck.nets_of(d)[k];
            assert_eq!(sch.pin_net(i, k).and_then(local), Some(net));
            let hidden = matches!(syms.family[s], Family::Nmos | Family::Pmos) && k == 3;
            let face = facing(o, syms.pin_x[row], syms.pin_y[row]);
            faces.push((at, face));
            if hidden {
                hidden_pts.push((at, net, face));
            } else {
                pin_pts[net as usize].push(at);
            }
        }
    }
    let mut rails = vec![false; names.len()];
    for i in added {
        let role = sch.device_role(i);
        let net = sch
            .pin_net(i, 0)
            .and_then(local)
            .expect("a terminal symbol sits on a net of the cell");
        let (orient, rail) = match role {
            Role::PowerRail => (3, true),
            Role::GroundRail => (1, true),
            Role::InputPort => (2, false),
            Role::OutputPort => (0, false),
            Role::None => unreachable!("cktImg adds only terminal symbols"),
        };
        rails[net as usize] |= rail;
        out.mark(sch.pin_xy(i, 0), net, orient);
    }
    for l in 0..sch.label_count() {
        let net = local(sch.label_net(l)).expect("a label names a net of the cell");
        out.mark(
            sch.label_xy(l),
            net,
            LABEL_ORIENT[sch.label_side(l) as usize],
        );
    }
    // A hidden pin (MOS bulk) gets no wire, so it is joined by name; a net cktImg wired
    // whole and left unnamed then needs its name on the wired piece too.
    let face_at = |p: [i32; 2]| faces.iter().find(|f| f.0 == p).map_or(0, |f| f.1);
    for &(at, net, face) in &hidden_pts {
        if !out.has_mark(net)
            && let Some(&p) = pin_pts[net as usize].first()
        {
            out.mark(p, net, face_at(p));
        }
        out.mark(at, net, face);
    }
    let mut segs: Vec<Vec<&[[i32; 2]]>> = vec![Vec::new(); names.len()];
    let mut wire_of: Vec<std::ops::Range<usize>> = vec![0..0; names.len()];
    for w in 0..sch.net_count() {
        let Some(net) = local(sch.net_name(w)) else {
            assert_eq!(
                sch.wire_segment_count(w),
                0,
                "wires on a net the cell does not have"
            );
            continue;
        };
        let mut net_wires: Vec<[i32; 4]> = Vec::new();
        for s in 0..sch.wire_segment_count(w) {
            let poly = sch.wire_segment(w, s);
            for p in poly.windows(2) {
                assert!(
                    p[0][0] == p[1][0] || p[0][1] == p[1][1],
                    "a Manhattan polyline"
                );
                net_wires.push([p[0][0], p[0][1], p[1][0], p[1][1]]);
            }
            segs[net as usize].push(poly);
        }
        let start = out.wire.len();
        out.wire.extend(merged(net_wires));
        wire_of[net as usize] = start..out.wire.len();
    }
    for (net, pins) in pin_pts.iter().enumerate() {
        if pins.len() >= 2 && !rails[net] {
            out.nets_multi += 1;
            out.nets_wired += u32::from(wired(pins, &segs[net]));
        }
    }
    // cktImg should leave no pin of a net without a wire or a name (docs/upstream lists the
    // decks where it does). Such a net is joined by name instead: a label on every pin.
    let named_at = |out: &Drawn, net: u32, p: [i32; 2]| {
        (0..out.mark_x.len()).any(|m| out.mark_net[m] == net && [out.mark_x[m], out.mark_y[m]] == p)
    };
    for (net, pins) in pin_pts.iter().enumerate() {
        let net = net as u32;
        let stray = |p: &[i32; 2]| {
            let on_wire = out.wire[wire_of[net as usize].clone()]
                .iter()
                .any(|w| (w[0]..=w[2]).contains(&p[0]) && (w[1]..=w[3]).contains(&p[1]));
            !on_wire && !named_at(out, net, *p)
        };
        let strays = pins.iter().filter(|p| stray(p)).count() as u32;
        if pins.len() >= 2 && strays > 0 {
            out.strays += strays;
            for &p in pins {
                if !named_at(out, net, p) {
                    out.mark(p, net, face_at(p));
                }
            }
        }
    }
    // Every net of two or more pins carries its name (cards and code may name it, and the
    // designer wrote it): one label where it reads as a net name, else on its first pin.
    for (net, pins) in pin_pts.iter().enumerate() {
        if pins.len() >= 2 && !out.has_mark(net as u32) {
            match spot(&out.wire, wire_of[net].clone()) {
                Some(p) => out.mark(p, net as u32, 0),
                None => out.mark(pins[0], net as u32, face_at(pins[0])),
            }
        }
    }
    out.bounds = sch.bounds().unwrap_or([0; 4]);
    let first: Vec<Option<([i32; 2], u8)>> = pin_pts
        .iter()
        .map(|p| p.first().map(|&q| (q, face_at(q))))
        .collect();
    name_nets(out, deck, rec, c, &first);
    // cktImg's crosses, plus one on any other lone pin it missed and nothing names.
    let marked = |out: &Drawn, p: [i32; 2]| {
        (0..out.mark_x.len()).any(|m| [out.mark_x[m], out.mark_y[m]] == p)
    };
    for k in 0..sch.noconnect_count() {
        let p = sch.noconnect(k);
        if !marked(out, p) {
            out.noconn.push(p);
        }
    }
    for (net, pins) in pin_pts.iter().enumerate() {
        let wired = |p: [i32; 2]| {
            out.wire[wire_of[net].clone()]
                .iter()
                .any(|w| (w[0]..=w[2]).contains(&p[0]) && (w[1]..=w[3]).contains(&p[1]))
        };
        if let [p] = pins[..]
            && !marked(out, p)
            && !wired(p)
            && !out.noconn.contains(&p)
        {
            out.strays += 1;
            out.noconn.push(p);
        }
    }
    grow_bounds(out);
}

/// One net's axis-aligned segments without overlaps: each normalized so `(x1, y1) <
/// (x2, y2)` (the format's wire order), zero-length ones dropped, and collinear ones that
/// overlap cut at every original endpoint into disjoint pieces. Every original endpoint
/// stays an endpoint, so connectivity is unchanged (netlist spec §3: joining two pieces
/// through a junction would turn it into an interior crossing, which does not connect).
fn merged(mut segs: Vec<[i32; 4]>) -> Vec<[i32; 4]> {
    for s in &mut segs {
        if (s[2], s[3]) < (s[0], s[1]) {
            *s = [s[2], s[3], s[0], s[1]];
        }
    }
    segs.retain(|s| (s[0], s[1]) != (s[2], s[3]));
    // Per line (horizontal: y, vertical: x), intervals along it.
    let mut lines: Vec<(bool, i32, i32, i32)> = segs
        .iter()
        .map(|s| {
            if s[1] == s[3] {
                (false, s[1], s[0], s[2])
            } else {
                (true, s[0], s[1], s[3])
            }
        })
        .collect();
    lines.sort_unstable();
    let mut out: Vec<[i32; 4]> = Vec::with_capacity(segs.len());
    let mut k = 0;
    while k < lines.len() {
        let (vertical, at) = (lines[k].0, lines[k].1);
        let end = k + lines[k..]
            .iter()
            .take_while(|l| (l.0, l.1) == (vertical, at))
            .count();
        let mut cuts: Vec<i32> = lines[k..end].iter().flat_map(|l| [l.2, l.3]).collect();
        cuts.sort_unstable();
        cuts.dedup();
        // Sweep the union of the intervals; emit the pieces between consecutive cuts.
        let (mut lo, mut hi) = (lines[k].2, lines[k].3);
        for l in lines[k + 1..end]
            .iter()
            .map(|l| (l.2, l.3))
            .chain([(i32::MAX, i32::MAX)])
        {
            if l.0 <= hi && l.0 != i32::MAX {
                hi = hi.max(l.1);
                continue;
            }
            let inner: Vec<i32> = cuts
                .iter()
                .copied()
                .filter(|&c| c >= lo && c <= hi)
                .collect();
            for w in inner.windows(2) {
                out.push(if vertical {
                    [at, w[0], at, w[1]]
                } else {
                    [w[0], at, w[1], at]
                });
            }
            (lo, hi) = l;
        }
        k = end;
    }
    assert!(
        out.iter()
            .all(|s| (s[0], s[1]) < (s[2], s[3]) && (s[0] == s[2] || s[1] == s[3]))
    );
    out
}

/// Where to write a net's name on its wires `wires[mine]`: the middle of one of its
/// longest segments that no other net's wire passes through (a name there would join that
/// wire too). `None` when every candidate tried is crossed.
///
/// Cost: O(candidates × wires), at most four candidates.
fn spot(wires: &[[i32; 4]], mine: std::ops::Range<usize>) -> Option<[i32; 2]> {
    let mut order: Vec<usize> = mine.clone().collect();
    order.sort_by_key(|&i| {
        (
            std::cmp::Reverse((wires[i][2] - wires[i][0]) + (wires[i][3] - wires[i][1])),
            i,
        )
    });
    let on =
        |p: [i32; 2], w: &[i32; 4]| (w[0]..=w[2]).contains(&p[0]) && (w[1]..=w[3]).contains(&p[1]);
    let found = order
        .into_iter()
        .take(4)
        .map(|i| {
            let w = wires[i];
            [(w[0] + w[2]).div_euclid(2), (w[1] + w[3]).div_euclid(2)]
        })
        .find(|&m| {
            wires
                .iter()
                .enumerate()
                .all(|(j, w)| mine.contains(&j) || !on(m, w))
        });
    assert!(found.is_none_or(|m| wires[mine].iter().any(|w| on(m, w))));
    found
}

/// Whether one tree of `polys` connects every point of `pins` (union-find over the pins
/// and polylines; a pin or a polyline end on another polyline joins it).
fn wired(pins: &[[i32; 2]], polys: &[&[[i32; 2]]]) -> bool {
    let on = |p: [i32; 2], poly: &[[i32; 2]]| {
        poly.windows(2).any(|s| {
            let (a, b) = (s[0], s[1]);
            (a[0].min(b[0])..=a[0].max(b[0])).contains(&p[0])
                && (a[1].min(b[1])..=a[1].max(b[1])).contains(&p[1])
        })
    };
    // Nodes: pins, then polylines.
    let mut parent: Vec<usize> = (0..pins.len() + polys.len()).collect();
    fn root(parent: &mut [usize], mut i: usize) -> usize {
        while parent[i] != i {
            parent[i] = parent[parent[i]];
            i = parent[i];
        }
        i
    }
    let join = |parent: &mut Vec<usize>, a: usize, b: usize| {
        let (ra, rb) = (root(parent, a), root(parent, b));
        parent[ra] = rb;
    };
    for (j, poly) in polys.iter().enumerate() {
        for (i, &p) in pins.iter().enumerate() {
            if on(p, poly) {
                join(&mut parent, i, pins.len() + j);
            }
        }
        for (k, other) in polys.iter().enumerate().skip(j + 1) {
            let touch = [poly[0], poly[poly.len() - 1]]
                .iter()
                .any(|&p| on(p, other))
                || [other[0], other[other.len() - 1]]
                    .iter()
                    .any(|&p| on(p, poly));
            if touch {
                join(&mut parent, pins.len() + j, pins.len() + k);
            }
        }
    }
    let r0 = root(&mut parent, 0);
    (1..pins.len()).all(|i| root(&mut parent, i) == r0)
}

/// Gives every net the cell needs by name a marker (a label on its first pin, `first[n]`,
/// for a net nothing named yet; a port off the drawing for a port net with no pin), then
/// turns the first marker of each port net into its `port`. A net is needed by name when
/// it is a port, a global (`.global`, `…!`, `0`), on a pin of a generated leaf (which
/// re-emits its card's node names as text) or a word of the cell's card or code text
/// (`v(a1)` in a `B` expression, `.save v(out)`); any other lone pin keeps cktImg's cross.
fn name_nets(
    out: &mut Drawn,
    deck: &Deck,
    rec: &Recognized,
    c: usize,
    first: &[Option<([i32; 2], u8)>],
) {
    let words = text_words(deck, c);
    let ports = deck.ports(c);
    let mut on_leaf = vec![false; deck.net_count(c)];
    for d in deck.devs(c) {
        if rec.syms.origin[rec.parts.sym[d] as usize] == Origin::Leaf {
            for &n in deck.nets_of(d) {
                on_leaf[n as usize] = true;
            }
        }
    }
    let needs = |n: u32| {
        let key = deck.net_key(c, n);
        (c > 0 && ports.contains(&n))
            || key == "0"
            || key.ends_with('!')
            || deck.globals.iter().any(|g| g == key)
            || on_leaf[n as usize]
            || words.binary_search_by(|w| w.as_str().cmp(key)).is_ok()
    };
    for (n, p) in first.iter().enumerate() {
        let n = n as u32;
        if let Some((p, face)) = p
            && !out.has_mark(n)
            && needs(n)
        {
            out.mark(*p, n, *face);
        }
    }
    if c == 0 {
        return;
    }
    let mut free_y = out.bounds[1];
    for &n in ports {
        match out.mark_net.iter().position(|&m| m == n) {
            Some(m) => {
                out.mark_port[m] = true;
                out.mark_orient[m] = (out.mark_orient[m] + 2) % 4;
            }
            None => {
                // No device on the net: a port left of the drawing, clear of every wire.
                let x = out.bounds[0] - 2 * UNIT;
                out.mark([x, free_y], n, 2);
                *out.mark_port.last_mut().expect("just marked") = true;
                free_y += UNIT;
            }
        }
    }
    assert!(ports.iter().all(|&n| {
        out.mark_net
            .iter()
            .zip(&out.mark_port)
            .any(|(&m, &p)| m == n && p)
    }));
}

/// Lowercase words of cell `c`'s code text and card text after the nodes, sorted (the
/// net names they may mention, e.g. `v(out)`).
fn text_words(deck: &Deck, c: usize) -> Vec<String> {
    let code = (0..deck.code.len())
        .filter(|&k| deck.code_cell[k] as usize == c)
        .map(|k| &deck.code[k]);
    let cards = deck.devs(c).map(|d| &deck.dev_rest[d]);
    let mut words: Vec<String> = code
        .chain(cards)
        .flat_map(|t| {
            t.split(|ch: char| ch.is_whitespace() || "(),='\"{}".contains(ch))
                .filter(|w| !w.is_empty())
                .map(str::to_ascii_lowercase)
                .collect::<Vec<_>>()
        })
        .collect();
    words.sort_unstable();
    words.dedup();
    words
}

/// The fallback drawing: devices in rows in deck order, unrotated, each symbol's body clear
/// of the others' (so no two pins share a point), every pin labelled with its net (labels
/// with equal names connect, so this is always correct; a node-less stub's placeholder
/// pin is no-connected).
fn labelled(out: &mut Drawn, deck: &Deck, rec: &Recognized, c: usize) {
    let syms = &rec.syms;
    let row_width = 24 * UNIT;
    let (mut x, mut y, mut row_height) = (0i32, 0i32, 0i32);
    for d in deck.devs(c) {
        let s = rec.parts.sym[d] as usize;
        let b = syms.body[s];
        assert!(b[0] <= b[2] && b[1] <= b[3]);
        if x > 0 && x + (b[2] - b[0]) > row_width {
            (x, y, row_height) = (0, y + row_height + UNIT, 0);
        }
        // The body's top-left corner at the cursor.
        let (ox, oy) = (x - b[0], y - b[1]);
        out.x.push(ox);
        out.y.push(oy);
        out.orient.push(0);
        for (k, pin) in syms.pins(s).enumerate() {
            let p = [ox + syms.pin_x[pin], oy + syms.pin_y[pin]];
            match deck.nets_of(d).get(k) {
                Some(&net) => out.mark(p, net, facing(0, syms.pin_x[pin], syms.pin_y[pin])),
                // A node-less stub's placeholder pin.
                None => out.noconn.push(p),
            }
        }
        x += b[2] - b[0] + UNIT;
        row_height = row_height.max(b[3] - b[1]);
    }
    // Nets of two or more pins, all joined by name here (the layout report's denominator).
    let mut pins = vec![0u32; deck.net_count(c)];
    for d in deck.devs(c) {
        for &n in deck.nets_of(d) {
            pins[n as usize] += 1;
        }
    }
    out.nets_multi += pins.iter().filter(|&&k| k >= 2).count() as u32;
    grow_bounds(out);
    name_nets(out, deck, rec, c, &vec![None; deck.net_count(c)]);
    grow_bounds(out);
    assert_eq!(out.x.len(), deck.devs(c).len());
}

/// Grows `out.bounds` over every instance origin, wire end and marker.
fn grow_bounds(out: &mut Drawn) {
    let pts = out
        .x
        .iter()
        .zip(&out.y)
        .map(|(&x, &y)| [x, y])
        .chain(out.wire.iter().flat_map(|w| [[w[0], w[1]], [w[2], w[3]]]))
        .chain(out.mark_x.iter().zip(&out.mark_y).map(|(&x, &y)| [x, y]))
        .chain(out.noconn.iter().copied());
    let mut b = out.bounds;
    let mut empty = b == [0; 4];
    for p in pts {
        if empty {
            b = [p[0], p[1], p[0], p[1]];
            empty = false;
        }
        b = [
            b[0].min(p[0]),
            b[1].min(p[1]),
            b[2].max(p[0]),
            b[3].max(p[1]),
        ];
    }
    assert!(b[0] <= b[2] && b[1] <= b[3]);
    out.bounds = b;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compose_applies_the_right_operand_first() {
        for a in 0..8 {
            for b in 0..8 {
                let o = compose(a, b);
                for p in [(1, 0), (0, 1), (3, -7)] {
                    let q = xform(b, p.0, p.1);
                    assert_eq!(xform(o, p.0, p.1), xform(a, q.0, q.1), "{a} after {b}");
                }
            }
        }
        // R90 then MR0 is MR270 (a reflection across the diagonal); R0 is neutral.
        assert_eq!(compose(4, 1), 7);
        assert_eq!(
            (0..8).map(|o| compose(o, 0)).collect::<Vec<_>>(),
            (0..8).collect::<Vec<_>>()
        );
    }

    #[test]
    fn labels_face_away_from_their_symbol() {
        // nmos4 bulk (20, 0): text to the right at R0, to the left when mirrored, down at R90.
        assert_eq!(facing(0, 20, 0), 0);
        assert_eq!(facing(4, 20, 0), 2);
        assert_eq!(facing(1, 20, 0), 1);
        // res p (0, -30): text up at R0 (orientation R270 runs +x upwards).
        assert_eq!(facing(0, 0, -30), 3);
        assert_eq!(
            facing(0, 0, 0),
            0,
            "a pin at the origin reads left to right"
        );
    }

    #[test]
    fn canonical_turn_puts_core_two_pins_on_the_x_axis() {
        // res p (0,-30) → (30,0), n (0,30) → (-30,0): one UNIT apart on the x axis.
        assert_eq!(xform(to_canonical(Family::Two), 0, -30), (30, 0));
        assert_eq!(xform(to_canonical(Family::Two), 0, 30), (-30, 0));
        // nmos4: drain right, gate up, source left (cktImg's MOS frame), bulk below.
        let t = to_canonical(Family::Nmos);
        assert_eq!(
            [
                xform(t, 20, -30),
                xform(t, -20, 0),
                xform(t, 20, 30),
                xform(t, 20, 0)
            ],
            [(30, 20), (0, -20), (-30, 20), (0, 20)]
        );
    }

    #[test]
    fn merged_cuts_overlaps_at_every_endpoint() {
        let w = merged(vec![
            [30, 0, 0, 0],   // reversed
            [10, 0, 60, 0],  // overlaps it
            [60, 0, 90, 0],  // touches it: stays a separate piece
            [10, 0, 60, 0],  // a duplicate
            [0, 10, 0, -20], // vertical through the start
            [5, 5, 5, 5],    // zero length
            [0, 40, 0, 50],  // a gap on the same vertical line
        ]);
        assert_eq!(
            w,
            [
                [0, 0, 10, 0],
                [10, 0, 30, 0],
                [30, 0, 60, 0],
                [60, 0, 90, 0],
                [0, -20, 0, 10],
                [0, 40, 0, 50]
            ]
        );
        assert!(merged(Vec::new()).is_empty());
    }

    #[test]
    fn net_names_keep_readable_names_and_fold_ground() {
        let d = crate::spice::parse("R1 a gnd 1\nR2 a(1) b 1\nR3 b 0 1\n");
        let names = net_names(&d, 0);
        let by = |k: &str| {
            names[(0..d.net_count(0) as u32)
                .find(|&n| d.net_key(0, n) == k)
                .unwrap() as usize]
                .clone()
        };
        assert_eq!(by("a"), "a");
        assert_eq!(by("0"), "0");
        assert!(
            by("gnd").starts_with("n2s_"),
            "gnd must not merge with 0 here"
        );
        assert!(by("a(1)").starts_with("n2s_"));
        let d = crate::spice::parse("R1 a gnd 1\n");
        assert!(
            net_names(&d, 0).contains(&"0".to_owned()),
            "a lone gnd is ground"
        );
    }
}
