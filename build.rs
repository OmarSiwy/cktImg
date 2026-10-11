//! Compiles `extern/cktimg` (Zig 0.17, C ABI in `include/cktimg.h`) into `libcktimg.a`
//! for the cargo target and links it: `wasm32-freestanding` ReleaseSmall when cargo builds
//! `wasm32-unknown-unknown`, the host ReleaseFast (PIC) otherwise. Everything Zig writes
//! (object cache, global cache, the library) stays in `OUT_DIR`, so `cargo clean` removes
//! it and the submodule's working tree is never touched.
//!
//! Why `zig build-lib` and not `zig build`: at the pinned commit `zig build` also compiles
//! the tools (gallery, cktimg-json, cktimg-xschem), which do not build for
//! wasm32-freestanding, and it has no step for the library alone. The command below is the
//! static library of `build.zig` (root `src/root.zig`, `build_options.latex_renderer =
//! false`). docs/upstream/cktimg-lib-step.patch adds a `lib` step upstream; once it lands
//! this can call `zig build lib`.

use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("set by cargo"));
    let root = manifest.join("../../extern/cktimg");
    let src = root.join("src/root.zig");
    assert!(
        src.is_file(),
        "{} missing: run `git submodule update --init`",
        src.display()
    );
    let out = PathBuf::from(std::env::var("OUT_DIR").expect("set by cargo"));
    let target = std::env::var("TARGET").expect("set by cargo");
    let host = std::env::var("HOST").expect("set by cargo");
    let zig = std::env::var("ZIG").unwrap_or_else(|_| "zig".to_owned());

    let version = Command::new(&zig)
        .arg("version")
        .output()
        .unwrap_or_else(|e| {
            panic!(
                "cannot run `{zig}` ({e}): extern/cktimg needs Zig 0.17 (`nix develop`, or set ZIG)"
            )
        });
    let version = String::from_utf8_lossy(&version.stdout);
    assert!(
        version.starts_with("0.17."),
        "extern/cktimg needs Zig 0.17, `{zig}` is {}: use `nix develop` or set ZIG",
        version.trim()
    );

    // `zon_config` (docs/upstream/cktimg-optional-zon.patch; ignored before it lands): the
    // guest never passes settings or symbol files, so it leaves Zig's ZON parser out.
    let wasm = target.starts_with("wasm32");
    let options = out.join("build_options.zig");
    let text = format!(
        "pub const latex_renderer: bool = false;\npub const zon_config: bool = {};\n",
        !wasm
    );
    std::fs::write(&options, text).expect("write build_options.zig");
    let lib = out.join("libcktimg.a");
    let mut cmd = Command::new(&zig);
    cmd.args(["build-lib", "-j4"]);
    if wasm {
        // compiler-rt: cktImg's f128 helpers (`truncl`, `__divtf3`, …), which the Rust
        // wasm32 runtime does not provide.
        cmd.args([
            "-target",
            "wasm32-freestanding",
            "-OReleaseSmall",
            "-fcompiler-rt",
        ]);
    } else {
        assert_eq!(
            target, host,
            "cross builds other than wasm32 need a Zig target mapping"
        );
        cmd.args(["-OReleaseFast", "-fPIC", "-mcpu=baseline"]);
    }
    cmd.arg("--dep")
        .arg("build_options")
        .arg(format!("-Mroot={}", src.display()))
        .arg(format!("-Mbuild_options={}", options.display()))
        .args(["--name", "cktimg"])
        .arg(format!("-femit-bin={}", lib.display()))
        .arg("--cache-dir")
        .arg(out.join("zig-cache"))
        .arg("--global-cache-dir")
        .arg(out.join("zig-global-cache"));
    let status = cmd
        .status()
        .unwrap_or_else(|e| panic!("cannot run {cmd:?}: {e}"));
    assert!(status.success(), "{cmd:?} failed ({status})");
    assert!(lib.is_file(), "zig wrote no {}", lib.display());

    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=cktimg");
    println!("cargo:rerun-if-changed={}", root.join("src").display());
    println!(
        "cargo:rerun-if-changed={}",
        root.join("include/cktimg.h").display()
    );
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=ZIG");
}
