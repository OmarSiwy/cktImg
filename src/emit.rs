//! Emit transform: drawn cells → Schemify files (format spec v1) in the
//! writer's canonical form (§2, §4): records in rank order, rank-3 kinds in writer order
//! each sorted by id, a blank line between records of different words, values quoted
//! only when not bare. Only the record kinds below are ever written, so this is a few
//! lines rather than `schemify_format`'s general writer (which would cost the guest
//! ~20 KB); `tests/roundtrip.rs` checks every file round-trips byte for byte through
//! `doc`.
//!
//! Ids follow the importer rule (format spec §4, `schemify_format::IdRng::for_import`):
//! record `k` of a file draws from FNV-1a 64 of `"<source>#<stem>"` then `k`
//! (little-endian), splitmix64, redrawn on collision.

use schemify_abi::text::push_value;

use crate::layout::{Drawn, ORIENT_WORDS};
use crate::recognize::{Family, Recognized, strip_outer, template, template_expr};
use crate::spice::{Deck, FNV_OFFSET, Interner, fnv1a};

/// One output file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutFile {
    /// File name (`inv.shcomp`), to be written next to the source netlist.
    pub name: String,
    /// Canonical file bytes.
    pub bytes: Vec<u8>,
    /// A generated leaf cell (`spice_*` or a stub): an existing file of that name is
    /// kept rather than replaced, since earlier imports into the directory share it.
    pub shared: bool,
}

/// Crockford base32 digits of ids, in value (and byte) order.
const ID_ALPHABET: &[u8; 32] = b"0123456789abcdefghjkmnpqrstvwxyz";
/// Records per file: the sort key keeps 20 bits for the record index.
const RECORDS_MAX: usize = 1 << 20;

/// Canonical position of a record word: rank 1, rank 2, the rank-3 kinds in writer
/// order (sorted by id within), rank 6.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u8)]
enum Slot {
    Rank1 = 1,
    Rank2,
    Inst,
    Wire,
    Label,
    Port,
    Noconn,
    Code,
}

/// One record being built: sort key, word, text (record line, attributes, verbatim).
struct Rec {
    key: u64,
    word: &'static str,
    text: String,
}

/// Builds one file.
struct Writer {
    header: String,
    recs: Vec<Rec>,
    /// `key_hash` of `"<source>#<stem>"`.
    source_key: u64,
    ordinal: u32,
    taken: Interner,
}

/// Appends `v` in decimal (the canonical form of an integer coordinate); `core::fmt`
/// costs the guest far more fuel per number.
fn push_int(out: &mut String, v: i32) {
    if v < 0 {
        out.push('-');
    }
    let mut digits = [0u8; 10];
    let mut n = v.unsigned_abs();
    let mut k = digits.len();
    loop {
        k -= 1;
        digits[k] = b'0' + (n % 10) as u8;
        n /= 10;
        if n == 0 {
            break;
        }
    }
    out.extend(digits[k..].iter().map(|&d| d as char));
}

/// `v` in decimal, as an owned value for attribute lists.
fn int(v: i32) -> String {
    let mut s = String::with_capacity(11);
    push_int(&mut s, v);
    s
}

/// The 6-char id drawn from 64 random bits (low 30 bits, 5 per char, first char lowest).
fn id_text(bits: u64) -> String {
    (0..6)
        .map(|i| ID_ALPHABET[((bits >> (5 * i)) & 31) as usize] as char)
        .collect()
}

/// Bytewise sort value of an id drawn from `bits` (first char most significant).
fn id_order(bits: u64) -> u64 {
    (0..6).fold(0, |acc, i| (acc << 5) | ((bits >> (5 * i)) & 31))
}

/// FNV-1a 64 state after the source key (each record then folds in its ordinal).
fn key_hash(key: &str) -> u64 {
    fnv1a(FNV_OFFSET, key.as_bytes())
}

/// `IdRng::for_import(key, ordinal)` + `fresh_id` (with `key_hash(key)` precomputed): the
/// first draw whose text `taken` does not hold yet (interned there).
fn import_id(key: u64, ordinal: u32, taken: &mut Interner) -> u64 {
    let mut state = fnv1a(key, &ordinal.to_le_bytes());
    for _ in 0..64 {
        state = state.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        let bits = z ^ (z >> 31);
        if taken.intern(&id_text(bits)).1 {
            return bits;
        }
    }
    unreachable!("64 taken draws in a 2^30 id space");
}

impl Writer {
    fn new(kind: &str, source_key: String) -> Writer {
        Writer {
            header: format!("schemify 1 {kind}\n"),
            recs: Vec::new(),
            source_key: key_hash(&source_key),
            ordinal: 0,
            taken: Interner::default(),
        }
    }

    /// A header attribute (call in canonical order: doc, prefix, provenance).
    fn header_attr(&mut self, key: &str, v: &str) {
        assert!(self.recs.is_empty(), "header attributes come first");
        self.header.push_str("  ");
        self.header.push_str(key);
        self.header.push(' ');
        push_value(&mut self.header, v);
        self.header.push('\n');
    }

    /// Starts a record; rank-3 records draw an id (the first field).
    fn record(&mut self, slot: Slot, word: &'static str, fields: &[&str]) {
        assert!(self.recs.len() < RECORDS_MAX, "file record table full");
        let ranked = matches!(
            slot,
            Slot::Inst | Slot::Wire | Slot::Label | Slot::Port | Slot::Noconn
        );
        let mut text = String::from(word);
        let mut order = 0;
        if ranked {
            let bits = import_id(self.source_key, self.ordinal, &mut self.taken);
            self.ordinal += 1;
            order = id_order(bits);
            text.push(' ');
            text.push_str(&id_text(bits));
        }
        text.push('\n');
        let key = (slot as u64) << 56 | order << 20 | self.recs.len() as u64;
        self.recs.push(Rec { key, word, text });
        self.fields(fields);
    }

    /// Integer coordinates (xschem units) as fields of the current record.
    fn coords(&mut self, xs: &[i32]) {
        let rec = self.recs.last_mut().expect("a record is open");
        assert_eq!(rec.text.pop(), Some('\n'));
        assert!(!rec.text.contains('\n'), "fields go on the record line");
        for &v in xs {
            rec.text.push(' ');
            push_int(&mut rec.text, v);
        }
        rec.text.push('\n');
    }

    /// Appends canonical values to the current record's first line.
    fn fields(&mut self, values: &[&str]) {
        let rec = self.recs.last_mut().expect("a record is open");
        assert_eq!(rec.text.pop(), Some('\n'));
        assert!(!rec.text.contains('\n'), "fields go on the record line");
        for v in values {
            rec.text.push(' ');
            push_value(&mut rec.text, v);
        }
        rec.text.push('\n');
    }

    /// An attribute line of the current record.
    fn attr(&mut self, key: &str, values: &[&str]) {
        let rec = self.recs.last_mut().expect("a record is open");
        rec.text.push_str("  ");
        rec.text.push_str(key);
        for v in values {
            rec.text.push(' ');
            push_value(&mut rec.text, v);
        }
        rec.text.push('\n');
    }

    /// A verbatim line of the current record.
    fn verbatim(&mut self, line: &str) {
        assert!(!line.contains(['\n', '\r']));
        let rec = self.recs.last_mut().expect("a record is open");
        rec.text
            .push_str(if line.is_empty() { "  |" } else { "  | " });
        rec.text.push_str(line);
        rec.text.push('\n');
    }

    fn finish(self, name: String, shared: bool) -> OutFile {
        let mut keys: Vec<u64> = self.recs.iter().map(|r| r.key).collect();
        keys.sort_unstable();
        let mut out = self.header;
        let mut prev = "schemify";
        for k in keys {
            let r = &self.recs[(k & (RECORDS_MAX as u64 - 1)) as usize];
            if r.word != prev {
                out.push('\n');
            }
            out.push_str(&r.text);
            prev = r.word;
        }
        assert!(out.starts_with("schemify 1 ") && out.ends_with('\n'));
        OutFile {
            name,
            bytes: out.into_bytes(),
            shared,
        }
    }
}

/// Writes deck cell `c` (0: the bench, else a component) as file `stem`.
///
/// # Panics
///
/// Panics if `drawn` was made for another cell.
pub fn cell_file(
    source: &str,
    deck: &Deck,
    rec: &Recognized,
    c: usize,
    stem: &str,
    drawn: &Drawn,
) -> OutFile {
    assert_eq!(drawn.x.len(), deck.devs(c).len());
    let kind = if c == 0 { "shbench" } else { "shcomp" };
    let mut w = Writer::new(kind, format!("{source}#{stem}"));
    if c > 0 {
        w.header_attr("prefix", "X");
    }
    w.header_attr("provenance", &format!("cktimg {source}"));
    let params: Vec<&str> = deck
        .params(c)
        .map(|p| deck.param_name[p].as_str())
        .collect();
    if c > 0 {
        let s = crate::recognize::sub_symbol(c);
        symbol(&mut w, rec, s);
        for p in deck.params(c) {
            let v = template_expr(strip_outer(&deck.param_value[p]), &params);
            w.record(Slot::Rank1, "param", &[&deck.param_name[p], &v]);
            w.attr("kind", &["string"]);
        }
        w.record(Slot::Rank1, "impl", &["schematic", "schematic"]);
        graphics(&mut w, rec, s);
    }
    for (i, d) in deck.devs(c).enumerate() {
        let s = rec.parts.sym[d] as usize;
        w.record(Slot::Inst, "inst", &[&rec.syms.cellref(s)]);
        let (x, y) = (int(drawn.x[i]), int(drawn.y[i]));
        w.attr("at", &[&x, &y, ORIENT_WORDS[drawn.orient[i] as usize]]);
        w.attr(
            "name",
            &[&crate::recognize::pin_name(&rec.parts.inst_name[d])],
        );
        for o in rec.parts.overrides(d) {
            w.attr(&rec.parts.over_key[o], &[&rec.parts.over_val[o]]);
        }
    }
    for seg in &drawn.wire {
        w.record(Slot::Wire, "wire", &[]);
        w.coords(seg);
    }
    for p in &drawn.noconn {
        w.record(Slot::Noconn, "noconn", &[]);
        w.coords(p);
    }
    for m in 0..drawn.mark_net.len() {
        let net = drawn.mark_net[m];
        let name = crate::recognize::pin_name(deck.net_name(c, net));
        let (slot, word) = if drawn.mark_port[m] {
            (Slot::Port, "port")
        } else {
            (Slot::Label, "label")
        };
        w.record(slot, word, &[]);
        w.coords(&[drawn.mark_x[m], drawn.mark_y[m]]);
        w.fields(&[ORIENT_WORDS[drawn.mark_orient[m] as usize], &name]);
        if !drawn.mark_port[m] && deck.globals.iter().any(|g| g == deck.net_key(c, net)) {
            w.attr("global", &["true"]);
        }
    }
    let code = || (0..deck.code.len()).filter(|&k| deck.code_cell[k] as usize == c);
    if c == 0 && code().next().is_some() {
        w.record(Slot::Code, "code", &["netlist", "spice"]);
        for k in code() {
            for line in deck.code[k].lines() {
                // `${NAME}` expands in code text (netlist spec §7.1); `$$` is a literal `$`.
                w.verbatim(&line.replace('$', "$$"));
            }
        }
    } else if c > 0 && (code().next().is_some() || !params.is_empty()) {
        // Inside a subckt the text must stay in its definition: one `spice_code` instance
        // per entry, stacked below the drawing (clear of every wire), pin no-connected.
        // The first re-declares the cell's parameters for the card text that names them:
        // `.param k={k}` renders each (specialized) value.
        let mut texts: Vec<String> = Vec::new();
        if !params.is_empty() {
            let mut line = String::from(".param");
            for k in &params {
                // Template `k={{{k}}}`: literal braces around a hole.
                line.push(' ');
                line.push_str(k);
                line.push_str("={{{");
                line.push_str(k);
                line.push_str("}}}");
            }
            texts.push(line);
        }
        texts.extend(code().map(|k| template(&deck.code[k], &[])));
        let s = rec.code_sym as usize;
        let k0 = rec.syms.pins(s).start;
        let (x, mut y) = below(drawn);
        for (n, text) in texts.iter().enumerate() {
            w.record(Slot::Inst, "inst", &[&rec.syms.cellref(s)]);
            w.attr("at", &[&int(x), &int(y), "R0"]);
            w.attr("name", &[&format!("code{n}")]);
            w.attr("text", &[text]);
            w.record(Slot::Noconn, "noconn", &[]);
            w.coords(&[x + rec.syms.pin_x[k0], y + rec.syms.pin_y[k0]]);
            y += 60;
        }
    }
    w.finish(format!("{stem}.{kind}"), false)
}

/// Origin for code instances: left-aligned, 300 units below the drawing, on the 10 grid.
fn below(drawn: &Drawn) -> (i32, i32) {
    let b = drawn.bounds;
    assert!(b[0] <= b[2] && b[1] <= b[3]);
    let (x, y) = (
        b[0].div_euclid(10) * 10,
        (b[3] + 300).div_euclid(10) * 10 + 10,
    );
    assert!(y > b[3]);
    (x, y)
}

/// Writes generated leaf symbol `s` (`.shprim`): its pins, one string parameter and a
/// SPICE impl that re-emits the card (`{name} {pins} {args}`, or the leaf's own template:
/// an XSPICE port shape, a node-less call), or for the code leaf the text itself
/// (`{text}`).
pub fn leaf_file(source: &str, rec: &Recognized, s: usize) -> OutFile {
    let stem = &rec.syms.stem[s];
    let code = s == rec.code_sym as usize;
    let own = rec.syms.format[s].as_str();
    let (doc, param, format) = if code {
        (
            "SPICE text kept inside a subckt definition (cktimg plugin)",
            "text",
            "{text}",
        )
    } else {
        (
            "SPICE card re-emitted verbatim (cktimg plugin)",
            "args",
            if own.is_empty() {
                "{name} {pins} {args}"
            } else {
                own
            },
        )
    };
    let mut w = Writer::new("shprim", format!("{source}#{stem}"));
    w.header_attr("doc", doc);
    w.header_attr("provenance", &format!("cktimg {source}"));
    symbol(&mut w, rec, s);
    w.record(
        Slot::Rank1,
        "param",
        &[param, &template(&rec.syms.args_default[s], &[])],
    );
    w.attr("kind", &["string"]);
    w.record(Slot::Rank1, "impl", &["spice", "spice"]);
    w.attr("format", &["spice", format]);
    graphics(&mut w, rec, s);
    w.finish(format!("{stem}.shprim"), true)
}

/// Rank 1 pins of symbol `s`.
fn symbol(w: &mut Writer, rec: &Recognized, s: usize) {
    for k in rec.syms.pins(s) {
        w.record(
            Slot::Rank1,
            "pin",
            &[&rec.syms.pin_name[k], rec.syms.pin_dir[k].word()],
        );
        w.coords(&[rec.syms.pin_x[k], rec.syms.pin_y[k]]);
    }
}

/// Rank 2 drawing of symbol `s`: the family's glyph, pin leads, name and cell text.
fn graphics(w: &mut Writer, rec: &Recognized, s: usize) {
    let b = rec.syms.body[s];
    let line = |w: &mut Writer, v: [i32; 4]| {
        w.record(Slot::Rank2, "line", &[]);
        w.coords(&v);
    };
    match rec.syms.family[s] {
        Family::Two => {
            line(w, [0, -30, 0, -20]);
            line(w, [0, 20, 0, 30]);
            w.record(Slot::Rank2, "rect", &[]);
            w.coords(&[-10, -20, 10, 20]);
        }
        Family::Box => {
            // The box 20 inside the body, a lead from each pin to its side.
            let r = [b[0] + 20, b[1] + 20, b[2] - 20, b[3] - 20];
            assert!(
                r[0] < r[2] && r[1] < r[3],
                "a box body is at least 120 x 80"
            );
            w.record(Slot::Rank2, "rect", &[]);
            w.coords(&r);
            for k in rec.syms.pins(s) {
                let (x, y) = (rec.syms.pin_x[k], rec.syms.pin_y[k]);
                let edge = if x == b[0] || x == b[2] {
                    [r[if x == b[0] { 0 } else { 2 }], y]
                } else {
                    [x, r[if y == b[1] { 1 } else { 3 }]]
                };
                line(w, [x, y, edge[0], edge[1]]);
            }
        }
        Family::Vcxs | Family::Vsw | Family::Tline => {
            let inner = b[2].max(-b[0]) - 20;
            let (top, bot) = (b[1].min(-10) - 10, b[3].max(10) + 10);
            w.record(Slot::Rank2, "rect", &[]);
            w.coords(&[-inner, top, inner, bot]);
            for k in rec.syms.pins(s) {
                let (x, y) = (rec.syms.pin_x[k], rec.syms.pin_y[k]);
                let edge = if x < 0 {
                    -inner
                } else if x > 0 {
                    inner
                } else {
                    0
                };
                if edge != x {
                    line(w, [x, y, edge, y]);
                } else if y != 0 && (y < top || y > bot) {
                    line(w, [x, y, x, if y < 0 { top } else { bot }]);
                }
            }
        }
        Family::Nmos | Family::Pmos | Family::Npn | Family::Pnp => {
            for v in [
                [-20, 0, -10, 0],
                [-10, -20, -10, 20],
                [0, -20, 0, 20],
                [0, -20, 20, -20],
                [0, 20, 20, 20],
                [20, -30, 20, -20],
                [20, 20, 20, 30],
            ] {
                line(w, v);
            }
            if rec.syms.pins(s).len() == 4 {
                line(w, [0, 0, 20, 0]);
            }
        }
    }
    for (y, t) in [(b[1] - 20, "{name}"), (b[3] + 10, "{cell}")] {
        w.record(Slot::Rank2, "stext", &[]);
        w.coords(&[b[0], y]);
        w.fields(&["R0", t]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values_quote_only_when_needed() {
        let q = |v: &str| {
            let mut s = String::new();
            push_value(&mut s, v);
            s
        };
        assert_eq!(q("nfet_01v8"), "nfet_01v8");
        assert_eq!(q("{name}"), "{name}");
        assert_eq!(q(""), "\"\"");
        assert_eq!(q("#1"), "\"#1\"");
        assert_eq!(q("a b"), "\"a b\"");
        assert_eq!(q("say \"hi\"\\"), "\"say \\\"hi\\\"\\\\\"");
        assert_eq!(
            q("l1\nl2\tx\r\u{0}\u{7f}"),
            "\"l1\\nl2\\tx\\u{d}\\u{0}\\u{7f}\""
        );
    }

    #[test]
    fn integers_print_like_core_fmt() {
        for v in [0, 7, -7, 10, -10, 123_456, i32::MAX, i32::MIN] {
            assert_eq!(int(v), v.to_string());
        }
    }

    #[test]
    fn ids_sort_like_their_text() {
        let mut taken = Interner::default();
        let a = import_id(key_hash("k"), 0, &mut taken);
        let b = import_id(key_hash("k"), 1, &mut taken);
        assert_ne!(id_text(a), id_text(b));
        assert_eq!(id_text(a) < id_text(b), id_order(a) < id_order(b));
        let again = import_id(key_hash("k"), 0, &mut taken);
        assert_ne!(id_text(again), id_text(a), "a taken id is redrawn");
    }

    #[test]
    fn ids_match_the_format_crate_import_rule() {
        use schemify_format::{IdRng, fresh_id};
        for (key, k) in [("n2s/a.sp#a", 0), ("n2s/a.sp#a", 7), ("x", 123_456)] {
            let ours = id_text(import_id(key_hash(key), k, &mut Interner::default()));
            let theirs = fresh_id(&mut IdRng::for_import(key, k), |_| false);
            assert_eq!(ours, theirs.as_str());
        }
    }
}
