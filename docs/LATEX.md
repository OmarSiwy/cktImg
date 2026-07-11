# `cktimg-latex` — SPICE → schematic, natively in LaTeX

Write SPICE, get a schematic drawn by `pdflatex` itself. The output is **native
TikZ** — `\draw` commands, vector, no SVG, no raster, **no external image
converter** anywhere in the pipeline.

## Install the bridge binary

The only moving part is a small binary, `cktimg-latex`, that turns a SPICE file
into a `tikzpicture`:

```sh
cargo install --path export/latex      # or: cargo install cktimg-latex
```

CI also publishes a prebuilt binary on every push (`.github/workflows/latex.yaml`)
— grab it from the run's **Artifacts** and put it on your `PATH`.

## Inline SPICE (the magic path)

Copy `export/latex/cktimg.sty` next to your paper, then:

```latex
\documentclass{article}
\usepackage{cktimg}
\begin{document}

\begin{figure}
  \centering
  \begin{cktcircuit}
  R1 in out 1k
  C1 out 0 1u
  \end{cktcircuit}
  \caption{An RC low-pass, placed and routed by cktImg.}
\end{figure}

\end{document}
```

Compile with shell-escape so LaTeX can call the placer:

```sh
pdflatex -shell-escape paper.tex
```

That's it — the SPICE in the environment is placed, routed, and drawn as TikZ
inline. No SVG step, no Inkscape, no `\includegraphics`.

> **Why `-shell-escape`?** LaTeX can't do place-and-route, so the environment
> shells out to the `cktimg-latex` binary (which *is* the tool, not a third-party
> converter) and `\input`s the TikZ it produces. The drawing itself is 100% TikZ.

`\cktinput{circuit.spice}` does the same for SPICE that already lives in its own file.

## No shell-escape? Pre-generate (plain pdflatex)

Turn the netlist into a `.tex` once, commit it, and `\input` it — then your build
needs nothing at LaTeX time:

```sh
cktimg-latex circuit.spice circuit.tex
```

```latex
\usepackage{tikz,xcolor}
...
\input{circuit}        % just a tikzpicture
```

## Rust API

If you'd rather generate figures from a `build.rs` or your own tool:

```rust
let (path, report) = cktimg_latex::figure(spice, "figs/ota.tex")?; // writes TikZ
let (tikz, _)      = cktimg_latex::tikz(spice);                     // or in-memory
```

## Notes

- Rail nets (`vdd`/`vcc`, `gnd`/`vss`/`0`) get rail devices auto-inserted when
  the netlist names them but draws none.
- Sizing: the picture is emitted at 1 schematic-unit = 1pt. Wrap in
  `\resizebox{\linewidth}{!}{...}` if you want it stretched to the column.
- The colors/line weights match the SVG renderer, so figure and web view agree.
- Parsing never panics; unplaceable lines are reported (printed to the LaTeX log
  in the inline path), not dropped silently.
