# Debug: Cap'n Proto Value Mismatch

## Problem

The Rust FFI function `fhe_serialize_value` produces a Cap'n Proto `Value` message that is the correct size (1,464 bytes, matching Python's output), but the Concrete C++ runtime rejects it with:

```
RuntimeError: Tried to transform a transport value with incompatible payload size.
```

This happens when `FHEModelServer.run()` processes our Rust-generated ciphertext on the backend.

## Context

We added `CiphertextFormat.CONCRETE` support to the `flutter_concrete` plugin. The flow:

1. Dart quantizes input → calls Rust `fhe_lwe_encrypt_seeded` → seeded LWE ciphertext bytes
2. Dart calls Rust `fhe_serialize_value` → Cap'n Proto `Value` message (1,464 bytes)
3. Dart sends to backend `/fhe/predict`
4. Backend calls `FHEModelServer.run(encrypted_input, eval_keys)` → **FAILS HERE**

The same backend works fine when the Python `FHEModelClient` generates the ciphertext.

## What works

- Python reference: encrypt → server.run() → decrypt works end-to-end
- Rust keygen: produces valid eval keys (18 MB, backend accepts upload, 200 OK)
- Rust encrypt: produces 1,216 bytes payload (16-byte seed + 150 × 8-byte b-values)
- Rust serialize: wraps payload in Cap'n Proto Value → 1,464 bytes total
- Both Python and Rust produce 1,464-byte serialized Values

## Files involved

- **Rust serialization**: `flutter_concrete/rust/src/lib.rs` — `fhe_serialize_value` function (around line 694)
- **Cap'n Proto schema**: `flutter_concrete/rust/schema/concrete-protocol.capnp` — `Value`, `TypeInfo`, `LweCiphertextTypeInfo` structs (line 164+)
- **Python reference**: `emotion_ml/artifacts/fhe_reference/encrypted_input.bin` — 1,464 bytes, the exact output of Python's `FHEModelClient.quantize_encrypt_serialize()`
- **Backend endpoint**: `journal_backend/routers/fhe.py` — `predict()` calls `server.run()`

## Model specs (from `journal_app/assets/fhe/client.zip` → `client.specs.json`)

```json
{
  "circuits": [{
    "inputs": [{
      "rawInfo": {
        "shape": {"dimensions": [1, 50, 3]},
        "integerPrecision": 64,
        "isSigned": false
      },
      "typeInfo": {
        "lweCiphertext": {
          "abstractShape": {"dimensions": [1, 50]},
          "concreteShape": {"dimensions": [1, 50, 3]},
          "integerPrecision": 64,
          "encryption": {
            "keyId": 0,
            "variance": 8.442253112932959e-31,
            "lweDimension": 2048
          },
          "compression": "seed",
          "encoding": {
            "integer": {"width": 3, "isSigned": false, "mode": {"native": {}}}
          }
        }
      }
    }]
  }]
}
```

## What to do

1. **Byte-level diff** between `emotion_ml/artifacts/fhe_reference/encrypted_input.bin` (Python) and a Rust-generated Value. To get the Rust output, either:
   - Add a Rust test that calls `fhe_serialize_value` with the same payload and writes to a file
   - Or use the Dart integration test (`flutter_concrete/test/integration_test.dart`) to save the bytes

2. **Parse both Cap'n Proto messages** field by field and compare:
   - Root struct pointer layout (data words, pointer words)
   - Payload → data list → entry size
   - RawInfo → shape dimensions, integerPrecision, isSigned
   - TypeInfo → LweCiphertextTypeInfo → all fields (shapes, encryption, compression, encoding)

3. **Likely suspects** for the mismatch:
   - Field ordering in the Cap'n Proto schema not matching Concrete's canonical schema
   - Missing or extra fields that change the struct layout
   - The `Modulus` nested struct inside `LweCiphertextEncryptionInfo` — our schema may nest it differently from Concrete's
   - The encoding union discriminant (integer vs boolean) offset

4. **Where to find Concrete's canonical schema**: The original `.capnp` file is in the concrete-compiler repo at `compilers/concrete-compiler/compiler/lib/Bindings/Python/concrete/compiler/`. It can also be extracted from the installed Python package. Check `concrete.compiler` or search for `.capnp` files in the emotion_ml venv:
   ```bash
   find emotion_ml/.venv -name "*.capnp" 2>/dev/null
   ```

## Environment

- Backend venv: `journal_backend/.venv` (Python 3.11, concrete-ml)
- ML venv: `emotion_ml/.venv` (Python 3.11, concrete-ml)
- Rust: `~/.cargo/bin` (rustc 1.94.0), build with `cd flutter_concrete/rust && cargo build`
- Dart tests: `cd flutter_concrete && LD_LIBRARY_PATH=rust/target/debug flutter test test/integration_test.dart`
- Backend: `cd journal_backend && source .venv/bin/activate && uvicorn main:app --port 8000`
