//! Render all test-suite circuits to SVG under `gallery/`, regenerate the
//! HTML index, and serve the gallery in a browser.
//! Run from the repo root: `cargo visualize` (alias) or
//! `cargo run -p cktimg-svg --example gallery`.

use ir::Interner;
use std::process::Command;

// The §7 circuits are a dev-only fixture in the `build` crate's tests, not shipped API.
// Path-include the file directly so the gallery shares the one source of truth.
#[path = "../../build/tests/fixtures/circuits.rs"]
mod circuits;

fn main() {
    std::fs::create_dir_all("gallery").expect("create gallery/");
    let circuits = circuits::all();
    let mut names = Vec::with_capacity(circuits.len());
    for (name, f) in circuits {
        let mut it = Interner::default();
        let placed = build::layout_verbose(f(&mut it), it.pool());
        let doc = svg::render(placed.ir(), it.pool());
        let path = format!("gallery/{name}.svg");
        std::fs::write(&path, doc).expect("write svg");
        println!("wrote {path}");
        names.push(format!("{name}.svg"));
    }
    // Regenerate index.html in lockstep so the gallery never lists stale files.
    names.sort();
    let mut cards = String::new();
    for n in &names {
        let stem = n.trim_end_matches(".svg");
        use std::fmt::Write;
        let _ = writeln!(
            cards,
            "<figure><a href=\"{n}\"><img src=\"{n}\" loading=\"lazy\"></a><figcaption>{stem}</figcaption></figure>"
        );
    }
    let index = format!(
        "<!doctype html><meta charset=\"utf-8\"><title>cktImg gallery</title>\n\
         <style>body{{font-family:sans-serif;margin:2rem}}\
         main{{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:1.5rem}}\
         figure{{margin:0;border:1px solid #ddd;border-radius:6px;padding:1rem}}\
         img{{width:100%;height:auto}}\
         figcaption{{text-align:center;margin-top:.5rem;color:#444}}</style>\n\
         <h1>cktImg gallery ({count} circuits)</h1>\n<main>\n{cards}</main>\n",
        count = names.len()
    );
    std::fs::write("gallery/index.html", index).expect("write index.html");
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
    // Kill any stale server still holding this port from a previous run.
    if let Ok(out) = Command::new("ss")
        .args(["-tlnp", &format!("sport = :{port}")])
        .output()
    {
        let text = String::from_utf8_lossy(&out.stdout);
        for cap in text.split("pid=").skip(1) {
            let pid = cap
                .split(|c: char| !c.is_ascii_digit())
                .next()
                .unwrap_or("");
            if !pid.is_empty() {
                let _ = Command::new("kill").arg(pid).status();
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
        }
    }

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
