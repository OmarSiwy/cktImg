//! `cktimg-latex <in.spice> [out.tex]` — SPICE file in, TikZ out (file or stdout).
//! This is the bridge `cktimg.sty` calls under `pdflatex -shell-escape`.

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(input) = args.next() else {
        eprintln!("usage: cktimg-latex <in.spice> [out.tex]");
        std::process::exit(2);
    };
    let spice = std::fs::read_to_string(&input).unwrap_or_else(|e| {
        eprintln!("cktimg-latex: cannot read {input}: {e}");
        std::process::exit(1);
    });

    let (tex, report) = cktimg_latex::tikz(&spice);
    if !report.is_clean() {
        eprintln!("{}", report.summary()); // surfaced in the LaTeX log
    }

    match args.next() {
        Some(out) => std::fs::write(&out, tex).unwrap_or_else(|e| {
            eprintln!("cktimg-latex: cannot write {out}: {e}");
            std::process::exit(1);
        }),
        None => print!("{tex}"),
    }
}
