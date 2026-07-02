//! SPICE → schematic, native LaTeX. Feed it a netlist, get a `tikzpicture` that
//! `pdflatex` draws itself — no SVG, no raster, no external converter.
//!
//! Two ways to use it (see `docs/LATEX.md`):
//! - **inline**: drop `cktimg.sty` next to your paper and write SPICE inside a
//!   `cktcircuit` environment (needs `pdflatex -shell-escape`; this crate's
//!   `cktimg-latex` binary is the bridge).
//! - **pre-generated**: run the binary to turn `foo.spice` into `foo.tex`, then
//!   `\input{foo}` — plain `pdflatex`, nothing at LaTeX time.

use std::io;
use std::path::{Path, PathBuf};

pub use cktimg::Report;

mod renderer;

/// Render `spice` to a `.tex` file (a `tikzpicture`) at `out` and return the path.
/// Parent dirs are created. The [`Report`] flags any netlist lines ignored/skipped.
pub fn figure(spice: &str, out: impl AsRef<Path>) -> io::Result<(PathBuf, Report)> {
    let out = out.as_ref();
    if let Some(dir) = out.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)?;
    }
    let (tex, report) = tikz(spice);
    std::fs::write(out, tex)?;
    Ok((out.to_path_buf(), report))
}

/// Just the TikZ string (a `\definecolor` + `tikzpicture`). Drop into a document
/// with `\usepackage{tikz,xcolor}`.
pub fn tikz(spice: &str) -> (String, Report) {
    cktimg::run(spice, renderer::render)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ponytail: one end-to-end check — a transistor renders a tikzpicture.
    #[test]
    fn renders_tikz() {
        let (doc, _) = tikz("M1 d g s b nmos");
        assert!(
            doc.contains("\\begin{tikzpicture}"),
            "expected tikz, got: {doc:.80}"
        );
        assert!(doc.contains("\\draw"), "expected drawing commands");
    }
}
