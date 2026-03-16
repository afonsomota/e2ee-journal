# libfhe_client — Native Rust FHE Client for Flutter

Rust crate that provides on-device FHE key generation, encryption, and decryption via C FFI. Flutter's Dart code calls into this library through `dart:ffi`.

## What It Does

| FFI Function | Purpose |
|---|---|
| `fhe_keygen` | Generate TFHE-rs keypair + Concrete evaluation keys |
| `fhe_encrypt_u8` | Encrypt quantized uint8 feature vector |
| `fhe_decrypt_i8` | Decrypt int8 inference result |
| `fhe_free_buf` / `fhe_free_i8_buf` | Free Rust-allocated buffers |

### Key Generation

`fhe_keygen` produces three buffers:

- **client_key** — TFHE-rs `ClientKey` (private, stored on-device in `flutter_secure_storage`)
- **server_key** — Concrete Cap'n Proto `ServerKeyset` (~120 MB, uploaded to backend `POST /fhe/key`)
- **lwe_key** — empty (ABI slot retained for compatibility)

The server key contains **4 seeded BSKs + 8 seeded KSKs** matching the multi-parameter circuit compiled in `client.zip`. Parameters are read from `client.specs.json` inside the compiled FHE model. Seed compression reduces the key from ~750 MB (uncompressed) to ~120 MB.

### Encryption / Decryption

- Encryption uses `FheUint8::encrypt` with `V0_10_PARAM_MESSAGE_2_CARRY_2_KS_PBS_GAUSSIAN_2M64`
- Output is bincode-serialized `Vec<FheUint8>`, compatible with `concrete-ml-extensions`
- Decryption reverses: bincode `Vec<FheInt8>` → raw `i8` scores (dequantized in Dart)

## Dependencies

| Crate | Purpose |
|---|---|
| `tfhe` (git rev `1ec21a5e`) | TFHE-rs — key generation, encrypt/decrypt, `core_crypto` for BSK/KSK |
| `capnp` / `capnpc` | Cap'n Proto serialization (Concrete's eval key wire format) |
| `bincode` + `serde` | Ciphertext serialization (TFHE-rs format) |
| `bytemuck` | Zero-copy u64↔u8 slice casting |

The `tfhe` git revision matches `concrete-ml-extensions 0.2.0` so ciphertexts are binary-compatible with the Python backend.

## Build

Requires `capnp` compiler (for schema):
```bash
brew install capnp    # macOS
apt install capnproto # Linux
```

### Development (macOS)
```bash
cargo build --release
# Output: target/release/libfhe_client.dylib
```

### iOS
```bash
# Prerequisites (one-time):
brew install rustup
rustup default stable
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

# Build XCFramework:
./build_ios.sh
# Output: ../ios/Frameworks/libfhe_client.xcframework
```

### Android
```bash
# Prerequisites: install NDK, add targets
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android

./build_android.sh
# Output: ../android/app/src/main/jniLibs/*/libfhe_client.so
```

## Flutter Integration

Dart loads the library in `lib/fhe/fhe_native.dart`:

```
iOS:     DynamicLibrary.process()          (static link via XCFramework)
Android: DynamicLibrary.open('libfhe_client.so')
macOS:   DynamicLibrary.open('libfhe_client.dylib')
```

The high-level flow in `lib/fhe/fhe_client.dart`:

1. `FheClient.setup()` → calls `fhe_keygen`, persists keys, returns base64 eval key
2. `FheClient.vectorizeAndEncrypt(text)` → TF-IDF + LSA + quantize + `fhe_encrypt_u8`
3. Backend runs FHE inference on encrypted data
4. `FheClient.decryptResult(b64)` → `fhe_decrypt_i8` + dequantize + argmax → emotion label

## Testing

```bash
cargo test -- --nocapture
```

The smoke test generates keys, validates the Cap'n Proto structure (4 BSKs, 8 KSKs), and writes `/tmp/rust_eval_key.bin` for cross-language comparison with the Python `FHEModelClient`.

## Project Structure

```
rust/
├── src/lib.rs                          # FFI exports + eval key generation
├── schema/concrete-protocol.capnp      # Concrete's Cap'n Proto schema
├── build.rs                            # capnpc schema compilation
├── build_ios.sh                        # iOS XCFramework build script
├── build_android.sh                    # Android .so build script
├── Cargo.toml
└── Cargo.lock
```
