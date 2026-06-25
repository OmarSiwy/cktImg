//! Netlist front-end: SPICE (ngspice/hspice) and Spectre text -> [`ir`] schematic.
//!
//! One transformation: `&str` in, a flat [`Schematic<Unplaced>`] + a [`Report`] out. The
//! reader is deliberately narrow — it builds *topology only*:
//!
//! * **Analysis and control are dropped, not parsed.** Every `.tran`/`.ac`/`.option`/`.model`
//!   /`.param` (and the Spectre equivalents) is recorded in the [`Report`] as *ignored*, never
//!   acted on. The IR has no notion of simulation.
//! * **Builtin devices only.** A device's class is the builtin it names (`nmos`, `res`, …),
//!   resolved through [`devices`] — the single source of truth. A transistor whose model token
//!   is a foundry name, not a builtin, is *skipped* and reported. `.model` cards are never
//!   consulted.
//! * **`.subckt`s are flattened.** Definitions are inlined recursively with hierarchical net
//!   and instance names, so the IR carries no hierarchy.
//!
//! Anything the reader wanted to represent but could not (unknown model, undefined subckt,
//! unsupported element) is *skipped* and reported with its source line, so the user always
//! learns exactly what was dropped and why.

mod expr;
mod lines;
mod parse;
mod preprocess;
mod subckt;

use ir::{Interner, Schematic, Unplaced};
use lines::Logical;
use std::path::{Path, PathBuf};

/// Why a source line did not become a device. Both kinds are reported; only the *intent*
/// differs — [`Ignored`](NoteKind::Ignored) is by design, [`Skipped`](NoteKind::Skipped) is a
/// line we would have represented if we could.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum NoteKind {
    /// Dropped on purpose: analysis, options, models, params, includes.
    Ignored,
    /// Could not be represented: unknown model, undefined subckt, unsupported/malformed element.
    Skipped,
}

/// One reported line: its 1-based source number, the assembled text, and a fixed reason.
#[derive(Clone, Debug)]
pub struct Note {
    pub line: u32,
    pub text: String,
    pub reason: &'static str,
}

/// Everything the reader did not turn into a device, split by intent. An empty report means a
/// clean, fully-represented netlist.
#[derive(Default, Debug)]
pub struct Report {
    pub ignored: Vec<Note>,
    pub skipped: Vec<Note>,
}

impl Report {
    pub(crate) fn ignore(&mut self, l: &Logical, reason: &'static str) {
        self.ignored.push(Note { line: l.no, text: l.text.clone(), reason });
    }
    pub(crate) fn skip(&mut self, l: &Logical, reason: &'static str) {
        self.skipped.push(Note { line: l.no, text: l.text.clone(), reason });
    }
    pub(crate) fn note_owned(&mut self, line: u32, text: String, reason: &'static str, skip: bool) {
        let n = Note { line, text, reason };
        if skip { self.skipped.push(n) } else { self.ignored.push(n) }
    }

    pub fn is_clean(&self) -> bool {
        self.skipped.is_empty()
    }

    /// Human-readable rundown of what was dropped, newest concern first (skips, then ignores).
    /// Empty string when nothing was dropped at all.
    pub fn summary(&self) -> String {
        let mut s = String::new();
        for n in &self.skipped {
            s.push_str(&format!("skipped  line {}: {}  [{}]\n", n.line, n.text, n.reason));
        }
        for n in &self.ignored {
            s.push_str(&format!("ignored  line {}: {}  [{}]\n", n.line, n.text, n.reason));
        }
        s
    }
}

/// Lower already-expanded text into a schematic, recording into `rep`.
fn pipeline(src: &str, interner: &mut Interner, mut rep: Report) -> (Schematic<Unplaced>, Report) {
    let (top, defs) = subckt::split(lines::assemble(src), &mut rep);
    let mut b = ir::IrBuilder::new(interner);
    subckt::emit(&top, &defs, &mut b, &mut rep);
    (b.finish(), rep)
}

/// Parse a netlist into a schematic. The caller owns the [`Interner`] (its string pool backs
/// the returned IR), matching [`ir::IrBuilder`]. Never panics on malformed input — every
/// problem surfaces in the [`Report`]. `.include`/`.lib` lines are *not* resolved here (they
/// are reported as ignored); use [`parse_path`] or [`parse_with_loader`] to follow them.
pub fn parse(src: &str, interner: &mut Interner) -> (Schematic<Unplaced>, Report) {
    pipeline(src, interner, Report::default())
}

/// Parse, resolving `.include`/`.lib` through a caller-supplied `loader` (path -> text). The
/// loader owns all IO, so this is usable with an in-memory file map or any virtual filesystem.
/// Includes resolve relative to `"."`; supply absolute paths in the source for other roots.
pub fn parse_with_loader(
    src: &str,
    interner: &mut Interner,
    loader: &mut dyn FnMut(&Path) -> Option<String>,
) -> (Schematic<Unplaced>, Report) {
    let mut rep = Report::default();
    let expanded = preprocess::expand(src, Path::new("."), loader, &mut rep);
    pipeline(&expanded, interner, rep)
}

/// Parse a netlist file, resolving `.include`/`.lib` against the real filesystem (each include
/// relative to the file that names it). Returns an IO error only if the *root* file can't be
/// read; missing or cyclic includes are reported, not fatal.
pub fn parse_path(
    path: impl AsRef<Path>,
    interner: &mut Interner,
) -> std::io::Result<(Schematic<Unplaced>, Report)> {
    let path = path.as_ref();
    let root = std::fs::read_to_string(path)?;
    let base = path.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."));
    let mut rep = Report::default();
    let mut loader = |p: &Path| std::fs::read_to_string(p).ok();
    let expanded = preprocess::expand(&root, &base, &mut loader, &mut rep);
    Ok(pipeline(&expanded, interner, rep))
}

#[cfg(test)]
mod tests {
    use super::*;
    use devices::class_at;

    // End-to-end: a small mixed deck. Builds the right devices, drops analysis, skips a
    // foundry-model transistor, and tells the user about both.
    #[test]
    fn end_to_end() {
        let src = "\
* a tiny RC + driver
V1 in 0 dc 5
R1 in mid 1k
C1 mid 0 1u
M1 out mid 0 0 nmos
M2 out mid 0 0 nch_25
.tran 1n 1u
.end
";
        let mut interner = Interner::default();
        let (sch, rep) = parse(src, &mut interner);
        let ir = sch.ir();

        // V1, R1, C1, M1 -> 4 devices; M2 (foundry model) skipped.
        assert_eq!(ir.devices.len(), 4);
        let names: Vec<&str> =
            ir.devices.symbol.iter().map(|s| class_at(s.index()).name).collect();
        assert_eq!(names, ["vsource", "res", "cap", "nmos"]);

        assert_eq!(rep.skipped.len(), 1);
        assert_eq!(rep.skipped[0].reason, "transistor model is not a builtin device");
        // .tran and .end ignored
        assert!(rep.ignored.iter().any(|n| n.text.starts_with(".tran")));
        assert!(!rep.is_clean());
    }

    // Includes resolved via an in-memory loader, exercising the whole front end end-to-end.
    #[test]
    fn parse_with_includes() {
        use std::collections::HashMap;
        use std::path::Path;

        let mut files = HashMap::new();
        files.insert("rc.sp".to_string(), "R1 in out 1k\nC1 out 0 1u\n".to_string());
        let src = "V1 in 0 dc 5\n.include rc.sp\n";

        let mut interner = Interner::default();
        let mut loader = |p: &Path| files.get(p.to_string_lossy().trim_start_matches("./")).cloned();
        let (sch, rep) = parse_with_loader(src, &mut interner, &mut loader);

        // V1 + the two devices pulled from the include
        assert_eq!(sch.ir().devices.len(), 3);
        assert!(rep.is_clean(), "{}", rep.summary());
    }
}
