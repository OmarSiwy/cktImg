//! Recognize transform: [`Deck`] devices → symbols (bundled `core` cells, generated
//! subckt cells, generated leaf cells) and per-instance parameter overrides.
//!
//! A card maps onto its `core` cell only when the core template re-emits it
//! faithfully: the core templates always print some parameters (`m=`, a diode's `area=`,
//! a MOSFET's `w=`/`l=`), so a card that omits them would change meaning. Every other
//! card becomes an instance of a generated *leaf* (`spice_<kind>.shprim`, template
//! `{name} {pins} {args}`) that re-emits the card text verbatim. `X` cards call the
//! generated cell of a subckt in the file, or a generated stub leaf named after an
//! undefined subckt.

use crate::spice::{Deck, Dir, Side, Tok, Xspice, key_of, tokenize, xspice};

/// Symbols per conversion (core rows + generated cells).
pub const SYMBOLS_MAX: usize = 8192;

/// Geometry family: pin layout and body of a symbol (local xschem units, y down).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Family {
    /// Two pins `p` (0,-30) / `n` (0,30).
    Two,
    /// MOSFET `d g s b`, n-channel drawing.
    Nmos,
    /// MOSFET `d g s b`, p-channel drawing (drain at the bottom).
    Pmos,
    /// Three-terminal `c b e` (also JFET/MESFET `d g s`), npn drawing.
    Npn,
    /// Three-terminal, pnp drawing (collector at the bottom).
    Pnp,
    /// Controlled source `p n cp cn`.
    Vcxs,
    /// Voltage switch `p n cp cn`.
    Vsw,
    /// Four-port line `p1 n1 p2 n2`.
    Tline,
    /// Generated box: pins on the sides `*@` directives name, else inputs left and the
    /// rest right (subckt cells, stubs, XSPICE and other leaves).
    Box,
}

/// How a symbol is written out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    /// A bundled `core` cell; nothing to write.
    Core,
    /// The generated `.shcomp` of deck cell `c`.
    Sub(u16),
    /// A generated `.shprim` leaf re-emitting card text (`spice_<kind>` or a stub).
    Leaf,
}

/// Symbol table: one row per distinct cell instances refer to. Pins are CSR
/// (`pin_start`, rows + 1) in SPICE order. Owner: this module; read by place/route/emit.
#[derive(Debug, Default)]
pub struct Symbols {
    /// Cell stem (`res`, `inv`, `spice_d2`); unique among generated cells,
    /// case-insensitively.
    pub stem: Vec<String>,
    /// Where the cell comes from.
    pub origin: Vec<Origin>,
    /// Geometry family (drawing and pin roles).
    pub family: Vec<Family>,
    /// Default of the leaf `args` parameter (stub leaves: the subckt name).
    pub args_default: Vec<String>,
    /// A leaf's SPICE template when not the default `{name} {pins} {args}` (`""`): an
    /// XSPICE card's own port shape, or `{name} {args}` for a node-less `X` (its one pin
    /// is a placeholder the card never prints).
    pub format: Vec<String>,
    /// Local body rectangle `[x0, y0, x1, y1]`, closed, pins on its boundary.
    pub body: Vec<[i32; 4]>,
    /// CSR into the pin columns.
    pub pin_start: Vec<u32>,
    /// Pin names.
    pub pin_name: Vec<String>,
    /// Pin offsets, multiples of 10.
    pub pin_x: Vec<i32>,
    /// Pin offsets, multiples of 10.
    pub pin_y: Vec<i32>,
    /// Pin direction (symbol interface; control pins are `In`).
    pub pin_dir: Vec<Dir>,
}

impl Symbols {
    /// Pin rows of symbol `s`.
    pub fn pins(&self, s: usize) -> std::ops::Range<usize> {
        self.pin_start[s] as usize..self.pin_start[s + 1] as usize
    }

    /// Cell reference written in `inst` records.
    pub fn cellref(&self, s: usize) -> String {
        match self.origin[s] {
            Origin::Core => format!("core:{}", self.stem[s]),
            _ => format!("./{}", self.stem[s]),
        }
    }

    /// Appends a symbol; a [`Family::Box`] passes its body (from [`box_layout`]), the
    /// other families' bodies follow from their pins.
    fn push(
        &mut self,
        stem: String,
        origin: Origin,
        family: Family,
        pins: &[(String, i32, i32, Dir)],
        box_body: Option<[i32; 4]>,
    ) -> u32 {
        assert!(self.stem.len() < SYMBOLS_MAX, "symbol table full");
        assert!(
            pins.iter().all(|p| p.1 % 10 == 0 && p.2 % 10 == 0),
            "pins on the 10 grid"
        );
        assert_eq!(family == Family::Box, box_body.is_some());
        if self.pin_start.is_empty() {
            self.pin_start.push(0);
        }
        let mut body = [0i32; 4];
        for (i, p) in pins.iter().enumerate() {
            if i == 0 {
                body = [p.1, p.2, p.1, p.2];
            }
            body = [
                body[0].min(p.1),
                body[1].min(p.2),
                body[2].max(p.1),
                body[3].max(p.2),
            ];
        }
        match family {
            // The core two-pin bodies (circles, plates) reach x = ±20.
            Family::Two => body = [-20, -30, 20, 30],
            Family::Vcxs | Family::Vsw => body[2] = 20,
            Family::Tline => body = [-80, -20, 80, 20],
            Family::Box => body = box_body.expect("asserted above"),
            _ => {}
        }
        for (name, x, y, dir) in pins {
            self.pin_name.push(name.clone());
            self.pin_x.push(*x);
            self.pin_y.push(*y);
            self.pin_dir.push(*dir);
        }
        self.pin_start.push(self.pin_name.len() as u32);
        self.stem.push(stem);
        self.origin.push(origin);
        self.family.push(family);
        self.args_default.push(String::new());
        self.format.push(String::new());
        self.body.push(body);
        (self.stem.len() - 1) as u32
    }
}

/// Per-device recognition result (rows parallel to the deck's devices).
#[derive(Debug, Default)]
pub struct Parts {
    /// Symbol row.
    pub sym: Vec<u32>,
    /// The instance's `name` attribute.
    pub inst_name: Vec<String>,
    /// CSR into the override columns.
    pub over_start: Vec<u32>,
    /// Overridden parameter names.
    pub over_key: Vec<String>,
    /// Override values: expressions for number params, templates for string params.
    pub over_val: Vec<String>,
}

impl Parts {
    /// Override rows of device `d`.
    pub fn overrides(&self, d: usize) -> std::ops::Range<usize> {
        self.over_start[d] as usize..self.over_start[d + 1] as usize
    }
}

/// Core cells this importer places, with their SPICE-order pins (offsets from
/// `lib/core/*.shprim`; `tests/core_geometry.rs` checks them against the files).
/// A pin table row: name, x, y, direction.
type PinRow = (&'static str, i32, i32, Dir);

const CORE: &[(&str, Family, &[PinRow])] = &[
    ("res", Family::Two, TWO),
    ("cap", Family::Two, TWO),
    ("ind", Family::Two, TWO),
    ("diode", Family::Two, TWO),
    ("vsource", Family::Two, TWO),
    ("isource", Family::Two, TWO),
    ("cccs", Family::Two, TWO),
    ("ccvs", Family::Two, TWO),
    ("switch", Family::Two, TWO),
    ("nmos4", Family::Nmos, NMOS),
    ("pmos4", Family::Pmos, PMOS),
    ("npn", Family::Npn, NPN),
    ("pnp", Family::Pnp, PNP),
    ("vcvs", Family::Vcxs, VCXS),
    ("vccs", Family::Vcxs, VCXS),
    ("vswitch", Family::Vsw, VSW),
    ("tline", Family::Tline, TLINE),
];

use Dir::{In, Inout};
const TWO: &[PinRow] = &[("p", 0, -30, Inout), ("n", 0, 30, Inout)];
const NMOS: &[PinRow] = &[
    ("d", 20, -30, Inout),
    ("g", -20, 0, In),
    ("s", 20, 30, Inout),
    ("b", 20, 0, In),
];
const PMOS: &[PinRow] = &[
    ("d", 20, 30, Inout),
    ("g", -20, 0, In),
    ("s", 20, -30, Inout),
    ("b", 20, 0, In),
];
const NPN: &[PinRow] = &[
    ("c", 20, -30, Inout),
    ("b", -20, 0, In),
    ("e", 20, 30, Inout),
];
const PNP: &[PinRow] = &[
    ("c", 20, 30, Inout),
    ("b", -20, 0, In),
    ("e", 20, -30, Inout),
];
const VCXS: &[PinRow] = &[
    ("p", 0, -30, Inout),
    ("n", 0, 30, Inout),
    ("cp", -40, -20, In),
    ("cn", -40, 20, In),
];
const VSW: &[PinRow] = &[
    ("p", 0, -30, Inout),
    ("n", 0, 30, Inout),
    ("cp", -40, 0, In),
    ("cn", -40, 20, In),
];
const TLINE: &[PinRow] = &[
    ("p1", -80, -10, Inout),
    ("n1", -80, 10, Inout),
    ("p2", 80, -10, Inout),
    ("n2", 80, 10, Inout),
];

/// Symbol row of the generated cell of deck subckt `c` (≥ 1).
pub fn sub_symbol(c: usize) -> usize {
    assert!(c >= 1, "the top level has no symbol");
    CORE.len() + c - 1
}

/// Core cell names and pin tables, for the geometry cross-check test.
pub fn core_table() -> impl Iterator<Item = (&'static str, Vec<(&'static str, i32, i32)>)> {
    CORE.iter()
        .map(|(n, _, pins)| (*n, pins.iter().map(|p| (p.0, p.1, p.2)).collect()))
}

/// Recognition output: the symbol table and one [`Parts`] row per deck device.
#[derive(Debug, Default)]
pub struct Recognized {
    /// Symbols, core rows first (row `i` = `CORE[i]`), then subckt cells in deck order
    /// (row `CORE.len() + c - 1` for cell `c`), then leaves in first-use order.
    pub syms: Symbols,
    /// Per device.
    pub parts: Parts,
    /// Notes for the import log.
    pub warnings: Vec<String>,
    /// The `spice_code` leaf (one pin, template `{text}`) that carries a subckt's code
    /// text inside its definition; `u32::MAX` when no subckt has code.
    pub code_sym: u32,
}

/// Recognizes every device of `deck`. Never fails: an unmappable card becomes a leaf
/// instance that re-emits it verbatim.
///
/// Cost: O(devices × card length) plus O(log symbols) per leaf lookup.
pub fn recognize(deck: &Deck) -> Recognized {
    let mut r = Recognized::default();
    let mut taken: Vec<String> = Vec::new();
    for (name, fam, pins) in CORE {
        let pins: Vec<_> = pins
            .iter()
            .map(|p| (p.0.to_owned(), p.1, p.2, p.3))
            .collect();
        r.syms
            .push((*name).to_owned(), Origin::Core, *fam, &pins, None);
    }
    for c in 1..deck.cells() {
        let stem = unique_stem(&deck.cell_name[c], &mut taken);
        let (pins, body) = box_pins(deck, c);
        r.syms
            .push(stem, Origin::Sub(c as u16), Family::Box, &pins, Some(body));
    }
    r.code_sym = u32::MAX;
    let has_params = (1..deck.cells()).any(|c| !deck.params(c).is_empty());
    if has_params || deck.code_cell.iter().any(|&c| c != 0) {
        let stem = unique_stem("spice_code", &mut taken);
        let (pins, body) = box_auto(&["p".to_owned()], &[Dir::Inout]);
        r.code_sym = r
            .syms
            .push(stem, Origin::Leaf, Family::Box, &pins, Some(body));
    }
    r.parts.over_start.push(0);
    for c in 0..deck.cells() {
        let params: Vec<&str> = deck
            .params(c)
            .map(|p| deck.param_name[p].as_str())
            .collect();
        let first = r.parts.inst_name.len();
        for d in deck.devs(c) {
            device(deck, d, &params, &mut r, &mut taken);
            r.parts.over_start.push(r.parts.over_key.len() as u32);
            // Instance names are unique per cell (E009): a repeated card name gets a suffix.
            let last = r.parts.inst_name.len() - 1;
            let taken_name = |n: &str, names: &[String]| {
                names[first..last].iter().any(|x| x.eq_ignore_ascii_case(n))
            };
            let name = r.parts.inst_name[last].clone();
            if taken_name(&name, &r.parts.inst_name) {
                let mut k = 2u32;
                while taken_name(&format!("{name}_{k}"), &r.parts.inst_name) {
                    k += 1;
                }
                r.warnings.push(format!(
                    "line {}: duplicate name {name} renamed {name}_{k}",
                    deck.dev_line[d]
                ));
                r.parts.inst_name[last] = format!("{name}_{k}");
            }
        }
    }
    assert_eq!(r.parts.sym.len(), deck.dev_name.len());
    assert_eq!(r.parts.over_start.len(), deck.dev_name.len() + 1);
    r
}

/// A symbol's pins (name, x, y, direction) and, for a box, its body.
type BoxPins = (Vec<(String, i32, i32, Dir)>, [i32; 4]);

/// Generated box of subckt cell `c`: each port on the side its `*@` directive names, in
/// directive order, else inputs left and the rest right, in port order.
fn box_pins(deck: &Deck, c: usize) -> BoxPins {
    let ports = deck.port_start[c] as usize..deck.port_start[c + 1] as usize;
    let dirs: Vec<Dir> = deck
        .ports(c)
        .iter()
        .map(|&n| port_dir(deck, c, n))
        .collect();
    let names: Vec<String> = deck
        .ports(c)
        .iter()
        .map(|&n| pin_name(deck.net_name(c, n)))
        .collect();
    box_layout(
        &names,
        &dirs,
        &deck.port_side[ports.clone()],
        &deck.port_rank[ports],
    )
}

/// [`box_layout`] with every pin on its default side (inputs left, the rest right).
fn box_auto(names: &[String], dirs: &[Dir]) -> BoxPins {
    box_layout(
        names,
        dirs,
        &vec![Side::Auto; names.len()],
        &vec![u16::MAX; names.len()],
    )
}

/// Box geometry for pins `names` (directions `dirs`) on sides `sides` (`Auto`: inputs
/// left, the rest right), ordered on each side by `ranks` then pin order (top to bottom,
/// left to right). Pins sit 20 apart, centred on the origin, side pins at x = ±xs and
/// top/bottom pins at y = ±ys; xs and ys put every pin on its own side by cktImg's rule
/// (the larger of |x| and |y| faces out) and clear of the other sides' pins. The body is
/// `[-xs, -ys, xs, ys]` (pins on its boundary, the drawn box 20 inside). Without
/// top/bottom pins and with at most six pins a side, the pins are where they always were
/// (x = ±60).
fn box_layout(names: &[String], dirs: &[Dir], sides: &[Side], ranks: &[u16]) -> BoxPins {
    let n = names.len();
    assert!(dirs.len() == n && sides.len() == n && ranks.len() == n);
    let side: Vec<Side> = (0..n)
        .map(|k| match (sides[k], dirs[k]) {
            (Side::Auto, Dir::In) => Side::Left,
            (Side::Auto, _) => Side::Right,
            (s, _) => s,
        })
        .collect();
    // Slot of each pin along its side, and pins per side (indexed by `Side as usize`).
    let mut slot = vec![0i32; n];
    let mut count = [0i32; 5];
    for s in [Side::Left, Side::Right, Side::Top, Side::Bottom] {
        let mut on: Vec<usize> = (0..n).filter(|&k| side[k] == s).collect();
        on.sort_by_key(|&k| (ranks[k], k));
        for (j, &k) in on.iter().enumerate() {
            slot[k] = j as i32;
        }
        count[s as usize] = on.len() as i32;
    }
    // Half the extent of `m` pins 20 apart.
    let half = |m: i32| (m - 1).max(0) * 10;
    let a = half(count[Side::Left as usize].max(count[Side::Right as usize]));
    let b = half(count[Side::Top as usize].max(count[Side::Bottom as usize]));
    let xs = 60.max(a + 10).max(b + 30);
    let ys = 40.max(a + 30).max(b + 10);
    let pins: Vec<(String, i32, i32, Dir)> = (0..n)
        .map(|k| {
            let along = slot[k] * 20 - half(count[side[k] as usize]);
            let (x, y) = match side[k] {
                Side::Left => (-xs, along),
                Side::Right => (xs, along),
                Side::Top => (along, -ys),
                Side::Bottom => (along, ys),
                Side::Auto => unreachable!("resolved above"),
            };
            (names[k].clone(), x, y, dirs[k])
        })
        .collect();
    assert!(
        pins.iter()
            .all(|p| (p.1.abs() == xs && p.2.abs() < xs) || (p.2.abs() == ys && p.1.abs() < ys))
    );
    (pins, [-xs, -ys, xs, ys])
}

/// Port direction: `*.PININFO`, else the net name (`in*`/`vin*` input, `out*`/`vout*`/
/// `vref*`/`vo` output), else inout.
pub fn port_dir(deck: &Deck, c: usize, n: u32) -> Dir {
    let key = deck.net_key(c, n);
    if let Some(d) = deck.pin_info(key) {
        return d;
    }
    if key.starts_with("in") || key.starts_with("vin") {
        Dir::In
    } else if key.starts_with("out")
        || key.starts_with("vout")
        || key.starts_with("vref")
        || key == "vo"
    {
        Dir::Out
    } else {
        Dir::Inout
    }
}

/// A net or pin name as a Schemify net expression: `,` `*` `:` would read as bundle,
/// repeat or bus range, so they become `_`.
pub fn pin_name(name: &str) -> String {
    name.replace([',', '*', ':'], "_")
}

/// A file stem from `name` (`[A-Za-z0-9_.-]`, others `_`), unique case-insensitively
/// against `taken` (suffix `_2`, `_3`, …), recorded in `taken`.
pub fn unique_stem(name: &str, taken: &mut Vec<String>) -> String {
    let base: String = name
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || "_.-".contains(ch) {
                ch
            } else {
                '_'
            }
        })
        .collect();
    let base = if base.is_empty() || base.starts_with('.') {
        format!("c{base}")
    } else {
        base
    };
    let mut stem = base.clone();
    let mut k = 2u32;
    while taken.iter().any(|t| t.eq_ignore_ascii_case(&stem)) {
        stem = format!("{base}_{k}");
        k += 1;
    }
    taken.push(stem.clone());
    stem
}

/// True for a number the expression language reads exactly: `digits[.digits][e±digits]`
/// with an optional SI suffix and nothing after (`10u`, `1.8`, `2meg`; not `1.8V`).
pub fn is_literal(s: &str) -> bool {
    let s = s.strip_prefix('-').unwrap_or(s).to_ascii_lowercase();
    let b = s.as_bytes();
    let mut i = 0;
    let digits = |i: &mut usize| {
        let start = *i;
        while *i < b.len() && b[*i].is_ascii_digit() {
            *i += 1;
        }
        *i > start
    };
    let int = digits(&mut i);
    if i < b.len() && b[i] == b'.' {
        i += 1;
        if !digits(&mut i) {
            return false;
        }
    } else if !int {
        return false;
    }
    if i < b.len()
        && b[i] == b'e'
        && b.get(i + 1)
            .is_some_and(|c| c.is_ascii_digit() || *c == b'+' || *c == b'-')
    {
        i += 1;
        if b[i] == b'+' || b[i] == b'-' {
            i += 1;
        }
        if !digits(&mut i) {
            return false;
        }
    }
    let suffix = &s[i..];
    ["", "f", "p", "n", "u", "m", "k", "meg", "g", "t", "mil"].contains(&suffix)
}

/// SPICE text → template text (expr §6): literal braces doubled; an identifier naming a
/// parameter of `params` (case-insensitive, not a `k=` key, not a function name, not a
/// node inside `v(…)`/`i(…)`) becomes a hole, wrapped `({k})` inside an expression and
/// `{{({k})}}` (a SPICE expression) when bare.
pub fn template(text: &str, params: &[&str]) -> String {
    template_in(text, params, 0)
}

/// [`template`] for a parameter value: the whole text is one expression (its outer
/// `{…}`/`'…'` already stripped by [`strip_outer`]), so holes are `({k})` throughout and
/// the value can later be spliced into another SPICE expression without nested braces.
pub fn template_expr(text: &str, params: &[&str]) -> String {
    template_in(text, params, 1)
}

fn template_in(text: &str, params: &[&str], depth0: u32) -> String {
    let mut out = String::with_capacity(text.len() + 8);
    let mut depth = depth0; // inside {…} or '…'
    let mut quote = false;
    let mut probe_depth: Option<u32> = None; // paren depth of an open v(…)/i(…)
    let mut paren = 0u32;
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let mut k = 0;
    while k < chars.len() {
        let (i, ch) = chars[k];
        let ident_start = (ch.is_ascii_alphabetic() || ch == '_')
            && (k == 0 || {
                let p = chars[k - 1].1;
                !(p.is_ascii_alphanumeric() || p == '_' || p == '.')
            });
        if ident_start {
            let mut e = k;
            while e < chars.len() && (chars[e].1.is_ascii_alphanumeric() || chars[e].1 == '_') {
                e += 1;
            }
            let end = chars.get(e).map_or(text.len(), |c| c.0);
            let word = &text[i..end];
            let next = text[end..].trim_start().chars().next();
            let is_key = next == Some('=') && !text[end..].trim_start().starts_with("==");
            let is_call = next == Some('(');
            let hit = params.iter().find(|p| p.eq_ignore_ascii_case(word));
            match hit {
                Some(p) if !is_key && !is_call && probe_depth.is_none() => {
                    if depth > 0 || quote {
                        out.push_str(&format!("({{{p}}})"));
                    } else {
                        out.push_str(&format!("{{{{({{{p}}})}}}}"));
                    }
                }
                _ => {
                    out.push_str(word);
                    if is_call && (word.eq_ignore_ascii_case("v") || word.eq_ignore_ascii_case("i"))
                    {
                        probe_depth = Some(paren);
                    }
                }
            }
            k = e;
            continue;
        }
        match ch {
            '{' => {
                depth += 1;
                out.push_str("{{");
            }
            '}' => {
                depth = depth.saturating_sub(1);
                out.push_str("}}");
            }
            '\'' => {
                quote = !quote;
                out.push(ch);
            }
            '(' => {
                paren += 1;
                out.push(ch);
            }
            ')' => {
                paren = paren.saturating_sub(1);
                if probe_depth == Some(paren) {
                    probe_depth = None;
                }
                out.push(ch);
            }
            _ => out.push(ch),
        }
        k += 1;
    }
    out
}

/// Strips one outer `{…}` or `'…'` from a parameter value (`{2*k}` → `2*k`).
pub fn strip_outer(v: &str) -> &str {
    let v = v.trim();
    let inner = v
        .strip_prefix('{')
        .and_then(|s| s.strip_suffix('}'))
        .or_else(|| v.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')));
    inner.unwrap_or(v)
}

/// Instance overrides being built for one device.
struct Over {
    keys: Vec<String>,
    vals: Vec<String>,
}

impl Over {
    /// A string parameter holding card text, verbatim (braces escaped). Parameter names
    /// in it stay SPICE names: each generated component re-declares its parameters with
    /// a `.param` line inside its definition (empty values are the default, skipped).
    fn text(&mut self, key: &str, v: &str) {
        if !v.is_empty() {
            self.keys.push(key.to_owned());
            self.vals.push(template(v, &[]));
        }
    }

    /// A number parameter with literal value `v`, stored only when it differs from the
    /// cell default (D40).
    fn number(&mut self, key: &str, v: &str, default: &str) {
        assert!(is_literal(v), "number overrides are literals");
        if !v.eq_ignore_ascii_case(default) {
            self.keys.push(key.to_owned());
            self.vals.push(v.to_owned());
        }
    }
}

/// `k=v` parameters of a tokenized rest: (lowercase key, value), or `None` if any token
/// is not `k=v`.
fn kv(toks: &[Tok]) -> Option<Vec<(String, String)>> {
    toks.iter()
        .map(|t| {
            let k = key_of(&t.text)?;
            Some((k.to_ascii_lowercase(), t.text[k.len() + 1..].to_owned()))
        })
        .collect()
}

/// Splits `model k=v…` into the model word and its parameters; `None` unless the rest
/// is exactly that.
fn model_and_params(toks: &[Tok]) -> Option<(&str, Vec<(String, String)>)> {
    let (m, p) = toks.split_first()?;
    let plain = key_of(&m.text).is_none() && !m.text.contains(['{', '\'', '(']);
    plain.then_some(())?;
    Some((m.text.as_str(), kv(p)?))
}

/// Recognizes device `d` (in a cell with parameters `params`) and appends its row.
fn device(deck: &Deck, d: usize, params: &[&str], r: &mut Recognized, taken: &mut Vec<String>) {
    let name = &deck.dev_name[d];
    let letter = name.as_bytes()[0].to_ascii_lowercase();
    let nodes = deck.nets_of(d).len();
    let rest = deck.dev_rest[d].as_str();
    let toks = tokenize(rest);
    let mut o = Over {
        keys: Vec::new(),
        vals: Vec::new(),
    };
    let core = |n: &str| CORE.iter().position(|c| c.0 == n).map(|i| i as u32);
    let model_kind = |m: &str| {
        let m = m.to_ascii_lowercase();
        deck.models.iter().find(|x| x.0 == m).map(|x| x.1.clone())
    };
    let mut inst_name = name.clone();
    let sym: Option<u32> = match (letter, nodes) {
        (b'r' | b'c' | b'l', 2) => {
            let m = toks
                .iter()
                .find(|t| key_of(&t.text).is_some_and(|k| k.eq_ignore_ascii_case("m")));
            let value: Vec<&str> = toks
                .iter()
                .filter(|t| !key_of(&t.text).is_some_and(|k| k.eq_ignore_ascii_case("m")))
                .map(|t| t.text.as_str())
                .collect();
            let m_ok = m.is_none_or(|t| is_literal(&t.text[2..]));
            (m_ok && !value.is_empty()).then(|| {
                o.text("value", &value.join(" "));
                if let Some(t) = m {
                    o.number("m", &t.text[2..], "1");
                }
            });
            let cell = [("res", b'r'), ("cap", b'c'), ("ind", b'l')]
                .iter()
                .find(|x| x.1 == letter)
                .map_or("res", |x| x.0);
            if o.keys.is_empty() { None } else { core(cell) }
        }
        (b'v' | b'i', 2) if !rest.is_empty() => {
            o.text("value", rest);
            core(if letter == b'v' { "vsource" } else { "isource" })
        }
        (b'd', 2) => match model_and_params(&toks) {
            Some((m, p)) if p.len() == 1 && p[0].0 == "area" && is_literal(&p[0].1) => {
                o.text("model", m);
                o.number("area", &p[0].1, "1");
                core("diode")
            }
            _ => None,
        },
        (b'q', 3) => match model_and_params(&toks) {
            Some((m, p))
                if p.iter().any(|x| x.0 == "area")
                    && p.iter()
                        .all(|x| (x.0 == "area" || x.0 == "m") && is_literal(&x.1)) =>
            {
                o.text("model", m);
                for (k, v) in &p {
                    o.number(k, v, "1");
                }
                core(if model_kind(m).is_some_and(|k| k == "pnp") {
                    "pnp"
                } else {
                    "npn"
                })
            }
            _ => None,
        },
        (b'm', 4) => match model_and_params(&toks) {
            Some((m, p))
                if has_literal(&p, "w")
                    && has_literal(&p, "l")
                    && p.iter().all(|x| x.0 != "m" || is_literal(&x.1)) =>
            {
                o.text("model", m);
                let mut extra: Vec<String> = Vec::new();
                for (k, v) in &p {
                    match k.as_str() {
                        "w" => o.number("w", v, "1u"),
                        "l" => o.number("l", v, "0.18u"),
                        "m" => o.number("m", v, "1"),
                        _ => extra.push(format!("{k}={v}")),
                    }
                }
                o.text("extra", &extra.join(" "));
                core(if is_pmos(m, model_kind(m)) {
                    "pmos4"
                } else {
                    "nmos4"
                })
            }
            _ => None,
        },
        (b'e' | b'g', 4) if toks.len() == 1 => {
            o.text("value", rest);
            core(if letter == b'e' { "vcvs" } else { "vccs" })
        }
        (b'f' | b'h', 2) if toks.len() == 2 && key_of(&toks[0].text).is_none() => {
            o.text("vnam", &toks[0].text);
            o.text("value", &toks[1].text);
            core(if letter == b'f' { "cccs" } else { "ccvs" })
        }
        (b'w', 2) if toks.len() == 2 && toks.iter().all(|t| key_of(&t.text).is_none()) => {
            o.text("vnam", &toks[0].text);
            o.text("model", &toks[1].text);
            core("switch")
        }
        (b's', 4) if toks.len() == 1 && key_of(&toks[0].text).is_none() => {
            o.text("model", &toks[0].text);
            core("vswitch")
        }
        (b't', 4) => match kv(&toks) {
            Some(p) if p.len() == 2 && has_literal(&p, "z0") && has_literal(&p, "td") => {
                for (k, v) in &p {
                    o.number(k, v, if k == "z0" { "50" } else { "10n" });
                }
                core("tline")
            }
            _ => None,
        },
        (b'a', _) => {
            let x = xspice(rest).expect("the parser keeps only A cards it can split");
            o.text("args", &rest[x.model..]);
            let format = if x.plain {
                String::new()
            } else {
                xspice_format(rest, &x)
            };
            Some(xspice_leaf(nodes, &format, r, taken))
        }
        (b'x', _) => match deck.find_cell(&deck.dev_sub[d]) {
            Some(c) if deck.ports(c).len() == nodes => {
                let callee: Vec<&str> = deck
                    .params(c)
                    .map(|p| deck.param_name[p].as_str())
                    .collect();
                for t in toks
                    .iter()
                    .filter(|t| !t.text.eq_ignore_ascii_case("params:"))
                {
                    let hit = key_of(&t.text).and_then(|k| {
                        callee
                            .iter()
                            .find(|p| p.eq_ignore_ascii_case(k))
                            .map(|p| (k, *p))
                    });
                    match hit {
                        Some((k, p)) => {
                            o.keys.push(p.to_owned());
                            o.vals
                                .push(template_expr(strip_outer(&t.text[k.len() + 1..]), params));
                        }
                        None => r.warnings.push(format!(
                            "line {}: {name}: `{}` is no parameter of {}; dropped",
                            deck.dev_line[d], t.text, deck.dev_sub[d]
                        )),
                    }
                }
                if name.len() > 1 && name.as_bytes()[0].eq_ignore_ascii_case(&b'x') {
                    inst_name = name[1..].to_owned();
                }
                Some((CORE.len() + c - 1) as u32)
            }
            Some(_) => {
                r.warnings.push(format!(
                    "line {}: {name}: node count differs from .subckt {}; kept verbatim",
                    deck.dev_line[d], deck.dev_sub[d]
                ));
                None
            }
            None => {
                let s = stub(deck, d, r, taken);
                if !rest.is_empty() {
                    o.text("args", &format!("{} {rest}", deck.dev_sub[d]));
                }
                Some(s)
            }
        },
        _ => None,
    };
    let sym = sym.unwrap_or_else(|| {
        o.keys.clear();
        o.vals.clear();
        let text = if letter == b'x' {
            format!("{} {rest}", deck.dev_sub[d])
        } else {
            rest.to_owned()
        };
        o.text("args", text.trim_end());
        leaf(letter, nodes, &toks, deck, r, taken)
    });
    assert_eq!(o.keys.len(), o.vals.len());
    r.parts.over_key.append(&mut o.keys);
    r.parts.over_val.append(&mut o.vals);
    r.parts.sym.push(sym);
    r.parts.inst_name.push(inst_name);
}

/// True if `p` holds key `k` with a literal value.
fn has_literal(p: &[(String, String)], k: &str) -> bool {
    p.iter().any(|x| x.0 == k && is_literal(&x.1))
}

/// P-channel by `.model` type, else by the model name (`p…`, `…pmos…`, `…pfet…`, `…pch…`).
fn is_pmos(model: &str, kind: Option<String>) -> bool {
    match kind {
        Some(k) => k.starts_with('p'),
        None => {
            let m = model.to_ascii_lowercase();
            m.starts_with('p') || ["pmos", "pfet", "pch"].iter().any(|s| m.contains(s))
        }
    }
}

/// The generated leaf for a card core cells cannot re-emit, keyed by drawing family and
/// pin count (`spice_nmos4`, `spice_diode`, `spice_e2`, …), created on first use.
fn leaf(
    letter: u8,
    nodes: usize,
    toks: &[Tok],
    deck: &Deck,
    r: &mut Recognized,
    taken: &mut Vec<String>,
) -> u32 {
    let model = toks.first().map(|t| t.text.as_str()).unwrap_or("");
    let kind = {
        let m = model.to_ascii_lowercase();
        deck.models.iter().find(|x| x.0 == m).map(|x| x.1.clone())
    };
    let (key, fam, pins): (String, Family, &[PinRow]) = match (letter, nodes) {
        (b'd', 2) => ("diode".into(), Family::Two, TWO),
        (b'm', 4) if is_pmos(model, kind.clone()) => ("pmos4".into(), Family::Pmos, PMOS),
        (b'm', 4) => ("nmos4".into(), Family::Nmos, NMOS),
        (b'q', 3) if kind.as_deref() == Some("pnp") => ("pnp".into(), Family::Pnp, PNP),
        (b'q', 3) => ("npn".into(), Family::Npn, NPN),
        (b'j' | b'z', 3) => (format!("{}3", letter as char), Family::Npn, NPN),
        (b'e' | b'g', 4) => (format!("{}4", letter as char), Family::Vcxs, VCXS),
        (b's', 4) => ("s4".into(), Family::Vsw, VSW),
        (b't' | b'o', 4) => (format!("{}4", letter as char), Family::Tline, TLINE),
        (_, 2) => (format!("{}2", letter as char), Family::Two, TWO),
        _ => (format!("{}{nodes}", letter as char), Family::Box, &[]),
    };
    let want = format!("spice_{key}");
    if let Some(s) =
        (0..r.syms.stem.len()).find(|&s| r.syms.origin[s] == Origin::Leaf && r.syms.stem[s] == want)
    {
        return s as u32;
    }
    let stem = unique_stem(&want, taken);
    if fam != Family::Box {
        let pins: Vec<(String, i32, i32, Dir)> = pins
            .iter()
            .map(|p| (p.0.to_owned(), p.1, p.2, p.3))
            .collect();
        return r.syms.push(stem, Origin::Leaf, fam, &pins, None);
    }
    let (names, format) = leaf_pins(nodes);
    let (pins, body) = box_auto(&names, &vec![Dir::Inout; names.len()]);
    let s = r.syms.push(stem, Origin::Leaf, fam, &pins, Some(body));
    r.syms.format[s as usize] = format.to_owned();
    s
}

/// Pin names of a generated box leaf for a card of `nodes` nodes (`p1…pN`) and its
/// template when not the default. A node-less card gets one placeholder pin `p` (a
/// `.shprim` needs a pin; the layout no-connects it) that `{name} {args}` never prints.
fn leaf_pins(nodes: usize) -> (Vec<String>, &'static str) {
    if nodes == 0 {
        return (vec!["p".to_owned()], "{name} {args}");
    }
    ((1..=nodes).map(|i| format!("p{i}")).collect(), "")
}

/// The leaf for XSPICE `A` cards of `nodes` nodes whose port shape needs template
/// `format` (`""`: plain nodes, the default `{name} {pins} {args}`): a box with every
/// node but the last an input. A shaped leaf's stem carries a hash of its template
/// (`spice_a3_1f2e3d4c`), since leaves are shared by every import into a directory.
fn xspice_leaf(nodes: usize, format: &str, r: &mut Recognized, taken: &mut Vec<String>) -> u32 {
    assert!(nodes >= 1, "the parser keeps node-less A cards as code");
    let want = if format.is_empty() {
        format!("spice_a{nodes}")
    } else {
        let h = format.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| {
            (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
        });
        format!("spice_a{nodes}_{:08x}", h as u32)
    };
    let found = (0..r.syms.stem.len()).find(|&s| {
        r.syms.origin[s] == Origin::Leaf && r.syms.stem[s] == want && r.syms.format[s] == format
    });
    if let Some(s) = found {
        return s as u32;
    }
    let stem = unique_stem(&want, taken);
    let names: Vec<String> = (1..=nodes).map(|i| format!("p{i}")).collect();
    let dirs: Vec<Dir> = (1..=nodes)
        .map(|i| if i < nodes { Dir::In } else { Dir::Out })
        .collect();
    let (pins, body) = box_auto(&names, &dirs);
    let s = r
        .syms
        .push(stem, Origin::Leaf, Family::Box, &pins, Some(body));
    r.syms.format[s as usize] = format.to_owned();
    s
}

/// The template of an XSPICE card `rest` (text after its name, split as `x`) whose port
/// shape `{pins}` cannot print: the text before the model with each node a hole
/// `{p<k>}` and literal braces doubled, between `{name}` and `{args}` (the model on).
fn xspice_format(rest: &str, x: &Xspice) -> String {
    assert!(!x.plain && x.model <= rest.len());
    let mut f = String::from("{name} ");
    let mut at = 0;
    for (k, r) in x.nodes.iter().enumerate() {
        f.push_str(&template(&rest[at..r.start], &[]));
        f.push_str(&format!("{{p{}}}", k + 1));
        at = r.end;
    }
    f.push_str(&template(&rest[at..x.model], &[]));
    f.push_str("{args}");
    f
}

/// The stub leaf for `X` calls of undefined subckt `deck.dev_sub[d]` (one per name and
/// node count): pins `p1…pN` (a node-less call: see [`leaf_pins`]), `args` defaulting to
/// the subckt name.
fn stub(deck: &Deck, d: usize, r: &mut Recognized, taken: &mut Vec<String>) -> u32 {
    let sub = &deck.dev_sub[d];
    let (names, format) = leaf_pins(deck.nets_of(d).len());
    let found = (0..r.syms.stem.len()).find(|&s| {
        r.syms.origin[s] == Origin::Leaf
            && r.syms.args_default[s].eq_ignore_ascii_case(sub)
            && r.syms.pins(s).len() == names.len()
            && r.syms.format[s] == format
    });
    if let Some(s) = found {
        return s as u32;
    }
    let stem = unique_stem(sub, taken);
    let (pins, body) = box_auto(&names, &vec![Dir::Inout; names.len()]);
    let s = r
        .syms
        .push(stem, Origin::Leaf, Family::Box, &pins, Some(body));
    r.syms.args_default[s as usize] = sub.clone();
    r.syms.format[s as usize] = format.to_owned();
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spice::parse;

    #[test]
    fn box_pins_take_their_directive_sides_and_face_them() {
        let d = parse(
            ".subckt blk in out vdd vss b2\n*@ top vdd b2\n*@ bottom vss\nR1 in out 1\n.ends\n\
             X1 a b c d e blk\nX2 n1 n2 n3 n4 n5 n6 n7 n8 eight\n",
        );
        let r = recognize(&d);
        let pins = |s: usize| -> Vec<(&str, i32, i32)> {
            r.syms
                .pins(s)
                .map(|k| {
                    (
                        r.syms.pin_name[k].as_str(),
                        r.syms.pin_x[k],
                        r.syms.pin_y[k],
                    )
                })
                .collect()
        };
        let s = sub_symbol(1);
        // Pins stay in port order: `in` (an input by name) left, `out` right, vdd then b2
        // on top (directive order, left to right), vss below.
        assert_eq!(
            pins(s),
            [
                ("in", -60, 0),
                ("out", 60, 0),
                ("vdd", -10, -40),
                ("vss", 0, 40),
                ("b2", 10, -40)
            ]
        );
        assert_eq!(r.syms.body[s], [-60, -40, 60, 40]);
        // Eight pins on one side: the box widens so each still faces right (|x| > |y|).
        let eight = r.parts.sym[d.devs(0).start + 1] as usize;
        assert!(pins(eight).iter().all(|p| p.1 == 80 && p.2.abs() < 80));
        assert_eq!(pins(eight)[0].2, -70);
    }

    #[test]
    fn xspice_and_nodeless_cards_get_their_own_templates() {
        let d = parse("A1 [a b] ~y nand1\nA2 a b y nand1\nA3 [c d] ~e nand2\nX1 g\nX2 h k=1\n");
        let r = recognize(&d);
        let sym = |i: usize| r.parts.sym[d.devs(0).start + i] as usize;
        let over = |i: usize| -> Vec<(String, String)> {
            r.parts
                .overrides(d.devs(0).start + i)
                .map(|o| (r.parts.over_key[o].clone(), r.parts.over_val[o].clone()))
                .collect()
        };
        assert_eq!(r.syms.format[sym(0)], "{name} [{p1} {p2}] ~{p3} {args}");
        assert!(r.syms.stem[sym(0)].starts_with("spice_a3_"));
        assert_eq!(over(0), [("args".to_owned(), "nand1".to_owned())]);
        assert_eq!(
            (r.syms.stem[sym(1)].as_str(), r.syms.format[sym(1)].as_str()),
            ("spice_a3", ""),
            "plain nodes print as {{pins}}"
        );
        assert_eq!(sym(2), sym(0), "one leaf per port shape");
        let dirs: Vec<Dir> = r.syms.pins(sym(0)).map(|k| r.syms.pin_dir[k]).collect();
        assert_eq!(dirs, [Dir::In, Dir::In, Dir::Out]);
        // Node-less calls of undefined subckts: one placeholder pin the template skips.
        assert_eq!(r.syms.format[sym(3)], "{name} {args}");
        assert_eq!(r.syms.pins(sym(3)).len(), 1);
        assert!(over(3).is_empty(), "args defaults to the subckt name");
        assert_eq!(r.syms.args_default[sym(3)], "g");
        assert_eq!(over(4), [("args".to_owned(), "h k=1".to_owned())]);
        assert_ne!(sym(3), sym(4));
    }

    #[test]
    fn literals_follow_the_expression_grammar() {
        for ok in [
            "1", "10u", "1.8", ".5", "2meg", "1e-6", "1E3k", "-3", "0.18U", "5mil",
        ] {
            assert!(is_literal(ok), "{ok}");
        }
        for bad in [
            "", "1.", "u", "1.8V", "10uF", "{w}", "'1u'", "1e", "w", "1k2",
        ] {
            assert!(!is_literal(bad), "{bad}");
        }
    }

    #[test]
    fn templates_double_braces_and_hole_parameters() {
        assert_eq!(template("1k", &[]), "1k");
        assert_eq!(template("{rval}", &[]), "{{rval}}");
        assert_eq!(template("{2*W}", &["w"]), "{{2*({w})}}");
        assert_eq!(template("wn", &["wn"]), "{{({wn})}}");
        assert_eq!(
            template("w=wn l={l}", &["wn", "l"]),
            "w={{({wn})}} l={{({l})}}"
        );
        assert_eq!(
            template("v(k)*k + f(k)", &["k", "f"]),
            "v(k)*{{({k})}} + f({{({k})}})"
        );
        assert_eq!(
            template("10k", &["k"]),
            "10k",
            "a suffix is not an identifier"
        );
        assert_eq!(strip_outer("{2*k}"), "2*k");
        assert_eq!(strip_outer("'a'"), "a");
    }

    #[test]
    fn faithful_cards_map_to_core_others_to_leaves() {
        let d = parse(
            ".model dm d\nR1 a b 1k m=2\nD1 a 0 dm\nD2 a 0 dm area=2\nM1 d g 0 0 nch w=1u l=1u nf=2\n\
             M2 d g 0 0 pch l=1u\nQ1 c b 0 qx\nX1 a b undefined_sub w=1\nE1 o 0 value={v(a)}\nJ1 d g s jm\n",
        );
        let r = recognize(&d);
        let stem = |i: usize| r.syms.stem[r.parts.sym[i] as usize].as_str();
        let names: Vec<&str> = (0..d.dev_name.len()).map(stem).collect();
        assert_eq!(
            names,
            [
                "res",
                "spice_diode",
                "diode",
                "nmos4",
                "spice_pmos4",
                "spice_npn",
                "undefined_sub",
                "spice_e2",
                "spice_j3"
            ]
        );
        let over = |i: usize| -> Vec<(String, String)> {
            r.parts
                .overrides(i)
                .map(|o| (r.parts.over_key[o].clone(), r.parts.over_val[o].clone()))
                .collect()
        };
        assert_eq!(
            over(0),
            [("value".into(), "1k".into()), ("m".into(), "2".into())]
        );
        assert_eq!(over(1), [("args".into(), "dm".into())]);
        assert!(over(3).contains(&("extra".into(), "nf=2".into())));
        assert_eq!(over(6), [("args".into(), "undefined_sub w=1".into())]);
        assert_eq!(
            r.syms.args_default[r.parts.sym[6] as usize],
            "undefined_sub"
        );
    }
}
