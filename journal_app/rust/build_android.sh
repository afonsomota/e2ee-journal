#!/usr/bin/env bash
# journal_app/rust/build_android.sh
#
# Build the fhe_client Rust library for Android ABI targets.
#
# Prerequisites:
#   cargo install cargo-ndk
#   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
#   Android NDK installed (set ANDROID_NDK_HOME or NDK_HOME)
#
# Output:
#   ../android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libfhe_client.so
#
# Usage:
#   cd journal_app/rust && ./build_android.sh [api_level]
#   Default API level: 24 (Android 7.0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

API_LEVEL="${1:-24}"
JNI_DIR="$SCRIPT_DIR/../android/app/src/main/jniLibs"

echo "==> Building Android libraries (API level $API_LEVEL)..."

build_abi() {
    local target="$1"
    local abi="$2"
    echo "  Building $abi ($target)..."
    cargo ndk --target "$target" --platform "$API_LEVEL" -- build --release
    mkdir -p "$JNI_DIR/$abi"
    cp "target/$target/release/libfhe_client.so" "$JNI_DIR/$abi/libfhe_client.so"
    echo "  Copied: $JNI_DIR/$abi/libfhe_client.so"
}

build_abi aarch64-linux-android  arm64-v8a
build_abi armv7-linux-androideabi armeabi-v7a
build_abi x86_64-linux-android   x86_64

echo "==> Done. Libraries in $JNI_DIR"
