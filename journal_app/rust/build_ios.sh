#!/usr/bin/env bash
# journal_app/rust/build_ios.sh
#
# Build the fhe_client Rust library for iOS and package it as an XCFramework.
#
# Prerequisites:
#   brew install rustup
#   /opt/homebrew/opt/rustup/bin/rustup default stable
#   /opt/homebrew/opt/rustup/bin/rustup target add \
#       aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#   Xcode command-line tools installed
#
# Output:
#   ../ios/Frameworks/libfhe_client.xcframework
#   (Dart FFI loads this at runtime via DynamicLibrary.open)
#
# Usage:
#   cd journal_app/rust && ./build_ios.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Locate rustup-managed cargo ───────────────────────────────────────────────
# Homebrew's standalone rustc cannot cross-compile to iOS (no target std libs).
# We need rustup's toolchain cargo, which knows where the target stdlibs live.
#
# Detection order:
#   1. Homebrew rustup (brew install rustup) — toolchain cargo in Cellar
#   2. Standard rustup (~/.cargo/env)

_find_toolchain_cargo() {
  # Homebrew rustup: the proxy bin and the resolved Cellar path are the same rustup,
  # but we must call the toolchain's own cargo (not the proxy) so rustc uses the
  # correct sysroot.  The symlink opt/rustup -> Cellar/rustup/<ver> gives us a
  # stable path to the toolchain dir.
  local brew_rustup_opt="/opt/homebrew/opt/rustup"
  if [ -x "$brew_rustup_opt/bin/rustup" ]; then
    # Resolve the versioned Cellar path (where the sysroot actually lives).
    local cellar
    cellar="$(realpath "$brew_rustup_opt")"
    local toolchain_dir
    toolchain_dir="$(ls -d "$cellar"/lib/rustlib/toolchains/stable-*/  2>/dev/null | head -1)"
    if [ -x "$toolchain_dir/bin/cargo" ]; then
      export RUSTUP_HOME="$cellar/lib/rustlib"
      RUSTUP="$brew_rustup_opt/bin/rustup"
      CARGO="$toolchain_dir/bin/cargo"
      return 0
    fi
  fi
  # Standard rustup via ~/.cargo/env
  if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
    if command -v rustup &>/dev/null && command -v cargo &>/dev/null; then
      RUSTUP="$(command -v rustup)"
      CARGO="$(command -v cargo)"
      return 0
    fi
  fi
  return 1
}

if ! _find_toolchain_cargo; then
  echo "ERROR: rustup is required (Homebrew's standalone rustc cannot cross-compile to iOS)."
  echo ""
  echo "  brew install rustup"
  echo "  /opt/homebrew/opt/rustup/bin/rustup default stable"
  echo "  /opt/homebrew/opt/rustup/bin/rustup target add \\"
  echo "      aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios"
  exit 1
fi

REQUIRED_TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)
MISSING=()
for t in "${REQUIRED_TARGETS[@]}"; do
  if ! "$RUSTUP" target list --installed 2>/dev/null | grep -q "^$t$"; then
    MISSING+=("$t")
  fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: Missing rustup targets: ${MISSING[*]}"
  echo "Run: $RUSTUP target add ${MISSING[*]}"
  exit 1
fi

echo "==> Using cargo: $CARGO"

LIB_NAME="libfhe_client.a"
XCFW_DIR="$SCRIPT_DIR/../ios/Frameworks/libfhe_client.xcframework"

echo "==> Building for iOS device (arm64)..."
"$CARGO" build --release --target aarch64-apple-ios

echo "==> Building for iOS Simulator (arm64 - Apple Silicon Macs)..."
"$CARGO" build --release --target aarch64-apple-ios-sim

echo "==> Building for iOS Simulator (x86_64 - Intel Macs)..."
"$CARGO" build --release --target x86_64-apple-ios

echo "==> Creating fat simulator library..."
mkdir -p /tmp/fhe_client_build/sim
lipo -create \
  "target/aarch64-apple-ios-sim/release/$LIB_NAME" \
  "target/x86_64-apple-ios/release/$LIB_NAME" \
  -output "/tmp/fhe_client_build/sim/$LIB_NAME"

echo "==> Generating C header..."
cat > /tmp/fhe_client_build/fhe_client.h << 'HEADER'
// fhe_client.h — generated header for TFHE-rs FHE client FFI
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t fhe_keygen(
    uint8_t **client_key_out, size_t *client_key_len,
    uint8_t **server_key_out, size_t *server_key_len,
    uint8_t **lwe_key_out,    size_t *lwe_key_len);

int32_t fhe_encrypt_u8(
    const uint8_t *client_key, size_t client_key_len,
    const uint8_t *values,     size_t n_vals,
    uint8_t **ct_out, size_t *ct_len);

int32_t fhe_decrypt_i8(
    const uint8_t *client_key, size_t client_key_len,
    const uint8_t *ct,         size_t ct_len,
    int8_t **scores_out, size_t *scores_len);

void fhe_free_buf(uint8_t *ptr, size_t len);
void fhe_free_i8_buf(int8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif
HEADER

echo "==> Creating XCFramework..."
rm -rf "$XCFW_DIR"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/release/$LIB_NAME" \
  -headers /tmp/fhe_client_build/fhe_client.h \
  -library "/tmp/fhe_client_build/sim/$LIB_NAME" \
  -headers /tmp/fhe_client_build/fhe_client.h \
  -output "$XCFW_DIR"

echo "==> Done: $XCFW_DIR"
rm -rf /tmp/fhe_client_build
