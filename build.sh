#!/usr/bin/env bash
# Build the cktimg plugin for wasm32-unknown-unknown and copy it to ./cktimg.wasm (committed;
# a Schemify project loads it with `plugin cktimg path <dir>/cktimg.wasm`). Fails when the
# module reaches 550 KB (the engine is linked in; see the README's Limits).
#
# Needs the wasm32-unknown-unknown std and Zig 0.17 (build.rs compiles engine/); `nix develop`
# has both, rust-lld included. Without a rust-lld on the toolchain the script links with
# wasm-ld, re-running itself under `nix shell nixpkgs#lld` when none is on PATH.
#
# Reproducible: CI rebuilds the module and fails when the committed one differs. The bytes
# depend only on the sources, Cargo.lock and the toolchain: build in `nix develop` (the
# flake.lock pins rustc, wasm-ld and Zig) or commit the `cktimg-wasm` artifact of the CI
# run. Host paths are remapped out of the module.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_dir="${CARGO_TARGET_DIR:-$here/target}"
# Unit separator between flags: paths may contain spaces.
export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$here=/cktimg"$'\x1f'"--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo"

host="$(rustc -vV | sed -n 's/^host: //p')"
if [[ ! -x "$(rustc --print sysroot)/lib/rustlib/$host/bin/rust-lld" ]] \
   && [[ -z "${CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_LINKER:-}" ]]; then
  if command -v wasm-ld >/dev/null; then
    export CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_LINKER=wasm-ld
  else
    exec nix shell nixpkgs#lld -c env CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_LINKER=wasm-ld "$0" "$@"
  fi
fi

CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}" \
  cargo build --manifest-path "$here/Cargo.toml" --locked --release --target wasm32-unknown-unknown

wasm="$target_dir/wasm32-unknown-unknown/release/cktimg.wasm"
limit=550
size=$(wc -c <"$wasm")
if (( size >= limit * 1024 )); then
  echo "error: cktimg.wasm is $size bytes (limit $limit KB)" >&2
  exit 1
fi
cp "$wasm" "$here/cktimg.wasm"
echo "cktimg.wasm $size bytes"
