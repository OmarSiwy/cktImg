//! Builds the engine in `engine/` (Zig 0.17, C ABI in `engine/include/cktimg.h`) with its `zig build lib`
//! step into `libcktimg.a` for the cargo target and links it: `wasm32-freestanding`
//! ReleaseSmall without settings support when cargo builds `wasm32-unknown-unknown`
//! (`-Dzon_config=false`: the guest never passes settings or symbol files, and Zig's ZON
//! parser was a sixth of the module; cktImg bundles compiler-rt there), the host
//! ReleaseFast with position-independent code otherwise (`-Dpic=true`: Rust links PIE test
//! binaries). Everything Zig writes (its build runner, caches, the installed library) stays
//! in `OUT_DIR`, so `cargo clean` removes it and `engine/` is never touched.

use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("set by cargo"));
    let root = manifest.join("engine");
    assert!(
        root.join("build.zig").is_file(),
        "{} missing: the engine sits next to this build script",
        root.join("build.zig").display()
    );
    let out = PathBuf::from(std::env::var("OUT_DIR").expect("set by cargo"));
    let target = std::env::var("TARGET").expect("set by cargo");
    let host = std::env::var("HOST").expect("set by cargo");
    let zig = std::env::var("ZIG").unwrap_or_else(|_| "zig".to_owned());

    let version = Command::new(&zig)
        .arg("version")
        .output()
        .unwrap_or_else(|e| {
            panic!("cannot run `{zig}` ({e}): engine/ needs Zig 0.17 (`nix develop`, or set ZIG)")
        });
    let version = String::from_utf8_lossy(&version.stdout);
    assert!(
        version.starts_with("0.17."),
        "engine/ needs Zig 0.17, `{zig}` is {}: use `nix develop` or set ZIG",
        version.trim()
    );

    let mut cmd = Command::new(&zig);
    cmd.current_dir(&root).args(["build", "lib", "-j4"]);
    if target.starts_with("wasm32") {
        cmd.args([
            "-Dtarget=wasm32-freestanding",
            "-Doptimize=ReleaseSmall",
            "-Dzon_config=false",
        ]);
    } else {
        assert_eq!(
            target, host,
            "cross builds other than wasm32 need a Zig target mapping"
        );
        cmd.args(["-Doptimize=ReleaseFast", "-Dcpu=baseline", "-Dpic=true"]);
    }
    // `zig build` has no `--global-cache-dir` flag; the environment sets it.
    cmd.arg("--prefix")
        .arg(&out)
        .arg("--cache-dir")
        .arg(out.join("zig-cache"))
        .env("ZIG_GLOBAL_CACHE_DIR", out.join("zig-global-cache"));
    let status = cmd
        .status()
        .unwrap_or_else(|e| panic!("cannot run {cmd:?}: {e}"));
    assert!(status.success(), "{cmd:?} failed ({status})");
    let lib = out.join("lib");
    assert!(
        lib.join("libcktimg.a").is_file(),
        "zig wrote no {}",
        lib.join("libcktimg.a").display()
    );

    println!("cargo:rustc-link-search=native={}", lib.display());
    println!("cargo:rustc-link-lib=static=cktimg");
    for watched in ["src", "include/cktimg.h", "build.zig", "build.zig.zon"] {
        println!("cargo:rerun-if-changed={}", root.join(watched).display());
    }
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=ZIG");
}
