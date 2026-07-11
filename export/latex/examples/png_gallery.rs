//! Generate example PNGs from every fixture netlist.
//!
//!     nix-shell -p "texliveSmall.withPackages (p: [ p.standalone ])" poppler-utils \
//!       --run "cargo run -p cktimg-latex --example png_gallery"
//!
//! (`standalone.cls` is not in plain texliveSmall.)
//! Writes `target/gallery/<name>.{tex,pdf,png}`.

fn main() {
    let fixture_dir = std::path::Path::new("tests/fixtures");
    let out_dir = std::path::Path::new("target/gallery");
    std::fs::create_dir_all(out_dir).unwrap();

    let mut entries: Vec<_> = std::fs::read_dir(fixture_dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|x| x == "spice"))
        .collect();
    entries.sort_by_key(|e| e.file_name());

    for entry in &entries {
        let stem = entry
            .path()
            .file_stem()
            .unwrap()
            .to_string_lossy()
            .to_string();
        let spice = std::fs::read_to_string(entry.path()).unwrap();
        let (tikz, _report) = cktimg_latex::tikz(&spice);

        let doc = format!(
            "\\documentclass[tikz,border=10pt]{{standalone}}\n\
             \\usepackage{{xcolor}}\n\
             \\begin{{document}}\n\
             {tikz}\
             \\end{{document}}\n"
        );

        let tex_path = out_dir.join(format!("{stem}.tex"));
        std::fs::write(&tex_path, &doc).unwrap();

        let status = std::process::Command::new("pdflatex")
            .args(["-interaction=nonstopmode", "-output-directory"])
            .arg(out_dir)
            .arg(&tex_path)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .expect("pdflatex not found — run inside nix-shell -p texliveSmall");

        if !status.success() {
            eprintln!("FAIL {stem} (pdflatex)");
            continue;
        }

        let pdf_path = out_dir.join(format!("{stem}.pdf"));
        let png_stem = out_dir.join(&stem);
        let png_ok = std::process::Command::new("pdftoppm")
            .args(["-png", "-r", "300", "-singlefile"])
            .arg(&pdf_path)
            .arg(&png_stem)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);

        if png_ok {
            println!("OK  {stem}.png");
        } else {
            eprintln!("FAIL {stem} (pdftoppm)");
        }
    }

    println!("\ngallery written to {}", out_dir.display());
}
