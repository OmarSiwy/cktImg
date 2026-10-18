{
  description = "cktImg: the Schemify plugin that draws schematics from SPICE netlists, and its Zig layout engine";

  inputs = {
    # The same pins as Schemify's flake.lock: the plugin's rustc (1.95) and Zig equal the
    # ones Schemify builds its guests with, so cktimg.wasm rebuilds byte for byte.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Rust 1.95.0 (rust-toolchain.toml): nixpkgs ships only its current rustc, and the
    # module's bytes depend on the compiler.
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    # The engine needs Zig 0.17 (build.zig.zon), which nixpkgs doesn't ship yet.
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      rust-overlay,
      zig-overlay,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAll =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ rust-overlay.overlays.default ];
            }
          )
        );
      # Rust 1.95.0 with the guest target; it ships rust-lld, which links the module.
      toolchain =
        pkgs:
        pkgs.rust-bin.stable."1.95.0".default.override {
          targets = [ "wasm32-unknown-unknown" ];
        };
      zig = pkgs: zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."0.17.0";
    in
    {
      # The engine's static library and include/cktimg.h (the plugin is built by build.sh).
      packages = forAll (pkgs: {
        default = pkgs.stdenv.mkDerivation {
          pname = "cktimg";
          version = "0.1.0";
          src = ./engine;
          # Zig 0.17 from zig-overlay: nixpkgs' zig (and its setup hook) is 0.16.
          nativeBuildInputs = [ (zig pkgs) ];
          dontConfigure = true;
          dontInstall = true;
          # `-Dlatex_renderer=true` additionally compiles the TikZ emitter in; it is off by
          # default so consumers who only want geometry do not carry it.
          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
            zig build -Doptimize=ReleaseFast --prefix "$out" --cache-dir "$TMPDIR/zig-cache"
          '';
          meta = {
            description = "Place-and-route engine turning an analog netlist into a schematic";
            license = pkgs.lib.licenses.mit;
          };
        };
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            # The plugin: rustc, cargo, clippy, rustfmt and rust-lld at 1.95.0.
            (toolchain pkgs)
            # The engine.
            (zig pkgs)
            # The C ABI is shipped product surface, so the header must keep compiling
            # standalone: cc -std=c99 -Wall -Wextra -pedantic -fsyntax-only engine/include/cktimg.h
            clang-tools
            # Rasterizes gallery SVGs so a layout change can be eyeballed.
            imagemagick
          ];

          shellHook = ''
            echo "cktimg: zig $(zig version), $(rustc -V)"
            echo "  ./build.sh                             cktimg.wasm (the Schemify plugin)"
            echo "  cargo test                             the plugin's tests"
            echo "  (cd engine && zig build test)          the engine's suite"
            echo "  (cd engine && zig build gallery -- --svgs out/)  draw the textbook circuits"
          '';
        };
      });

      formatter = forAll (pkgs: pkgs.nixfmt);
    };
}
