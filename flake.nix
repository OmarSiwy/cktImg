{
  description = "cktimg — netlist to schematic place-and-route";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "cktimg";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [ pkgs.zig.hook ];

          # Builds the static library and installs include/cktimg.h alongside it.
          # `-Dlatex_renderer=true` additionally compiles the TikZ emitter in; it is
          # off by default so consumers who only want geometry do not carry it.
          zigBuildFlags = [ "-Doptimize=ReleaseFast" ];

          meta = {
            description = "Place-and-route engine turning an analog netlist into a schematic";
            license = pkgs.lib.licenses.mit;
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.zig
            pkgs.zls

            # The C ABI is shipped product surface, so the header must keep compiling
            # standalone: cc -std=c99 -Wall -Wextra -pedantic -fsyntax-only include/cktimg.h
            pkgs.clang-tools

            # Rasterizes gallery SVGs so a layout change can be eyeballed.
            pkgs.imagemagick
          ];

          shellHook = ''
            echo "cktimg — zig $(zig version)"
            echo "  zig build test                        run the suite"
            echo "  zig build test -Dlatex_renderer=true  include the TikZ emitter tests"
            echo "  zig build gallery                     render tests/fixtures to zig-out/gallery"
          '';
        };
      }
    );
}
