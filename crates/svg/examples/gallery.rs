//! Render all test-suite circuits to SVG under `gallery/`, refresh the
//! manifest, and serve the gallery in a browser.
//! Run from the repo root: `cargo visualize` (alias) or
//! `cargo run -p svg --example gallery`.

use ir::Interner;
use std::process::Command;

fn main() {
    std::fs::create_dir_all("gallery").expect("create gallery/");
    let mut names = Vec::new();
    for (name, f) in build::circuits::all() {
        let mut it = Interner::default();
        let placed = build::layout(f(&mut it));
        let doc = svg::render(placed.ir(), it.pool());
        let path = format!("gallery/{name}.svg");
        std::fs::write(&path, doc).expect("write svg");
        println!("wrote {path}");
        names.push(format!("{name}.svg"));
    }
    // Keep manifest.json in lockstep so the gallery never lists stale files.
    names.sort();
    let manifest = format!(
        "[\n{}\n]\n",
        names
            .iter()
            .map(|n| format!("  {:?}", n))
            .collect::<Vec<_>>()
            .join(",\n")
    );
    std::fs::write("gallery/manifest.json", manifest).expect("write manifest");
    println!("{} schematics rendered to gallery/", names.len());

    // Render-only mode (CI / scripted verification): skip the blocking dev server.
    if std::env::var_os("GALLERY_NO_SERVE").is_some() {
        return;
    }
    serve_and_open("gallery", 8731);
}

// ponytail: shells out to python's stdlib http.server — no Rust http dep for a
// dev-only viewer. Swap for `tiny_http` only if python stops being a given.
fn serve_and_open(dir: &str, port: u16) {
    let mut server = Command::new("python3")
        .args(["-m", "http.server", &port.to_string()])
        .current_dir(dir)
        .spawn()
        .expect("start python3 http.server (is python3 installed?)");

    let url = format!("http://localhost:{port}/");
    // xdg-open (Linux), open (macOS), start (Windows) — first one that exists wins.
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else if cfg!(target_os = "windows") {
        "start"
    } else {
        "xdg-open"
    };
    let _ = Command::new(opener).arg(&url).status();
    println!("serving {url}  (Ctrl-C to stop)");

    let _ = server.wait();
}
