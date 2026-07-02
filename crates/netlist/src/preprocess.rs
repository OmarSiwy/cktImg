//! `.include`/`.lib` resolution, run on raw text before line assembly. A pluggable loader
//! keeps file IO at the caller's boundary (and makes this testable without a filesystem);
//! [`crate::parse_path`] wires in `std::fs`. Handles both SPICE (`.include`, `.lib file sect`)
//! and Spectre (`include`, `lib`) spellings, resolves nested includes relative to the including
//! file, extracts named `.lib` sections, and guards against include cycles and runaway depth —
//! every failure is reported, never fatal.

use crate::Report;
use std::path::{Path, PathBuf};

/// Reads a resolved path to text, or `None` if it can't be read. Caller owns the IO.
pub type Loader<'a> = &'a mut dyn FnMut(&Path) -> Option<String>;

const MAX_DEPTH: usize = 50;

/// Expand all includes in `src` (whose own directory is `base`) into a single flat text.
pub fn expand(src: &str, base: &Path, loader: Loader, rep: &mut Report) -> String {
    let mut out = String::new();
    let mut visited: Vec<String> = Vec::new();
    expand_into(src, base, loader, rep, 0, &mut visited, &mut out);
    out
}

fn unquote(s: &str) -> &str {
    s.trim_matches(|c| c == '"' || c == '\'')
}

fn resolve(base: &Path, file: &str) -> PathBuf {
    let p = Path::new(file);
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        base.join(p)
    }
}

fn expand_into(
    src: &str,
    base: &Path,
    loader: Loader,
    rep: &mut Report,
    depth: usize,
    visited: &mut Vec<String>,
    out: &mut String,
) {
    if depth > MAX_DEPTH {
        rep.note_owned(0, "<include>".into(), "include nesting too deep", true);
        return;
    }
    for raw in src.lines() {
        let toks: Vec<&str> = raw.split_whitespace().collect();
        let head = toks
            .first()
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();
        match head.as_str() {
            ".include" | ".inc" | "include" => match toks.get(1) {
                Some(f) => splice(
                    unquote(f),
                    None,
                    base,
                    loader,
                    rep,
                    depth,
                    visited,
                    out,
                    raw,
                ),
                None => keep(raw, out),
            },
            ".lib" | "lib" => {
                // `.lib file section` pulls one section; a lone `.lib section` is just a marker.
                if toks.len() >= 3 {
                    splice(
                        unquote(toks[1]),
                        Some(unquote(toks[2])),
                        base,
                        loader,
                        rep,
                        depth,
                        visited,
                        out,
                        raw,
                    );
                }
            }
            ".endl" | "endl" => {} // section markers never survive into the flat text
            _ => keep(raw, out),
        }
    }
}

fn keep(raw: &str, out: &mut String) {
    out.push_str(raw);
    out.push('\n');
}

#[allow(clippy::too_many_arguments)]
fn splice(
    file: &str,
    section: Option<&str>,
    base: &Path,
    loader: Loader,
    rep: &mut Report,
    depth: usize,
    visited: &mut Vec<String>,
    out: &mut String,
    raw: &str,
) {
    let path = resolve(base, file);
    let key = path.to_string_lossy().to_string();
    if visited.contains(&key) {
        rep.note_owned(0, raw.to_string(), "include cycle skipped", true);
        return;
    }
    let text = match loader(&path) {
        Some(t) => t,
        None => {
            rep.note_owned(0, raw.to_string(), "include file not found", true);
            return;
        }
    };
    let content = match section {
        Some(sec) => match extract_section(&text, sec) {
            Some(c) => c,
            None => {
                rep.note_owned(0, raw.to_string(), "lib section not found", true);
                return;
            }
        },
        None => text,
    };
    let child_base = path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| base.to_path_buf());
    visited.push(key);
    expand_into(&content, &child_base, loader, rep, depth + 1, visited, out);
    visited.pop();
}

/// Pull the lines of one `.lib <section> … .endl` block out of a library file. Matching is
/// case-insensitive (SPICE convention). `None` if the section is absent.
fn extract_section(text: &str, section: &str) -> Option<String> {
    let want = section.to_ascii_lowercase();
    let mut out = String::new();
    let mut found = false;
    let mut in_sec = false;
    for line in text.lines() {
        let toks: Vec<&str> = line.split_whitespace().collect();
        let head = toks
            .first()
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();
        // opener: exactly `.lib <name>` (2 tokens) — the 3-token form is an include, not a label
        if matches!(head.as_str(), ".lib" | "lib") && toks.len() == 2 {
            if unquote(toks[1]).eq_ignore_ascii_case(&want) {
                in_sec = true;
                found = true;
            }
            continue;
        }
        if in_sec && matches!(head.as_str(), ".endl" | "endl") {
            in_sec = false;
            continue;
        }
        if in_sec {
            out.push_str(line);
            out.push('\n');
        }
    }
    found.then_some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    // A loader backed by an in-memory map — no filesystem needed.
    fn mem(files: &HashMap<String, String>) -> impl FnMut(&Path) -> Option<String> + '_ {
        move |p: &Path| files.get(&p.to_string_lossy().replace("./", "")).cloned()
    }

    #[test]
    fn nested_include_resolves_relative() {
        let mut files = HashMap::new();
        files.insert(
            "sub/models.sp".into(),
            ".include common.sp\nR2 c d 2k\n".to_string(),
        );
        files.insert("sub/common.sp".into(), "R3 e f 3k\n".to_string());
        let root = "R1 a b 1k\n.include sub/models.sp\n";
        let mut rep = Report::default();
        let mut load = mem(&files);
        let out = expand(root, Path::new("."), &mut load, &mut rep);
        assert!(out.contains("R1 a b 1k"));
        assert!(out.contains("R2 c d 2k"));
        assert!(out.contains("R3 e f 3k")); // common.sp resolved relative to sub/
        assert!(rep.skipped.is_empty(), "{:?}", rep.skipped);
    }

    #[test]
    fn lib_section_extraction() {
        let mut files = HashMap::new();
        files.insert(
            "corner.lib".into(),
            ".lib tt\nR1 a b 1k\n.endl\n.lib ff\nR1 a b 0.5k\n.endl\n".to_string(),
        );
        let root = ".lib corner.lib ff\n";
        let mut rep = Report::default();
        let mut load = mem(&files);
        let out = expand(root, Path::new("."), &mut load, &mut rep);
        assert!(out.contains("R1 a b 0.5k")); // ff section
        assert!(!out.contains("1k")); // tt section excluded
    }

    #[test]
    fn missing_and_cyclic_are_reported_not_fatal() {
        let mut files = HashMap::new();
        files.insert("a.sp".into(), ".include b.sp\n".to_string());
        files.insert("b.sp".into(), ".include a.sp\nR1 a b 1k\n".to_string());
        let mut rep = Report::default();
        let mut load = mem(&files);
        // cycle a->b->a, plus a missing file
        let out = expand(
            ".include a.sp\n.include gone.sp\n",
            Path::new("."),
            &mut load,
            &mut rep,
        );
        assert!(out.contains("R1 a b 1k"));
        assert!(rep.skipped.iter().any(|n| n.reason.contains("cycle")));
        assert!(rep.skipped.iter().any(|n| n.reason.contains("not found")));
    }
}
