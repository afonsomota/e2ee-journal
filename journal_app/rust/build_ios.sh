#!/usr/bin/env bash
# journal_app/rust/build_ios.sh
#
# Build the fhe_client Rust library for iOS and package it as an XCFramework.
#
# Prerequisites:
#   brew install rustup-init && rustup-init -y
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
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

LIB_NAME="libfhe_client.a"
XCFW_DIR="$SCRIPT_DIR/../ios/Frameworks/libfhe_client.xcframework"

echo "==> Building for iOS device (arm64)..."
cargo build --release --target aarch64-apple-ios

echo "==> Building for iOS Simulator (arm64 - Apple Silicon Macs)..."
cargo build --release --target aarch64-apple-ios-sim

echo "==> Building for iOS Simulator (x86_64 - Intel Macs)..."
cargo build --release --target x86_64-apple-ios

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
