//! Raw text -> logical lines. One transformation: a byte stream becomes a flat list of
//! [`Logical`] records (source line number + dialect + whitespace-split tokens), with
//! comments stripped and continuations folded. Everything downstream works on tokens, never
//! on raw text, so the parser never re-scans characters.

/// Netlist dialect of a single logical line. ngspice and hspice share the `Spice` arm — once
/// analysis/options are dropped, their *circuit* grammar is identical. `Spectre` is the
/// paren-node form. The mode flips on a `simulator lang=` directive; pure-SPICE files (no
/// directive) stay `Spice`, the default.
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
pub enum Lang {
    Spice,
    Spectre,
}

/// One assembled source statement. `toks` is already lowercased for `Spice` (the language is
/// case-insensitive) and case-preserved for `Spectre` (it is not). `no` is 1-based.
pub struct Logical {
    pub no: u32,
    pub text: String, // original (pre-lowercase) joined text, for the report
    pub toks: Vec<String>,
    pub lang: Lang,
}

impl Logical {
    /// First token, lowercased — the cheap discriminant the classifier branches on. Empty
    /// string for a blank statement so callers can match without bounds checks.
    pub fn head(&self) -> &str {
        self.toks.first().map(String::as_str).unwrap_or("")
    }
}

/// Strip comments from one physical line for the given dialect, returning the live part.
/// SPICE: `$` or `;` begin an inline comment; a `*` in column 0 is a whole-line comment.
/// Spectre: `//` to end-of-line, a leading `*`, and `/* … */` block comments — including
/// blocks that span lines, tracked through `in_block` (set while inside an unterminated block).
fn live_part<'a>(raw: &'a str, lang: Lang, in_block: &mut bool) -> &'a str {
    match lang {
        Lang::Spice => {
            if raw.trim_start().starts_with('*') {
                return "";
            }
            let cut = raw.find(['$', ';']).unwrap_or(raw.len());
            &raw[..cut]
        }
        Lang::Spectre => {
            let mut s = raw;
            if *in_block {
                match s.find("*/") {
                    Some(p) => {
                        s = &s[p + 2..];
                        *in_block = false;
                    }
                    None => return "", // still inside the block
                }
            }
            if s.trim_start().starts_with('*') {
                return "";
            }
            let cut = s.find("//").unwrap_or(s.len());
            let s = &s[..cut];
            if let Some(a) = s.find("/*") {
                if s[a + 2..].find("*/").is_some() {
                    // ponytail: an inline closed block drops the block and any trailing text on
                    // the line — vanishingly rare on a circuit statement.
                    return &s[..a];
                }
                *in_block = true; // block opens here, closes on a later line
                return &s[..a];
            }
            s
        }
    }
}

/// Does `tok` switch the active dialect? Recognizes `simulator lang=spectre` / `=spice`,
/// tolerating spaces around `=` (so tokens `simulator`,`lang=spectre` or `lang`,`=`,`spectre`).
fn lang_switch(toks: &[String]) -> Option<Lang> {
    if toks.first().map(String::as_str) != Some("simulator") {
        return None;
    }
    let joined = toks.join("").replace(' ', "");
    if joined.contains("lang=spectre") {
        Some(Lang::Spectre)
    } else if joined.contains("lang=spice") {
        Some(Lang::Spice)
    } else {
        None
    }
}

/// Tokenize one already-comment-stripped, continuation-folded statement. Spectre node lists
/// use parentheses; we surround `(`/`)` with spaces so they split out as standalone tokens
/// (the classifier keys element lines off a `(` in slot 1). SPICE folds to lowercase.
fn tokenize(text: &str, lang: Lang) -> Vec<String> {
    let spaced;
    let src = match lang {
        Lang::Spectre => {
            spaced = text.replace('(', " ( ").replace(')', " ) ");
            spaced.as_str()
        }
        Lang::Spice => text,
    };
    src.split_whitespace()
        .map(|w| match lang {
            Lang::Spice => w.to_ascii_lowercase(),
            Lang::Spectre => w.to_string(),
        })
        .collect()
}

/// Assemble the whole source into logical lines. Continuations: a line whose first non-space
/// char is `+` (SPICE/Spectre) or whose predecessor ended in `\` (Spectre) joins the previous
/// statement. The dialect of a statement is the mode active when its *first* physical line
/// starts; a `simulator lang=` line both switches the mode and is emitted (the caller marks it
/// Ignored).
pub fn assemble(src: &str) -> Vec<Logical> {
    let mut out: Vec<Logical> = Vec::new();
    let mut lang = Lang::Spice;
    // pending continuation join: (line_no, accumulated live text, lang at start)
    let mut pend: Option<(u32, String, Lang)> = None;
    let mut backslash = false; // previous physical line requested continuation via trailing '\'
    let mut in_block = false; // inside a Spectre /* … */ block spanning lines

    let flush = |pend: &mut Option<(u32, String, Lang)>, out: &mut Vec<Logical>, lang: &mut Lang| {
        if let Some((no, text, l)) = pend.take() {
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return;
            }
            let toks = tokenize(trimmed, l);
            if let Some(nl) = lang_switch(&toks) {
                *lang = nl;
            }
            out.push(Logical { no, text: trimmed.to_string(), toks, lang: l });
        }
    };

    for (i, raw_line) in src.lines().enumerate() {
        let no = (i + 1) as u32;
        // Continuation is detected lang-agnostically (leading `+`, or a `\` on the prior line)
        // so we can flush BEFORE stripping: flushing the previous statement applies any pending
        // `simulator lang=` switch, and the current line must be stripped in that fresh mode.
        let was_block = in_block;
        let is_plus = raw_line.trim_start().starts_with('+');
        // Continuation if the line is a `+`/`\` join, or sits inside an open block comment
        // (whose live remainder, if any, belongs to the statement the block interrupted).
        let cont = is_plus || backslash || was_block;
        if !cont {
            flush(&mut pend, &mut out, &mut lang);
        }

        let live = live_part(raw_line, lang, &mut in_block);
        backslash = live.trim_end().ends_with('\\');
        let trimmed = live.trim_start();
        // body with continuation/backslash markers removed
        let body = {
            let b = if is_plus { trimmed.strip_prefix('+').unwrap_or(trimmed) } else { live };
            b.trim_end().strip_suffix('\\').unwrap_or(b.trim_end())
        };

        if cont {
            // append to the open statement; if nothing is open (block sat between statements),
            // any live remainder starts a fresh statement rather than being dropped
            if let Some((_, text, _)) = pend.as_mut() {
                text.push(' ');
                text.push_str(body);
            } else if !body.trim().is_empty() {
                pend = Some((no, body.to_string(), lang));
            }
            continue;
        }
        if !body.trim().is_empty() {
            pend = Some((no, body.to_string(), lang));
        }
    }
    flush(&mut pend, &mut out, &mut lang);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn continuation_and_comments() {
        let src = "\
* title comment
R1 a b 1k $ inline ngspice comment
M1 d g s b
+ nmos
.tran 1n 1u
";
        let ls = assemble(src);
        // 3 statements: R1, the folded M1+nmos, .tran. The `*` line is dropped.
        assert_eq!(ls.len(), 3, "lines: {:?}", ls.iter().map(|l| &l.toks).collect::<Vec<_>>());
        assert_eq!(ls[0].toks, ["r1", "a", "b", "1k"]);
        assert_eq!(ls[1].toks, ["m1", "d", "g", "s", "b", "nmos"]); // continuation folded
        assert_eq!(ls[1].no, 3); // numbered from the statement's first physical line
        assert_eq!(ls[2].head(), ".tran");
    }

    #[test]
    fn spectre_lang_switch_and_parens() {
        let src = "\
simulator lang=spectre
m1 (d g s b) nmos // a comment
";
        let ls = assemble(src);
        assert_eq!(ls[0].lang, Lang::Spice); // the directive line itself is read in the prior mode
        assert_eq!(ls[1].lang, Lang::Spectre);
        // parens split into their own tokens, case preserved
        assert_eq!(ls[1].toks, ["m1", "(", "d", "g", "s", "b", ")", "nmos"]);
    }

    #[test]
    fn spectre_multiline_block_comment() {
        let src = "\
simulator lang=spectre
r1 (a b) resistor r=1k
/* this block
   spans several
   lines */
c1 (b 0) capacitor c=1u
";
        let ls = assemble(src);
        let heads: Vec<&str> = ls.iter().map(|l| l.head()).collect();
        // the 3-line block fully disappears; only the directive + 2 elements survive
        assert_eq!(heads, ["simulator", "r1", "c1"]);
    }
}
