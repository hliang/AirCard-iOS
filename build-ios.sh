#!/bin/bash
# build-ios.sh
# Builds the Rust FFI static library for iOS and packages AirliftFFI.xcframework.
# Run any time rust-core/ changes, then regenerate with `xcodegen generate`.
set -euo pipefail

# Make ~/.cargo visible to non-login shells (Xcode build phases, CI).
# Only source when the file exists: a bare `source ... || true` aborts the
# script under `set -e` because `source` is a special builtin.
# shellcheck disable=SC1090,SC1091
if [ -f "$HOME/.cargo/env" ]; then
    source "$HOME/.cargo/env"
fi

# Prefer the rustup-managed toolchain. A Homebrew or system Rust earlier in
# PATH has no iOS targets and fails with "can't find crate for `core`", and its
# rustc can shadow the rustup one even when `rustup run` is used. Prepending the
# active toolchain's bin directory keeps cargo and rustc in sync.
if command -v rustup >/dev/null 2>&1; then
    if RUSTUP_CARGO="$(rustup which cargo 2>/dev/null)" && [ -n "${RUSTUP_CARGO:-}" ]; then
        export PATH="$(dirname "$RUSTUP_CARGO"):$PATH"
    fi
fi

if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found. Install Rust from https://rustup.rs and retry." >&2
    exit 1
fi

# Pick an Xcode. Prefer Xcode-beta when present, otherwise use the active
# developer directory, instead of hardcoding a path that may not exist.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    if [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
    else
        export DEVELOPER_DIR="$(xcode-select -p)"
    fi
fi
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"

# Remap $HOME so absolute source paths don't appear in the binary's log output
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${HOME}=/build"
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=${HOME}=/build"
export TARGET_CFLAGS="${TARGET_CFLAGS:-} -ffile-prefix-map=${HOME}=/build"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/rust-core"

echo "==> cargo: $(command -v cargo) ($(cargo --version))"
echo "==> DEVELOPER_DIR: $DEVELOPER_DIR"

echo "==> Installing iOS targets (if needed)"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true

echo "==> Building Rust static libs (release)"
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim

cd "$ROOT"
echo "==> Repackaging AirliftFFI.xcframework"
rm -rf "$ROOT/AirliftFFI.xcframework"
xcodebuild -create-xcframework \
  -library rust-core/target/aarch64-apple-ios/release/libairlift_ffi.a \
  -headers rust-core/include \
  -library rust-core/target/aarch64-apple-ios-sim/release/libairlift_ffi.a \
  -headers rust-core/include \
  -output "$ROOT/AirliftFFI.xcframework"

echo "==> Done."
echo "    Regenerate the Xcode project with: xcodegen generate"
