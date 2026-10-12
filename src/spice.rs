//! Parse transform: SPICE netlist text → [`Deck`] tables.
//!
//! Subset (the cards ngspice and xschem netlists use): `*` comments (`*.PININFO` and, in a
//! `.subckt`, cktImg's `*@ left|right|top|bottom <ports>` block-side directives read),
//! `;` and whitespace-delimited `$` inline comments, `+` continuations, `.control` …
//! `.endc` kept as one opaque text block, `.subckt`/`.ends` (nested definitions are
//! hoisted), `.global`, `.param` (inside a subckt: the cell's parameters), `.end`.
//! Element cards are split into nodes and the verbatim rest (`N`/`P`/`Y` like `X`: nodes,
//! then the model; XSPICE `A` by [`xspice`]; an `X` may have no nodes); everything else
//! (`.model`, `.include`, analyses, `K` couplings, unsupported element letters) is kept as
//! code text of the cell it appears in, in file order. Case is folded for matching only;
//! first spellings are kept. The first line is not a title (xschem and Schemify netlists
//! start with a comment).

/// Largest accepted input (the ABI's `fs_write` data cap).
pub const TEXT_MAX: usize = 64 << 20;
/// Cells per deck (top level included).
pub const CELLS_MAX: usize = 4096;
/// Element cards per deck.
pub const DEVICES_MAX: usize = 1 << 20;
/// Nets per cell: the router stores net ids as `u16` with `u16::MAX` as "none".
pub const NETS_MAX: usize = u16::MAX as usize - 1;

/// Port direction (`*.PININFO` `I`/`O`/`B`, else guessed from the name).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Dir {
    /// Input (`I`).
    In,
    /// Output (`O`).
    Out,
    /// Bidirectional (`B`, the default).
    Inout,
}

impl Dir {
    /// The format spec's pin `dir` word.
    pub fn word(self) -> &'static str {
        match self {
            Dir::In => "in",
            Dir::Out => "out",
            Dir::Inout => "inout",
        }
    }
}

/// Side of a subckt's block symbol a port sits on: cktImg's `*@ left|right|top|bottom
/// <ports>` directive in the definition, or `Auto` (the importer's default) when none
/// names the port.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Side {
    /// No directive.
    Auto,
    /// `*@ left`.
    Left,
    /// `*@ right`.
    Right,
    /// `*@ top`.
    Top,
    /// `*@ bottom`.
    Bottom,
}

/// Parsed netlist. Cell 0 is the top level; devices and nets are grouped by cell
/// (CSR `*_start`, `cells + 1` entries) and net ids in `dev_net`/`port_net` are
/// cell-local (`0..net_start[c+1]-net_start[c]`). Lifetime: one conversion.
#[derive(Debug, Default)]
pub struct Deck {
    /// Subckt names as written; `""` for the top level.
    pub cell_name: Vec<String>,
    /// CSR into `port_net`.
    pub port_start: Vec<u32>,
    /// Port nets in `.subckt` order.
    pub port_net: Vec<u32>,
    /// Per port (parallel to `port_net`): the block side a `*@` directive put it on.
    pub port_side: Vec<Side>,
    /// Per port: its place among the definition's `*@` directive names (ports on one
    /// side are drawn in that order), `u16::MAX` when no directive names it.
    pub port_rank: Vec<u16>,
    /// CSR into `param_name`/`param_value`.
    pub param_start: Vec<u32>,
    /// Subckt parameter names (`.subckt … k=v` and in-body `.param`).
    pub param_name: Vec<String>,
    /// Their default text, verbatim (`1u`, `{2*k}`, `'w/2'`).
    pub param_value: Vec<String>,
    /// CSR into `net_key`.
    pub net_start: Vec<u32>,
    /// Lowercase net names, grouped by cell.
    pub net_key: Vec<String>,
    /// CSR into the device columns.
    pub dev_start: Vec<u32>,
    /// Element names as written (`M1`, `Xdut`).
    pub dev_name: Vec<String>,
    /// 1-based source line of the card.
    pub dev_line: Vec<u32>,
    /// CSR into `dev_net`.
    pub dev_net_start: Vec<u32>,
    /// Node nets in card order (cell-local ids).
    pub dev_net: Vec<u32>,
    /// Subckt name of an `X` card, empty otherwise.
    pub dev_sub: Vec<String>,
    /// Text after the nodes (and after the subckt name for `X`), verbatim; for an XSPICE
    /// `A` card everything after its name, since its nodes sit among port modifiers
    /// ([`xspice`] splits it).
    pub dev_rest: Vec<String>,
    /// Text kept for the netlist (dot cards, couplings, `.control` blocks, unsupported
    /// elements), each entry one statement with its original line breaks, in file order.
    pub code: Vec<String>,
    /// Cell each `code` entry was written in (0: top level).
    pub code_cell: Vec<u16>,
    /// `.global` names, lowercase.
    pub globals: Vec<String>,
    /// `.model` cards: (lowercase name, lowercase type).
    pub models: Vec<(String, String)>,
    /// `*.PININFO` directions: (lowercase net name, direction); the last entry wins.
    pub pininfo: Vec<(String, Dir)>,
    /// Lowercase net names of the whole deck; `spelled[id]` is the first spelling.
    pub spelling: Interner,
    /// First spelling per `spelling` id.
    pub spelled: Vec<String>,
    /// Lines kept or dropped with a reason, for the import log.
    pub warnings: Vec<String>,
}

impl Deck {
    /// Number of cells (≥ 1: the top level always exists).
    pub fn cells(&self) -> usize {
        self.cell_name.len()
    }

    /// Device rows of cell `c`.
    pub fn devs(&self, c: usize) -> std::ops::Range<usize> {
        self.dev_start[c] as usize..self.dev_start[c + 1] as usize
    }

    /// Number of nets of cell `c`.
    pub fn net_count(&self, c: usize) -> usize {
        (self.net_start[c + 1] - self.net_start[c]) as usize
    }

    /// Lowercase name of local net `n` of cell `c`.
    pub fn net_key(&self, c: usize, n: u32) -> &str {
        &self.net_key[self.net_start[c] as usize + n as usize]
    }

    /// Display spelling of local net `n` of cell `c` (its first spelling in the deck).
    pub fn net_name(&self, c: usize, n: u32) -> &str {
        let key = self.net_key(c, n);
        self.spelling
            .get(key)
            .map_or(key, |id| self.spelled[id as usize].as_str())
    }

    /// `*.PININFO` direction of lowercase net name `key`.
    pub fn pin_info(&self, key: &str) -> Option<Dir> {
        self.pininfo.iter().rev().find(|p| p.0 == key).map(|p| p.1)
    }

    /// Records `name`'s spelling unless the deck has one for it already.
    fn spell(&mut self, name: &str) {
        let (_, fresh) = self.spelling.intern(&name.to_ascii_lowercase());
        if fresh {
            self.spelled.push(name.to_owned());
        }
        assert_eq!(self.spelled.len(), self.spelling.len());
    }
}

/// FNV-1a 64 offset basis: the state [`fnv1a`] starts from.
pub(crate) const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;

/// FNV-1a 64 of `bytes`, continuing from state `h` ([`FNV_OFFSET`] for a fresh hash).
pub(crate) fn fnv1a(h: u64, bytes: &[u8]) -> u64 {
    bytes.iter().fold(h, |h, &b| {
        (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// Deterministic string → dense id table: FNV-1a 64 hash, open addressing with linear
/// probing, power-of-two slots kept at most half full. (No `HashMap`: its order and seed
/// are not deterministic, and one small table keeps the guest small.)
#[derive(Debug, Default)]
pub struct Interner {
    keys: Vec<String>,
    /// `id + 1` per slot, 0 = empty.
    slots: Vec<u32>,
}

impl Interner {
    /// Number of keys.
    pub fn len(&self) -> usize {
        self.keys.len()
    }

    /// True when empty.
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    fn slot(&self, key: &str) -> usize {
        (fnv1a(FNV_OFFSET, key.as_bytes()) as usize) & (self.slots.len() - 1)
    }

    /// Id of `key`, if interned.
    pub fn get(&self, key: &str) -> Option<u32> {
        if self.slots.is_empty() {
            return None;
        }
        let mut i = self.slot(key);
        loop {
            match self.slots[i] {
                0 => return None,
                id if self.keys[id as usize - 1] == key => return Some(id - 1),
                _ => i = (i + 1) & (self.slots.len() - 1),
            }
        }
    }

    /// Id of `key`, interning it first if new; the flag tells whether it was new.
    pub fn intern(&mut self, key: &str) -> (u32, bool) {
        if let Some(id) = self.get(key) {
            return (id, false);
        }
        if 2 * (self.keys.len() + 1) > self.slots.len() {
            let n = (self.slots.len() * 2).max(64);
            self.slots = vec![0; n];
            for (k, key) in self.keys.iter().enumerate() {
                let mut i = self.slot(key);
                while self.slots[i] != 0 {
                    i = (i + 1) & (n - 1);
                }
                self.slots[i] = k as u32 + 1;
            }
        }
        let id = u32::try_from(self.keys.len()).expect("ids fit u32");
        let mut i = self.slot(key);
        while self.slots[i] != 0 {
            i = (i + 1) & (self.slots.len() - 1);
        }
        self.slots[i] = id + 1;
        self.keys.push(key.to_owned());
        assert!(2 * self.keys.len() <= self.slots.len());
        (id, true)
    }
}

impl Deck {
    /// Node nets of device `d`.
    pub fn nets_of(&self, d: usize) -> &[u32] {
        &self.dev_net[self.dev_net_start[d] as usize..self.dev_net_start[d + 1] as usize]
    }

    /// Port nets of cell `c`.
    pub fn ports(&self, c: usize) -> &[u32] {
        &self.port_net[self.port_start[c] as usize..self.port_start[c + 1] as usize]
    }

    /// Parameter rows of cell `c`.
    pub fn params(&self, c: usize) -> std::ops::Range<usize> {
        self.param_start[c] as usize..self.param_start[c + 1] as usize
    }

    /// Lowercase type of `.model` `name` (case-insensitive; the first card of that name).
    pub fn model_kind(&self, name: &str) -> Option<&str> {
        let m = name.to_ascii_lowercase();
        self.models.iter().find(|x| x.0 == m).map(|x| x.1.as_str())
    }

    /// Cell defined as subckt `name` (case-insensitive); never the top level.
    pub fn find_cell(&self, name: &str) -> Option<usize> {
        (1..self.cells()).find(|&c| self.cell_name[c].eq_ignore_ascii_case(name))
    }
}

/// One logical statement: continuation lines joined with a space for parsing, the
/// original lines kept for code text.
struct Stmt {
    line: u32,
    text: String,
    raw: String,
}

/// Device rows in file order before grouping by cell.
#[derive(Default)]
struct Rows {
    cell: Vec<u16>,
    name: Vec<String>,
    line: Vec<u32>,
    nets: Vec<Vec<u32>>,
    sub: Vec<String>,
    rest: Vec<String>,
}

/// Parser state while statements stream in: the cell stack and global net ids
/// (`(cell, lowercase name)` → id), renumbered per cell by [`finish`].
#[derive(Default)]
struct Builder {
    deck: Deck,
    rows: Rows,
    /// `"<cell>/<lowercase name>"` → global net id.
    net_ids: Interner,
    net_cell: Vec<u16>,
    net_keys: Vec<String>,
    ports: Vec<Vec<u32>>,
    /// Per cell, `*@` directive sides of its ports (global net id), in directive order,
    /// one entry per port at most.
    sides: Vec<Vec<(u32, Side)>>,
    params: Vec<Vec<(String, String)>>,
    stack: Vec<u16>,
}

/// Parses `text`. Never fails: an unusable card becomes a warning and code text, so
/// nothing is silently dropped.
///
/// Cost: O(n) expected in the text length (net lookups hash through an [`Interner`]).
///
/// # Panics
///
/// Panics if `text` exceeds [`TEXT_MAX`] (the plugin refuses larger files first).
pub fn parse(text: &str) -> Deck {
    assert!(text.len() <= TEXT_MAX, "input over {TEXT_MAX} bytes");
    let mut b = Builder::default();
    b.new_cell("");
    for st in statements(text, &mut b.deck) {
        if !b.statement(&st) {
            break;
        }
    }
    if b.stack.len() > 1 {
        b.deck
            .warnings
            .push(format!("{} unterminated .subckt", b.stack.len() - 1));
    }
    let deck = b.finish();
    assert_eq!(deck.dev_start.len(), deck.cells() + 1);
    assert_eq!(deck.net_start.len(), deck.cells() + 1);
    deck
}

/// Splits `text` into statements: comments dropped (`*.PININFO` recorded), inline
/// comments cut, `+` lines joined, a `.control` block as one statement.
fn statements(text: &str, deck: &mut Deck) -> Vec<Stmt> {
    let mut out: Vec<Stmt> = Vec::new();
    let mut control: Option<Stmt> = None;
    for (i, raw) in text.lines().enumerate() {
        let line_no = u32::try_from(i + 1).unwrap_or(u32::MAX);
        let line = raw.trim();
        if let Some(block) = control.as_mut() {
            block.raw.push('\n');
            block.raw.push_str(raw.trim_end());
            if first_word_lower(line) == ".endc" {
                out.push(control.take().expect("open block"));
            }
            continue;
        }
        if line.is_empty() {
            continue;
        }
        if line.starts_with("*@") {
            // cktImg's block-side directive: a statement of its own, read in its cell.
            out.push(Stmt {
                line: line_no,
                text: line.to_owned(),
                raw: raw.trim_end().to_owned(),
            });
            continue;
        }
        if let Some(c) = line.strip_prefix('*') {
            pininfo(c, deck);
            continue;
        }
        if let Some(rest) = line.strip_prefix('+') {
            // A comment between a card and its continuation is transparent, a directive too.
            match out.iter_mut().rev().find(|st| !st.text.starts_with("*@")) {
                Some(st) if !st.text.is_empty() => {
                    st.text.push(' ');
                    st.text.push_str(cut_comment(rest).trim_start());
                    st.raw.push('\n');
                    st.raw.push_str(raw.trim_end());
                }
                _ => deck.warnings.push(format!(
                    "line {line_no}: continuation without a card, dropped"
                )),
            }
            continue;
        }
        if first_word_lower(line) == ".control" {
            control = Some(Stmt {
                line: line_no,
                text: String::new(),
                raw: raw.trim_end().to_owned(),
            });
            continue;
        }
        out.push(Stmt {
            line: line_no,
            text: cut_comment(line).to_owned(),
            raw: raw.trim_end().to_owned(),
        });
    }
    if let Some(block) = control {
        deck.warnings
            .push(format!("line {}: unterminated .control block", block.line));
        out.push(block);
    }
    out
}

/// Records `*.PININFO a:I b:O c:B` directions (`c` is the comment text after `*`).
fn pininfo(c: &str, deck: &mut Deck) {
    let lower = c.trim().to_ascii_lowercase();
    let Some(rest) = lower.strip_prefix(".pininfo") else {
        return;
    };
    for tok in rest.split_whitespace() {
        let Some((name, d)) = tok.rsplit_once(':') else {
            continue;
        };
        let dir = match d {
            "i" => Dir::In,
            "o" => Dir::Out,
            "b" | "io" => Dir::Inout,
            _ => continue,
        };
        deck.pininfo.push((name.to_owned(), dir));
    }
}

fn first_word_lower(line: &str) -> String {
    line.split_whitespace()
        .next()
        .unwrap_or("")
        .to_ascii_lowercase()
}

/// Cuts an inline comment: `;`, or `$` with whitespace (or the line edge) on both sides,
/// outside quotes.
fn cut_comment(s: &str) -> &str {
    let b = s.as_bytes();
    let mut quote = 0u8;
    for i in 0..b.len() {
        let c = b[i];
        if quote != 0 {
            if c == quote {
                quote = 0;
            }
            continue;
        }
        match c {
            b'\'' | b'"' => quote = c,
            b';' => return s[..i].trim_end(),
            b'$' => {
                let before = i == 0 || b[i - 1].is_ascii_whitespace();
                let after = i + 1 == b.len() || b[i + 1].is_ascii_whitespace();
                if before && after {
                    return s[..i].trim_end();
                }
            }
            _ => {}
        }
    }
    s.trim_end()
}

/// One token: its text (`k = v` glued to `k=v`) and the byte offset where it starts.
pub(crate) struct Tok {
    pub(crate) text: String,
    pub(crate) at: usize,
}

/// Splits on whitespace outside `'…'`, `"…"`, `{…}` and `(…)`, gluing `k = v`.
pub(crate) fn tokenize(s: &str) -> Vec<Tok> {
    let mut raw: Vec<Tok> = Vec::new();
    let mut cur = String::new();
    let mut start = 0usize;
    let mut quote: Option<char> = None;
    let (mut brace, mut paren) = (0u32, 0u32);
    for (i, c) in s.char_indices() {
        if let Some(q) = quote {
            cur.push(c);
            if c == q {
                quote = None;
            }
            continue;
        }
        if c.is_whitespace() && brace == 0 && paren == 0 {
            if !cur.is_empty() {
                raw.push(Tok {
                    text: std::mem::take(&mut cur),
                    at: start,
                });
            }
            continue;
        }
        if cur.is_empty() {
            start = i;
        }
        match c {
            '\'' | '"' => quote = Some(c),
            '{' => brace += 1,
            '}' => brace = brace.saturating_sub(1),
            '(' => paren += 1,
            ')' => paren = paren.saturating_sub(1),
            _ => {}
        }
        cur.push(c);
    }
    if !cur.is_empty() {
        raw.push(Tok {
            text: cur,
            at: start,
        });
    }
    let mut out: Vec<Tok> = Vec::with_capacity(raw.len());
    let mut i = 0;
    while i < raw.len() {
        let t = &raw[i].text;
        let next = raw.get(i + 1).map(|n| n.text.as_str());
        match out.last_mut() {
            Some(last) if t == "=" => {
                last.text.push('=');
                last.text.push_str(next.unwrap_or(""));
                i += 2;
            }
            Some(last) if t.starts_with('=') && !last.text.ends_with('=') => {
                last.text.push_str(t);
                i += 1;
            }
            _ if t.ends_with('=') && next.is_some() && key_of(t).is_some() => {
                out.push(Tok {
                    text: format!("{t}{}", next.unwrap_or("")),
                    at: raw[i].at,
                });
                i += 2;
            }
            _ => {
                out.push(Tok {
                    text: t.clone(),
                    at: raw[i].at,
                });
                i += 1;
            }
        }
    }
    out
}

/// The `k` of a `k=v` token: non-empty, no quote, brace or paren.
pub(crate) fn key_of(t: &str) -> Option<&str> {
    let eq = t.find('=')?;
    let key = &t[..eq];
    let plain = !key.is_empty() && !key.contains(['\'', '"', '{', '(', ')', '[']);
    plain.then_some(key)
}

/// An XSPICE `A` card's text after its name, split by [`xspice`].
#[derive(Debug, PartialEq, Eq)]
pub struct Xspice {
    /// Byte ranges of the node words in the text, in card order.
    pub nodes: Vec<std::ops::Range<usize>>,
    /// Byte offset of the model name; the model and everything after it is the card's tail.
    pub model: usize,
    /// The text before the model is only the nodes, space-separated (no `[ ]` vector,
    /// `%` modifier, `( )`, `~` or `null`), so `{pins}` re-emits it.
    pub plain: bool,
}

/// Splits XSPICE `A` card text after the name (`[a ~b] %vd(c d) null out model`). A word
/// is a run of anything but whitespace and `[ ] ( ) ~`; a `%…` word is a port modifier
/// (the word after `%vnam` names a source, not a node), `null` an unconnected port, a
/// `k=v` word a parameter; the model is the last other word outside brackets, and the
/// other words before it are the nodes. `None` without a model or a node (kept as code).
///
/// Cost: one pass over `text`.
pub fn xspice(text: &str) -> Option<Xspice> {
    // (range, a node or the model, bracket depth)
    let mut words: Vec<(std::ops::Range<usize>, bool, u32)> = Vec::new();
    let (mut depth, mut start, mut names_source) = (0u32, None, false);
    for (i, ch) in text.char_indices().chain([(text.len(), ' ')]) {
        if !(ch.is_whitespace() || "[]()~".contains(ch)) {
            start.get_or_insert(i);
            continue;
        }
        if let Some(s) = start.take() {
            let w = &text[s..i];
            let plain = !names_source
                && !w.starts_with('%')
                && !w.eq_ignore_ascii_case("null")
                && !w.contains('=');
            names_source = w.eq_ignore_ascii_case("%vnam");
            words.push((s..i, plain, depth));
        }
        match ch {
            '[' => depth += 1,
            ']' => depth = depth.saturating_sub(1),
            _ => {}
        }
    }
    let m = words.iter().rposition(|w| w.1 && w.2 == 0)?;
    let nodes: Vec<std::ops::Range<usize>> = words[..m]
        .iter()
        .filter(|w| w.1)
        .map(|w| w.0.clone())
        .collect();
    if nodes.is_empty() {
        return None;
    }
    let model = words[m].0.start;
    let plain =
        words[..m].iter().all(|w| w.1) && !text[..model].contains(['[', ']', '(', ')', '~']);
    assert!(nodes.iter().all(|r| r.end <= model));
    Some(Xspice {
        nodes,
        model,
        plain,
    })
}

/// Words that make an `E`/`G` card a two-node behavioural source.
const BEHAVIOURAL: &[&str] = &[
    "value", "vol", "cur", "table", "laplace", "poly", "freq", "and", "or", "nand", "nor",
];

impl Builder {
    fn new_cell(&mut self, name: &str) -> u16 {
        let c = self.deck.cell_name.len();
        assert!(c < CELLS_MAX, "cell table full");
        self.deck.cell_name.push(name.to_owned());
        self.ports.push(Vec::new());
        self.sides.push(Vec::new());
        self.params.push(Vec::new());
        let id = u16::try_from(c).expect("CELLS_MAX fits u16");
        self.stack.push(id);
        id
    }

    fn cell(&self) -> u16 {
        *self.stack.last().expect("the top level is never popped")
    }

    fn net(&mut self, cell: u16, name: &str) -> u32 {
        let key = name.to_ascii_lowercase();
        let (id, fresh) = self.net_ids.intern(&format!("{cell}/{key}"));
        if fresh {
            self.deck.spell(name);
            self.net_cell.push(cell);
            self.net_keys.push(key);
        }
        assert_eq!(self.net_keys.len(), self.net_ids.len());
        id
    }

    /// Sets parameter `k` of cell `c`; a repeated name (case-insensitive) takes the later
    /// value, as SPICE reads it, so the cell declares each parameter once.
    fn param(&mut self, line: u32, c: usize, k: &str, v: String) {
        match self.params[c]
            .iter()
            .position(|p| p.0.eq_ignore_ascii_case(k))
        {
            Some(i) => {
                self.warn(
                    line,
                    &format!("parameter {k} set again; the later value is kept"),
                );
                self.params[c][i].1 = v;
            }
            None => self.params[c].push((k.to_owned(), v)),
        }
        assert!(
            self.params[c]
                .iter()
                .filter(|p| p.0.eq_ignore_ascii_case(k))
                .count()
                == 1
        );
    }

    fn warn(&mut self, line: u32, what: &str) {
        self.deck.warnings.push(format!("line {line}: {what}"));
    }

    /// Keeps `st` as code text of the current cell (netlisted where it was written).
    fn code(&mut self, st: &Stmt) {
        self.deck.code.push(st.raw.clone());
        self.deck.code_cell.push(self.cell());
    }

    /// A `*@ left|right|top|bottom <ports>` directive (cktImg's block shape): records the
    /// side of each named port of the current subckt, in directive order; a port named
    /// again takes its later side and place. Other verbs (`*@ expand`), names that are no
    /// port and directives outside a subckt are ignored, as cktImg ignores them.
    fn directive(&mut self, st: &Stmt) {
        let c = self.cell();
        if c == 0 {
            return;
        }
        let mut words = st.text[2..]
            .split(|ch: char| ch.is_whitespace() || ch == ',')
            .filter(|w| !w.is_empty());
        let side = match words.next().map(str::to_ascii_lowercase).as_deref() {
            Some("left") => Side::Left,
            Some("right") => Side::Right,
            Some("top") => Side::Top,
            Some("bottom") => Side::Bottom,
            _ => return,
        };
        for w in words {
            let key = format!("{c}/{}", w.to_ascii_lowercase());
            let Some(id) = self.net_ids.get(&key) else {
                continue;
            };
            if !self.ports[c as usize].contains(&id) {
                continue;
            }
            let sides = &mut self.sides[c as usize];
            sides.retain(|s| s.0 != id);
            sides.push((id, side));
        }
        assert!(self.sides[c as usize].len() <= self.ports[c as usize].len());
    }

    /// Consumes one statement; `false` stops parsing (`.end`).
    fn statement(&mut self, st: &Stmt) -> bool {
        if st.text.starts_with("*@") {
            self.directive(st);
            return true;
        }
        if st.text.is_empty() {
            // A `.control` block (its text lives in `raw`).
            self.code(st);
            return true;
        }
        let toks = tokenize(&st.text);
        let Some(head) = toks.first() else {
            return true;
        };
        let head = head.text.to_ascii_lowercase();
        if head.starts_with('.') {
            return self.dot_card(st, &head, &toks);
        }
        let letter = head.as_bytes()[0];
        if !letter.is_ascii_alphabetic() {
            self.warn(st.line, "unrecognized card kept as code");
            self.code(st);
            return true;
        }
        self.element(st, letter, &toks);
        true
    }

    fn dot_card(&mut self, st: &Stmt, head: &str, toks: &[Tok]) -> bool {
        match head {
            ".end" => return false,
            ".subckt" => {
                let Some(name) = toks.get(1) else {
                    self.warn(st.line, ".subckt without a name, dropped");
                    return true;
                };
                if self.deck.find_cell(&name.text).is_some() {
                    self.warn(
                        st.line,
                        "duplicate .subckt name; calls use the first definition",
                    );
                }
                if self.cell() != 0 {
                    self.warn(st.line, "nested .subckt hoisted to the top level");
                }
                let c = self.new_cell(&name.text);
                let mut in_params = false;
                for t in &toks[2..] {
                    if t.text.eq_ignore_ascii_case("params:") {
                        in_params = true;
                    } else if let Some(k) = key_of(&t.text) {
                        in_params = true;
                        let v = t.text[k.len() + 1..].to_owned();
                        self.param(st.line, c as usize, k, v);
                    } else if in_params {
                        self.warn(st.line, &format!("stray token {} in .subckt", t.text));
                    } else {
                        let n = self.net(c, &t.text);
                        if self.ports[c as usize].contains(&n) {
                            self.warn(st.line, &format!("duplicate port {}", t.text));
                        } else {
                            self.ports[c as usize].push(n);
                        }
                    }
                }
            }
            ".ends" => {
                if self.stack.len() > 1 {
                    self.stack.pop();
                } else {
                    self.warn(st.line, ".ends without .subckt, dropped");
                }
            }
            ".global" => {
                for t in &toks[1..] {
                    let key = t.text.to_ascii_lowercase();
                    self.deck.spell(&t.text);
                    if !self.deck.globals.contains(&key) {
                        self.deck.globals.push(key);
                    }
                }
            }
            ".param" | ".params" if self.cell() != 0 => {
                let c = self.cell() as usize;
                for t in &toks[1..] {
                    match key_of(&t.text) {
                        Some(k) => {
                            let v = t.text[k.len() + 1..].to_owned();
                            self.param(st.line, c, k, v);
                        }
                        None => self.warn(st.line, &format!("stray token {} in .param", t.text)),
                    }
                }
            }
            _ => {
                if head == ".model"
                    && let (Some(name), Some(kind)) = (toks.get(1), toks.get(2))
                {
                    let kind = kind.text.split('(').next().unwrap_or("");
                    self.deck
                        .models
                        .push((name.text.to_ascii_lowercase(), kind.to_ascii_lowercase()));
                }
                self.code(st);
            }
        }
        true
    }

    /// Node count of an element card, or `None` for a card kept as code text.
    fn node_count(&self, letter: u8, toks: &[Tok]) -> Option<usize> {
        let lower = |i: usize| toks.get(i).map(|t| t.text.to_ascii_lowercase());
        let is_model = |i: usize| {
            toks.get(i)
                .is_some_and(|t| self.deck.model_kind(&t.text).is_some())
        };
        Some(match letter {
            b'r' | b'c' | b'l' | b'd' | b'v' | b'i' | b'f' | b'h' | b'b' | b'w' => 2,
            b'e' | b'g' => {
                let w = lower(3).unwrap_or_default();
                let word = w.split(['(', '=', '{']).next().unwrap_or("");
                if BEHAVIOURAL.contains(&word) { 2 } else { 4 }
            }
            b'm' | b's' | b't' | b'o' => 4,
            b'j' | b'z' | b'u' => 3,
            b'q' => {
                // `Q c b e [s] model`: four nodes when token 5 is the model, or when
                // token 4 is no known model and token 5 is a plain word.
                let fifth_plain = toks
                    .get(5)
                    .is_some_and(|t| key_of(&t.text).is_none() && !t.text.contains(['{', '\'']));
                if !is_model(4) && (is_model(5) || fifth_plain) {
                    4
                } else {
                    3
                }
            }
            // Nodes, then the subckt or model name, then `k=v` (`N1 d g s b osdi_mod w=1u`,
            // `P1 i1 i2 0 o1 o2 0 cpl len=1`, `Y1 a 0 b 0 txl len=1`). An `X` may have no
            // nodes (`X1 sub`: a subckt on globals only); the others need one.
            b'x' | b'n' | b'p' | b'y' => {
                let k = toks
                    .iter()
                    .position(|t| {
                        key_of(&t.text).is_some() || t.text.eq_ignore_ascii_case("params:")
                    })
                    .unwrap_or(toks.len());
                if k < 2 || (k < 3 && letter != b'x') {
                    return None;
                }
                k - 2
            }
            _ => return None,
        })
    }

    fn element(&mut self, st: &Stmt, letter: u8, toks: &[Tok]) {
        let cell = self.cell();
        let (nets, sub, rest): (Vec<u32>, String, String) = if letter == b'a' {
            // XSPICE: the nodes sit among port modifiers, so the rest keeps them all.
            let rest = st
                .text
                .trim_start()
                .split_once(char::is_whitespace)
                .map_or("", |p| p.1)
                .trim();
            let Some(x) = xspice(rest) else {
                self.warn(
                    st.line,
                    "XSPICE card without a node or a model kept as code (not drawn)",
                );
                self.code(st);
                return;
            };
            let nets = x
                .nodes
                .iter()
                .map(|r| self.net(cell, &rest[r.clone()]))
                .collect();
            (nets, String::new(), rest.to_owned())
        } else {
            let Some(nodes) = self.node_count(letter, toks) else {
                let what = if letter == b'k' {
                    "coupling kept as top-level code"
                } else {
                    "unsupported element kept as top-level code (not drawn)"
                };
                self.warn(st.line, what);
                self.code(st);
                return;
            };
            let need = 1 + nodes + usize::from(letter == b'x');
            if toks.len() < need {
                self.warn(st.line, "too few nodes; card kept as code");
                self.code(st);
                return;
            }
            let nets = toks[1..1 + nodes]
                .iter()
                .map(|t| self.net(cell, &t.text))
                .collect();
            let sub = if letter == b'x' {
                toks[need - 1].text.clone()
            } else {
                String::new()
            };
            let rest = toks.get(need).map_or("", |t| st.text[t.at..].trim());
            (nets, sub, rest.to_owned())
        };
        assert!(self.rows.name.len() < DEVICES_MAX, "device table full");
        assert!(
            letter == b'x' || !nets.is_empty(),
            "only an X card may have no node"
        );
        self.rows.cell.push(cell);
        self.rows.name.push(toks[0].text.clone());
        self.rows.line.push(st.line);
        self.rows.nets.push(nets);
        self.rows.sub.push(sub);
        self.rows.rest.push(rest);
    }

    /// Groups devices and nets by cell (stable) and renumbers nets cell-locally.
    fn finish(mut self) -> Deck {
        let cells = self.deck.cell_name.len();
        // Nets: stable counting sort by cell; `local[g]` is the cell-local id.
        let mut count = vec![0u32; cells + 1];
        for &c in &self.net_cell {
            count[c as usize + 1] += 1;
        }
        for c in 0..cells {
            count[c + 1] += count[c];
        }
        let mut next = count.clone();
        let mut local = vec![0u32; self.net_keys.len()];
        let mut keys = vec![String::new(); self.net_keys.len()];
        for (g, &c) in self.net_cell.iter().enumerate() {
            let slot = next[c as usize];
            next[c as usize] += 1;
            local[g] = slot - count[c as usize];
            keys[slot as usize] = std::mem::take(&mut self.net_keys[g]);
        }
        for (c, n) in count.iter().take(cells).enumerate() {
            let have = count[c + 1] - n;
            if have as usize > NETS_MAX {
                self.deck
                    .warnings
                    .push(format!("cell {c}: {have} nets exceed {NETS_MAX}"));
            }
        }
        let mut d = self.deck;
        d.net_start = count;
        d.net_key = keys;
        // Devices: stable by cell.
        let mut rows = self.rows;
        d.dev_start = vec![0; cells + 1];
        for &c in &rows.cell {
            d.dev_start[c as usize + 1] += 1;
        }
        for c in 0..cells {
            d.dev_start[c + 1] += d.dev_start[c];
        }
        let mut order = vec![0usize; rows.cell.len()];
        let mut fill = d.dev_start.clone();
        for (i, &c) in rows.cell.iter().enumerate() {
            order[fill[c as usize] as usize] = i;
            fill[c as usize] += 1;
        }
        d.dev_net_start.push(0);
        for &i in &order {
            d.dev_name.push(std::mem::take(&mut rows.name[i]));
            d.dev_line.push(rows.line[i]);
            d.dev_sub.push(std::mem::take(&mut rows.sub[i]));
            d.dev_rest.push(std::mem::take(&mut rows.rest[i]));
            d.dev_net
                .extend(rows.nets[i].iter().map(|&g| local[g as usize]));
            d.dev_net_start
                .push(u32::try_from(d.dev_net.len()).expect("pin count fits u32"));
        }
        d.port_start.push(0);
        d.param_start.push(0);
        for c in 0..cells {
            for &g in &self.ports[c] {
                d.port_net.push(local[g as usize]);
                let at = self.sides[c].iter().position(|s| s.0 == g);
                d.port_side
                    .push(at.map_or(Side::Auto, |k| self.sides[c][k].1));
                d.port_rank
                    .push(at.map_or(u16::MAX, |k| u16::try_from(k).expect("NETS_MAX < u16::MAX")));
            }
            d.port_start.push(d.port_net.len() as u32);
            for (k, v) in &self.params[c] {
                d.param_name.push(k.clone());
                d.param_value.push(v.clone());
            }
            d.param_start.push(d.param_name.len() as u32);
        }
        assert_eq!(d.dev_name.len() + 1, d.dev_net_start.len());
        assert_eq!(
            *d.dev_start.last().expect("cells + 1 entries") as usize,
            d.dev_name.len()
        );
        assert!(d.port_side.len() == d.port_net.len() && d.port_rank.len() == d.port_net.len());
        d
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cards_split_into_nodes_rest_and_code() {
        let d = parse(
            "* title\n.subckt inv in out vdd params: wn=1u\n*.PININFO in:I out:O\n\
             M1 out in vdd vdd pmos w={2*wn}\n+ l=0.18u ; tail\nMn out in 0 0 nmos w=wn l=1u\n\
             .param k=3\n.ends\nX1 a b VDD inv wn=2u\nV1 a 0 dc 0 ac 1\n.tran 1n 1u\n\
             .control\nrun\n.endc\nK1 L1 L2 0.9\n.end\nR9 never here\n",
        );
        assert_eq!(d.cells(), 2);
        assert_eq!(d.cell_name[1], "inv");
        assert_eq!(d.ports(1).len(), 3);
        let params: Vec<&str> = d.params(1).map(|p| d.param_name[p].as_str()).collect();
        assert_eq!(params, ["wn", "k"]);
        let r = parse(".subckt s a k=1\n.param K=2 j=3\n.param k=4\nR1 a 0 1\n.ends\n");
        let kv: Vec<(&str, &str)> = r
            .params(1)
            .map(|p| (r.param_name[p].as_str(), r.param_value[p].as_str()))
            .collect();
        assert_eq!(
            kv,
            [("k", "4"), ("j", "3")],
            "a repeated parameter keeps its later value"
        );
        assert_eq!(d.devs(0).len(), 2, "X1 and V1 at top");
        assert_eq!(d.devs(1).len(), 2);
        let m1 = d.devs(1).start;
        assert_eq!(d.dev_rest[m1], "pmos w={2*wn} l=0.18u");
        assert_eq!(d.nets_of(m1).len(), 4);
        let x1 = d.devs(0).start;
        assert_eq!(d.dev_sub[x1], "inv");
        assert_eq!(d.dev_rest[x1], "wn=2u");
        assert_eq!(d.code.len(), 3, "{:?}", d.code);
        assert_eq!(d.code_cell, [0, 0, 0]);
        assert!(d.code[1].starts_with(".control") && d.code[1].ends_with(".endc"));
        assert_eq!(d.pin_info("in"), Some(Dir::In));
        assert!(d.warnings.iter().any(|w| w.contains("coupling")));
        // Case folds for matching; the first spelling is kept for display.
        assert_eq!(d.net_name(0, d.nets_of(x1)[2]), "vdd");
    }

    #[test]
    fn qualified_counts_and_bad_cards() {
        let d = parse(".model qm npn\nQ1 c b e qm\nQ2 c b e s qm\nEb o 0 value={v(a)}\nR1 a\n");
        let r = d.devs(0);
        assert_eq!(r.len(), 3, "R1 has one node: kept as code");
        assert_eq!(d.nets_of(r.start).len(), 3);
        assert_eq!(d.nets_of(r.start + 1).len(), 4);
        assert_eq!(d.nets_of(r.start + 2).len(), 2);
        assert!(d.code.iter().any(|c| c.starts_with("R1")));
        assert!(d.warnings.iter().any(|w| w.contains("too few")));
    }

    #[test]
    fn xspice_osdi_line_and_nodeless_cards_are_devices() {
        let d = parse(
            ".subckt blk in out vdd vss\n*@ right out, in\n*@ top vdd\n*@ left IN\n*@ expand\n\
             R1 in out 1\n.ends\n*@ left a\nA1 [a b] ~y nand1\nA2 %vd(a 0) %v o gain1\nA3 null\n\
             N1 d g s b osdi w=1u\nP1 a b 0 c e 0 cpl\nY1 a 0 c 0 txl len=1\nX1 on_globals k=2\n\
             X2\nP2 cpl\n",
        );
        let top = d.devs(0);
        let names: Vec<&str> = top.clone().map(|i| d.dev_name[i].as_str()).collect();
        assert_eq!(names, ["A1", "A2", "N1", "P1", "Y1", "X1"]);
        let nodes = |i: usize| -> Vec<&str> {
            d.nets_of(top.start + i)
                .iter()
                .map(|&n| d.net_key(0, n))
                .collect()
        };
        assert_eq!(nodes(0), ["a", "b", "y"]);
        assert_eq!(nodes(1), ["a", "0", "o"]);
        assert_eq!([nodes(2).len(), nodes(3).len(), nodes(4).len()], [4, 6, 4]);
        assert!(nodes(5).is_empty(), "a node-less call");
        assert_eq!(d.dev_rest[top.start], "[a b] ~y nand1");
        assert_eq!(d.dev_rest[top.start + 2], "osdi w=1u");
        assert_eq!(
            (
                d.dev_sub[top.start + 5].as_str(),
                d.dev_rest[top.start + 5].as_str()
            ),
            ("on_globals", "k=2")
        );
        // No node (A3, P2) or no subckt name (X2): kept as code.
        assert_eq!(d.code.len(), 3, "{:?}", d.code);
        // `in`, named twice, takes its later side and place; `vss` has none; the
        // directive at top level and `*@ expand` change nothing.
        let ports = d.port_start[1] as usize..d.port_start[2] as usize;
        assert_eq!(
            d.port_side[ports.clone()],
            [Side::Left, Side::Right, Side::Top, Side::Auto]
        );
        assert_eq!(d.port_rank[ports], [2, 0, 1, u16::MAX]);
    }

    #[test]
    fn xspice_splits_nodes_from_modifiers_and_the_model() {
        let x = xspice("in out gain1").unwrap();
        assert!(x.plain && x.nodes == [0..2, 3..6] && x.model == 7);
        let x = xspice("[a ~b] %vd(c d) null out2 m").unwrap();
        assert!(!x.plain);
        let text = "[a ~b] %vd(c d) null out2 m";
        let words: Vec<&str> = x.nodes.iter().map(|r| &text[r.clone()]).collect();
        assert_eq!(words, ["a", "b", "c", "d", "out2"]);
        assert_eq!(&text[x.model..], "m");
        assert_eq!(xspice("%vnam vsrc o m").unwrap().nodes.len(), 1);
        assert_eq!(xspice("m"), None, "no node");
        assert_eq!(xspice("[a b]"), None, "no model outside brackets");
        assert_eq!(xspice(""), None);
    }

    #[test]
    fn tokenizer_glues_assignments_and_keeps_groups() {
        let t: Vec<String> = tokenize("V1 a b PULSE(0 1 0) w = {a + b} l= 2 'x y'")
            .into_iter()
            .map(|t| t.text)
            .collect();
        assert_eq!(
            t,
            ["V1", "a", "b", "PULSE(0 1 0)", "w={a + b}", "l=2", "'x y'"]
        );
        assert_eq!(cut_comment("R1 a b 1k $ note"), "R1 a b 1k");
        assert_eq!(cut_comment("R1 a b '1$2' ; c"), "R1 a b '1$2'");
    }
}
