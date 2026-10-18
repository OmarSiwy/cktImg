{
  description = "cktImg: the Schemify plugin that draws schematics from SPICE netlists, and its Zig layout engine";

  inputs = {
    # The same pins as Schemify's flake.lock: the plugin's rustc (1.95) and Zig equal the
    # ones Schemify builds its guests with, so cktimg.wasm rebuilds byte for byte.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # The engine needs Zig 0.17 (engine/build.zig.zon), which nixpkgs doesn't ship yet.
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, zig-overlay, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      zig = pkgs: zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."0.17.0";
    in
    {
      # The engine's static library and include/cktimg.h (the plugin is built by build.sh).
      packages = forAll (pkgs: {
        default = pkgs.stdenv.mkDerivation {
          pname = "cktimg";
          version = "0.1.0";
          src = ./engine;
          nativeBuildInputs = [ pkgs.zig.hook ];
          # `-Dlatex_renderer=true` additionally compiles the TikZ emitter in; it is off by
          # default so consumers who only want geometry do not carry it.
          zigBuildFlags = [ "-Doptimize=ReleaseFast" ];
          meta = {
            description = "Place-and-route engine turning an analog netlist into a schematic";
            license = pkgs.lib.licenses.mit;
          };
        };
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            # The plugin (nixpkgs' rustc ships the wasm32-unknown-unknown std; it has no
            # rust-lld, so build.sh links with wasm-ld).
            rustc
            cargo
            clippy
            rustfmt
            lld
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
