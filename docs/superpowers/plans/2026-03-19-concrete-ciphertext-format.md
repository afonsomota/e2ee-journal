# Concrete Ciphertext Format Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `CiphertextFormat.CONCRETE` support to flutter_concrete so the Dart client works with `n_bits≤7` circuits without Python on-device.

**Architecture:** Extend the existing Rust FFI layer with 4 new functions for LWE encrypt/decrypt and Cap'n Proto Value serialize/deserialize. The Dart side adds a `ConcreteCipherInfo` class parsed from `client.specs.json` and routes `ConcreteClient` through the new or existing path based on detected format. No public API changes.

**Tech Stack:** Rust (tfhe core_crypto, capnp), Dart FFI, Cap'n Proto, Python (reference oracle only)

**Spec:** `docs/superpowers/specs/2026-03-19-concrete-ciphertext-format-design.md`

---

## File Map

### New files
- `emotion_ml/fhe/dump_reference.py` — Python reference oracle for cross-language validation
- `flutter_concrete/lib/src/concrete_cipher_info.dart` — `ConcreteCipherInfo` class (input/output LWE params, shapes, compression)

### Modified files
- `flutter_concrete/rust/schema/concrete-protocol.capnp` — add `Value`, `TypeInfo`, `LweCiphertextTypeInfo`, etc.
- `flutter_concrete/rust/src/lib.rs` — add `fhe_lwe_encrypt_seeded`, `fhe_lwe_decrypt_full`, `fhe_serialize_value`, `fhe_deserialize_value`
- `flutter_concrete/lib/src/fhe_native.dart` — add FFI bindings for 4 new functions
- `flutter_concrete/lib/src/client_zip_parser.dart` — parse `ConcreteCipherInfo` from circuit specs
- `flutter_concrete/lib/src/concrete_client.dart` — format detection and routing
- `flutter_concrete/test/client_zip_parser_test.dart` — tests for new parsing

---

## Task 1: Python Reference Oracle

**Files:**
- Create: `emotion_ml/fhe/dump_reference.py`

This script generates ground-truth data for validating every subsequent layer.

- [ ] **Step 1: Write the reference oracle script**

```python
"""Dump reference FHE encryption/decryption data for cross-language testing.

Outputs to emotion_ml/artifacts/fhe_reference/:
  - quantized_input.bin     : int64 quantized values (50 values)
  - serialized_value.bin    : Cap'n Proto Value bytes (what server.run() accepts)
  - server_result.bin       : Cap'n Proto Value bytes (server.run() output)
  - decrypted_output.bin    : int64 decrypted raw scores
  - dequantized_output.bin  : float64 dequantized scores
  - meta.json               : shapes, encoding params, n_cts, etc.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import joblib
import numpy as np
from concrete.ml.deployment import FHEModelClient, FHEModelServer

from config import ARTIFACTS_DIR, LABELS, SPLITS_DIR

def dump_reference():
    tfidf = joblib.load(ARTIFACTS_DIR / "tfidf_vectorizer.pkl")
    svd = joblib.load(ARTIFACTS_DIR / "svd.pkl")
    normalizer = joblib.load(ARTIFACTS_DIR / "normalizer.pkl")

    test_df = __import__("pandas").read_csv(SPLITS_DIR / "test.csv")
    texts = test_df["text"].values[:1]  # single sample

    X_tfidf = tfidf.transform(texts)
    X_lsa = normalizer.transform(svd.transform(X_tfidf))

    fhe_dir = str(ARTIFACTS_DIR / "fhe_model")
    key_dir = str(ARTIFACTS_DIR / "fhe_keys")

    client = FHEModelClient(path_dir=fhe_dir, key_dir=key_dir)
    server = FHEModelServer(path_dir=fhe_dir)
    server.load()

    eval_keys = client.get_serialized_evaluation_keys()

    # Quantize
    x_quant = client.model.quantize_input(X_lsa)

    # Encrypt (returns serialized Value bytes)
    encrypted = client.quantize_encrypt_serialize(X_lsa)

    # Server inference
    server_result = server.run(encrypted, eval_keys)
    if isinstance(server_result, tuple):
        server_result = server_result[0]

    # Decrypt
    result = client.deserialize_decrypt_dequantize(server_result)
    pred = int(np.argmax(result))

    # Save reference data
    out_dir = ARTIFACTS_DIR / "fhe_reference"
    out_dir.mkdir(exist_ok=True)

    np.array(x_quant, dtype=np.int64).tofile(out_dir / "quantized_input.bin")
    Path(out_dir / "serialized_value.bin").write_bytes(encrypted)
    Path(out_dir / "server_result.bin").write_bytes(server_result)
    np.array(result, dtype=np.float64).tofile(out_dir / "dequantized_output.bin")

    meta = {
        "n_features": int(X_lsa.shape[1]),
        "quantized_shape": list(x_quant.shape),
        "encrypted_size": len(encrypted),
        "server_result_size": len(server_result),
        "pred_label": LABELS[pred],
        "pred_index": pred,
        "scores": result.tolist() if hasattr(result, 'tolist') else [list(r) for r in result],
    }
    (out_dir / "meta.json").write_text(json.dumps(meta, indent=2))

    print(f"Reference data saved to {out_dir}")
    print(f"  Quantized input shape: {x_quant.shape}")
    print(f"  Encrypted size: {len(encrypted)} bytes")
    print(f"  Server result size: {len(server_result)} bytes")
    print(f"  Prediction: {LABELS[pred]} (scores: {result})")

if __name__ == "__main__":
    dump_reference()
```

- [ ] **Step 2: Run the oracle**

```bash
cd /home/dev/e2ee-journal/emotion_ml && source .venv/bin/activate && python fhe/dump_reference.py
```

Expected: Creates `emotion_ml/artifacts/fhe_reference/` with reference files. Prints encrypted size (~1464 bytes for CONCRETE format) and prediction.

- [ ] **Step 3: Verify reference data is reasonable**

```bash
cd /home/dev/e2ee-journal/emotion_ml && source .venv/bin/activate && python -c "
import json, pathlib
meta = json.loads(pathlib.Path('artifacts/fhe_reference/meta.json').read_text())
print(json.dumps(meta, indent=2))
assert meta['encrypted_size'] > 0
assert meta['server_result_size'] > 0
print('Reference data OK')
"
```

- [ ] **Step 4: Commit**

```bash
git add emotion_ml/fhe/dump_reference.py
git commit -m "feat: add Python reference oracle for cross-language FHE validation"
```

---

## Task 2: Extend Cap'n Proto Schema

**Files:**
- Modify: `flutter_concrete/rust/schema/concrete-protocol.capnp`

Add the `Value` message and related types that Concrete uses for ciphertext transport. These extend the existing schema (which already has `ServerKeyset`, `Payload`, `Shape`, `RawInfo`, `Compression`).

- [ ] **Step 1: Add new types to the schema**

Append to `flutter_concrete/rust/schema/concrete-protocol.capnp`:

```capnp
# ── Ciphertext transport types ──────────────────────────────────────────────

struct Value {
  payload @0 :Payload;
  rawInfo @1 :RawInfo;
  typeInfo @2 :TypeInfo;
}

struct TypeInfo {
  union {
    lweCiphertext @0 :LweCiphertextTypeInfo;
    plaintext @1 :PlaintextTypeInfo;
    index @2 :IndexTypeInfo;
  }
}

struct PlaintextTypeInfo {}
struct IndexTypeInfo {}

struct LweCiphertextTypeInfo {
  abstractShape @0 :Shape;
  concreteShape @1 :Shape;
  integerPrecision @2 :UInt32;
  encryption @3 :LweCiphertextEncryptionInfo;
  compression @4 :Compression;
  encoding :union {
    integer @5 :IntegerCiphertextEncodingInfo;
    boolean @6 :BooleanCiphertextEncodingInfo;
  }
}

struct LweCiphertextEncryptionInfo {
  keyId @0 :UInt32;
  variance @1 :Float64;
  lweDimension @2 :UInt32;
  modulus @3 :Modulus;
}

struct IntegerCiphertextEncodingInfo {
  width @0 :UInt32;
  isSigned @1 :Bool;
  mode :union {
    native @2 :NativeMode;
    chunked @3 :ChunkedMode;
    crt @4 :CrtMode;
  }
}

struct NativeMode {}
struct ChunkedMode {
  size @0 :UInt32;
  width @1 :UInt32;
}
struct CrtMode {
  moduli @0 :List(UInt32);
}

struct BooleanCiphertextEncodingInfo {}
```

- [ ] **Step 2: Verify schema compiles**

The Rust build system compiles capnp schemas via `build.rs`. Since we don't have Rust toolchain locally, verify the schema is syntactically correct:

```bash
# If capnp CLI is available:
capnp compile -o /dev/null flutter_concrete/rust/schema/concrete-protocol.capnp 2>&1 || echo "capnp CLI not available — will verify on first cargo build"
```

- [ ] **Step 3: Commit**

```bash
git add flutter_concrete/rust/schema/concrete-protocol.capnp
git commit -m "feat: extend capnp schema with Value and ciphertext type info"
```

---

## Task 3: Rust — Seeded LWE Encryption

**Files:**
- Modify: `flutter_concrete/rust/src/lib.rs`

Add `fhe_lwe_encrypt_seeded` FFI function. This bit-decomposes quantized values and encrypts each bit as a seeded LWE ciphertext.

- [ ] **Step 1: Add the encrypt function**

Add to `flutter_concrete/rust/src/lib.rs`, before the existing `fhe_encrypt` function:

```rust
/// Encrypt quantized values using Concrete's seeded LWE encoding.
///
/// Each value is bit-decomposed into `encoding_width` individual bits (LSB first).
/// Each bit is encrypted as a separate seeded LWE ciphertext with Delta = 2^62.
///
/// Output layout: [seed_16bytes || b_0 || b_1 || ... || b_{n_vals*width-1}]
/// where each b_i is one u64.
///
/// # Safety
/// All pointer arguments must not be null. `values` must have `n_vals` elements.
/// Free output with `fhe_free_buf`.
#[no_mangle]
pub unsafe extern "C" fn fhe_lwe_encrypt_seeded(
    client_key: *const u8, client_key_len: usize,
    values: *const i64, n_vals: usize,
    encoding_width: u32,
    lwe_dimension: u32,
    variance: f64,
    ct_out: *mut *mut u8, ct_len: *mut usize,
) -> i32 {
    match panic::catch_unwind(|| -> Result<(), String> {
        let ck_bytes = slice::from_raw_parts(client_key, client_key_len);
        let vals = slice::from_raw_parts(values, n_vals);
        let ck: ClientKey = safe_deserialize(Cursor::new(ck_bytes), LIMIT)
            .map_err(|e| e.to_string())?;

        let width = encoding_width as usize;
        let lwe_dim = lwe_dimension as usize;
        let n_cts = n_vals * width;

        // Extract LWE secret key from ClientKey (SK[0])
        let (integer_ck, _, _, _) = ck.into_raw_parts();
        let shortint_ck = integer_ck.into_raw_parts();
        let (glwe_sk, _, _) = shortint_ck.into_raw_parts();
        let lwe_sk = glwe_sk.into_lwe_secret_key();

        assert_eq!(lwe_sk.lwe_dimension().0, lwe_dim,
            "ClientKey LWE dimension {} != expected {}", lwe_sk.lwe_dimension().0, lwe_dim);

        // Generate seed
        let mut seeder = new_seeder();
        let seed = seeder.as_mut().seed();
        let seed_bytes: [u8; 16] = seed.0.to_le_bytes();

        // Create seeded encryption generator from the same seed
        let mut encryption_generator =
            tfhe::core_crypto::commons::generators::EncryptionRandomGenerator::<
                DefaultRandomGenerator,
            >::new(seed.into(), seeder.as_mut());

        // Bit-decompose and encrypt
        let delta: u64 = 1u64 << 62; // width=1 per bit ciphertext
        let noise = Gaussian::from_dispersion_parameter(
            StandardDev(variance.sqrt()), 0.0);

        let mut b_values: Vec<u64> = Vec::with_capacity(n_cts);

        for &val in vals {
            for bit_idx in 0..width {
                let bit = ((val as u64 >> bit_idx) & 1) as u64;
                let encoded = bit.wrapping_mul(delta);

                // Generate random a vector and compute b = <a, s> + noise + encoded
                let mut a_vec = vec![0u64; lwe_dim];
                encryption_generator.fill_slice_with_random_mask(&mut a_vec);

                let mut dot: u64 = 0;
                for (a_i, s_i) in a_vec.iter().zip(lwe_sk.as_ref().iter()) {
                    dot = dot.wrapping_add(a_i.wrapping_mul(*s_i));
                }

                let noise_sample: u64 = encryption_generator
                    .random_noise_from_distribution(noise);
                let b = dot.wrapping_add(noise_sample).wrapping_add(encoded);
                b_values.push(b);
            }
        }

        // Output: seed || b-values as bytes
        let b_bytes = bytemuck::cast_slice::<u64, u8>(&b_values);
        let mut output = Vec::with_capacity(16 + b_bytes.len());
        output.extend_from_slice(&seed_bytes);
        output.extend_from_slice(b_bytes);

        let (ptr, len) = leak_buf(output);
        *ct_out = ptr;
        *ct_len = len;
        Ok(())
    }) {
        Ok(Ok(())) => 0,
        Ok(Err(_)) => -1,
        Err(_) => -2,
    }
}
```

**Important notes for implementer:**
- The `EncryptionRandomGenerator` API may differ from what's shown above. Consult the TFHE-rs docs for the exact `fill_slice_with_random_mask` and `random_noise_from_distribution` method signatures at rev `1ec21a5`.
- The CSPRNG must match what Concrete's server uses to expand seeds. TFHE-rs's `EncryptionRandomGenerator<DefaultRandomGenerator>` is the correct one (AES-128-CTR via `concrete-csprng`).
- If the generator API doesn't expose `fill_slice_with_random_mask` and `random_noise_from_distribution` directly, use `encrypt_seeded_lwe_ciphertext_list` from `tfhe::core_crypto::algorithms` instead — it handles the seed-based encryption loop internally.

- [ ] **Step 2: Write a Rust unit test for encrypt round-trip**

Add to `mod tests` in `lib.rs`:

```rust
#[test]
fn lwe_encrypt_seeded_round_trip() {
    let config = ConfigBuilder::default()
        .use_custom_parameters(V0_10_PARAM_MESSAGE_2_CARRY_2_KS_PBS_GAUSSIAN_2M64)
        .build();
    let (client_key, _) = tfhe::generate_keys(config);

    // Serialize client key
    let mut ck_buf = Vec::new();
    safe_serialize(&client_key, &mut ck_buf, LIMIT).unwrap();

    // Test values: 3-bit unsigned (0-7)
    let values: Vec<i64> = vec![0, 1, 3, 5, 7];
    let width: u32 = 3;
    let lwe_dim: u32 = 2048; // matches V0_10 parameter set
    let variance: f64 = 8.442253112932959e-31;

    // Encrypt
    let mut ct_ptr: *mut u8 = std::ptr::null_mut();
    let mut ct_len: usize = 0;
    let rc = unsafe {
        fhe_lwe_encrypt_seeded(
            ck_buf.as_ptr(), ck_buf.len(),
            values.as_ptr(), values.len(),
            width, lwe_dim, variance,
            &mut ct_ptr, &mut ct_len,
        )
    };
    assert_eq!(rc, 0, "fhe_lwe_encrypt_seeded failed");

    // Verify output size: 16 (seed) + 5*3*8 (b-values) = 136 bytes
    assert_eq!(ct_len, 16 + 5 * 3 * 8);

    // To verify correctness: manually expand seed, reconstruct a vectors,
    // compute plaintext = b - <a, s>, decode each bit, reassemble values.
    // (Full decrypt test will be added in Task 4)

    unsafe { fhe_free_buf(ct_ptr, ct_len) };
}
```

- [ ] **Step 3: Verify test compiles and passes**

```bash
cd flutter_concrete/rust && cargo test lwe_encrypt_seeded_round_trip -- --nocapture
```

Expected: Test passes, output size is `16 + n_vals * width * 8`.

- [ ] **Step 4: Commit**

```bash
git add flutter_concrete/rust/src/lib.rs
git commit -m "feat(rust): add fhe_lwe_encrypt_seeded for Concrete format"
```

---

## Task 4: Rust — Full LWE Decryption

**Files:**
- Modify: `flutter_concrete/rust/src/lib.rs`

Add `fhe_lwe_decrypt_full` FFI function. Decrypts full (uncompressed) LWE ciphertexts using Concrete's round-to-nearest decoding.

- [ ] **Step 1: Add the decrypt function**

Add to `flutter_concrete/rust/src/lib.rs`:

```rust
/// Decrypt full (uncompressed) LWE ciphertexts using Concrete's decoding.
///
/// Each ciphertext is `lwe_dimension + 1` u64 values: [a_0, ..., a_n, b].
/// Decryption: plaintext = b - <a, s>
/// Decoding (round-to-nearest):
///   shift = 64 - width - 1
///   decoded = ((plaintext + (1 << (shift-1))) >> shift) & ((1 << width) - 1)
///   if signed and decoded >= 2^(width-1): decoded -= 2^width
///
/// # Safety
/// `ct` must point to `n_cts * (lwe_dimension + 1) * 8` bytes.
/// Free output with `fhe_free_i64_buf`.
#[no_mangle]
pub unsafe extern "C" fn fhe_lwe_decrypt_full(
    client_key: *const u8, client_key_len: usize,
    ct: *const u8, ct_len: usize,
    n_cts: u32,
    encoding_width: u32, is_signed: u32,
    lwe_dimension: u32,
    scores_out: *mut *mut i64, scores_len: *mut usize,
) -> i32 {
    match panic::catch_unwind(|| -> Result<(), String> {
        let ck_bytes = slice::from_raw_parts(client_key, client_key_len);
        let ck: ClientKey = safe_deserialize(Cursor::new(ck_bytes), LIMIT)
            .map_err(|e| e.to_string())?;

        let lwe_dim = lwe_dimension as usize;
        let ct_size = lwe_dim + 1; // u64 elements per ciphertext
        let n = n_cts as usize;
        let width = encoding_width as usize;
        let signed = is_signed != 0;

        // Verify input size
        let expected_bytes = n * ct_size * 8;
        if ct_len != expected_bytes {
            return Err(format!(
                "ct_len {} != expected {} (n_cts={}, ct_size={})",
                ct_len, expected_bytes, n, ct_size
            ));
        }

        let ct_u64 = slice::from_raw_parts(ct as *const u64, n * ct_size);

        // Extract LWE secret key
        let (integer_ck, _, _, _) = ck.into_raw_parts();
        let shortint_ck = integer_ck.into_raw_parts();
        let (glwe_sk, _, _) = shortint_ck.into_raw_parts();
        let lwe_sk = glwe_sk.into_lwe_secret_key();

        let shift = 64 - width - 1;
        let half: u64 = 1u64 << (shift - 1);
        let mask: u64 = (1u64 << width) - 1;

        let mut results = Vec::with_capacity(n);
        for i in 0..n {
            let base = i * ct_size;
            let a = &ct_u64[base..base + lwe_dim];
            let b = ct_u64[base + lwe_dim];

            // Decrypt: plaintext = b - <a, s>
            let mut dot: u64 = 0;
            for (a_j, s_j) in a.iter().zip(lwe_sk.as_ref().iter()) {
                dot = dot.wrapping_add(a_j.wrapping_mul(*s_j));
            }
            let plaintext = b.wrapping_sub(dot);

            // Decode: round-to-nearest
            let decoded = (plaintext.wrapping_add(half) >> shift) & mask;

            let value = if signed && decoded >= (1u64 << (width - 1)) {
                decoded as i64 - (1i64 << width)
            } else {
                decoded as i64
            };

            results.push(value);
        }

        let len = results.len();
        let ptr = Box::into_raw(results.into_boxed_slice()) as *mut i64;
        *scores_out = ptr;
        *scores_len = len;
        Ok(())
    }) {
        Ok(Ok(())) => 0,
        Ok(Err(_)) => -1,
        Err(_) => -2,
    }
}
```

- [ ] **Step 2: Write a Rust test for encrypt→decrypt round-trip**

This test encrypts with `fhe_lwe_encrypt_seeded`, manually expands the seeded ciphertexts to full ciphertexts, then decrypts with `fhe_lwe_decrypt_full` and verifies values match.

```rust
#[test]
fn lwe_seeded_encrypt_then_full_decrypt_round_trip() {
    let config = ConfigBuilder::default()
        .use_custom_parameters(V0_10_PARAM_MESSAGE_2_CARRY_2_KS_PBS_GAUSSIAN_2M64)
        .build();
    let (client_key, _) = tfhe::generate_keys(config);

    let mut ck_buf = Vec::new();
    safe_serialize(&client_key, &mut ck_buf, LIMIT).unwrap();

    let values: Vec<i64> = vec![0, 1, 3, 5, 7];
    let width: u32 = 3;
    let lwe_dim: u32 = 2048;
    let variance: f64 = 8.442253112932959e-31;

    // Encrypt (seeded)
    let mut ct_ptr: *mut u8 = std::ptr::null_mut();
    let mut ct_len: usize = 0;
    let rc = unsafe {
        fhe_lwe_encrypt_seeded(
            ck_buf.as_ptr(), ck_buf.len(),
            values.as_ptr(), values.len(),
            width, lwe_dim, variance,
            &mut ct_ptr, &mut ct_len,
        )
    };
    assert_eq!(rc, 0);

    let ct_bytes = unsafe { slice::from_raw_parts(ct_ptr, ct_len) }.to_vec();
    unsafe { fhe_free_buf(ct_ptr, ct_len) };

    // Expand seeded ciphertexts to full ciphertexts for decrypt test.
    // Extract seed (first 16 bytes) and b-values.
    let seed_bytes: [u8; 16] = ct_bytes[0..16].try_into().unwrap();
    let seed = tfhe::core_crypto::commons::math::random::Seed(
        u128::from_le_bytes(seed_bytes));
    let b_values: &[u64] = bytemuck::cast_slice(&ct_bytes[16..]);

    let n_cts = values.len() * width as usize;
    assert_eq!(b_values.len(), n_cts);

    // Recreate CSPRNG from seed to regenerate a-vectors
    let mut seeder = new_seeder();
    let mut enc_gen = tfhe::core_crypto::commons::generators::EncryptionRandomGenerator::<
        DefaultRandomGenerator,
    >::new(seed.into(), seeder.as_mut());

    // Build full ciphertexts: [a_0..a_n, b] for each
    let ct_size = lwe_dim as usize + 1;
    let mut full_ct = vec![0u64; n_cts * ct_size];
    for i in 0..n_cts {
        let base = i * ct_size;
        enc_gen.fill_slice_with_random_mask(&mut full_ct[base..base + lwe_dim as usize]);
        full_ct[base + lwe_dim as usize] = b_values[i];
    }

    let full_ct_bytes = bytemuck::cast_slice::<u64, u8>(&full_ct);

    // Decrypt each bit-ciphertext individually (width=1, unsigned)
    let mut scores_ptr: *mut i64 = std::ptr::null_mut();
    let mut scores_len: usize = 0;
    let rc = unsafe {
        fhe_lwe_decrypt_full(
            ck_buf.as_ptr(), ck_buf.len(),
            full_ct_bytes.as_ptr(), full_ct_bytes.len(),
            n_cts as u32,
            1,  // width=1 per bit
            0,  // unsigned
            lwe_dim,
            &mut scores_ptr, &mut scores_len,
        )
    };
    assert_eq!(rc, 0);
    assert_eq!(scores_len, n_cts);

    let bits = unsafe { slice::from_raw_parts(scores_ptr, scores_len) }.to_vec();
    unsafe { fhe_free_i64_buf(scores_ptr, scores_len) };

    // Reassemble bits into values (LSB first)
    for (i, &orig_val) in values.iter().enumerate() {
        let mut reassembled: i64 = 0;
        for bit_idx in 0..width as usize {
            reassembled |= (bits[i * width as usize + bit_idx] & 1) << bit_idx;
        }
        assert_eq!(reassembled, orig_val, "value[{}] mismatch", i);
    }
}
```

- [ ] **Step 3: Run both tests**

```bash
cd flutter_concrete/rust && cargo test -- --nocapture
```

Expected: Both `lwe_encrypt_seeded_round_trip` and `lwe_seeded_encrypt_then_full_decrypt_round_trip` pass.

- [ ] **Step 4: Commit**

```bash
git add flutter_concrete/rust/src/lib.rs
git commit -m "feat(rust): add fhe_lwe_decrypt_full with round-to-nearest decoding"
```

---

## Task 5: Rust — Value Serialization & Deserialization

**Files:**
- Modify: `flutter_concrete/rust/src/lib.rs`

Add `fhe_serialize_value` and `fhe_deserialize_value` FFI functions using the Cap'n Proto types from Task 2.

- [ ] **Step 1: Add serialize function**

```rust
/// Serialize raw ciphertext bytes into a Cap'n Proto Value message.
///
/// `ct_data`: raw bytes (seeded: seed+b-values; full: n_cts*(lwe_dim+1) u64s)
/// `shape`/`abstract_shape`: concrete and abstract shapes as u32 arrays
/// `compression`: 0=none, 1=seed
///
/// # Safety
/// All pointer arguments must not be null. Free output with `fhe_free_buf`.
#[no_mangle]
pub unsafe extern "C" fn fhe_serialize_value(
    ct_data: *const u8, ct_len: usize,
    shape: *const u32, shape_len: usize,
    abstract_shape: *const u32, abstract_shape_len: usize,
    encoding_width: u32, is_signed: u32,
    lwe_dimension: u32, key_id: u32, variance: f64,
    compression: u32,
    out: *mut *mut u8, out_len: *mut usize,
) -> i32 {
    match panic::catch_unwind(|| -> Result<(), String> {
        let ct_bytes = slice::from_raw_parts(ct_data, ct_len);
        let shape_vals = slice::from_raw_parts(shape, shape_len);
        let abstract_shape_vals = slice::from_raw_parts(abstract_shape, abstract_shape_len);

        let mut message = Builder::new_default();
        {
            use concrete_protocol_capnp::value;
            let mut val = message.init_root::<value::Builder<'_>>();

            // Payload: single Data entry
            let mut payload = val.reborrow().init_payload();
            let mut data_list = payload.reborrow().init_data(1);
            data_list.set(0, ct_bytes);

            // RawInfo: isSigned is always false (raw u64 container)
            let mut raw_info = val.reborrow().init_raw_info();
            {
                let mut s = raw_info.reborrow().init_shape();
                let mut dims = s.init_dimensions(shape_vals.len() as u32);
                for (i, &d) in shape_vals.iter().enumerate() {
                    dims.set(i as u32, d);
                }
            }
            raw_info.set_integer_precision(64);
            raw_info.set_is_signed(false);

            // TypeInfo: lweCiphertext
            let mut type_info = val.reborrow().init_type_info();
            let mut lwe_info = type_info.init_lwe_ciphertext();

            // Abstract shape
            {
                let mut s = lwe_info.reborrow().init_abstract_shape();
                let mut dims = s.init_dimensions(abstract_shape_vals.len() as u32);
                for (i, &d) in abstract_shape_vals.iter().enumerate() {
                    dims.set(i as u32, d);
                }
            }

            // Concrete shape
            {
                let mut s = lwe_info.reborrow().init_concrete_shape();
                let mut dims = s.init_dimensions(shape_vals.len() as u32);
                for (i, &d) in shape_vals.iter().enumerate() {
                    dims.set(i as u32, d);
                }
            }

            lwe_info.set_integer_precision(64);

            // Encryption info
            {
                let mut enc = lwe_info.reborrow().init_encryption();
                enc.set_key_id(key_id);
                enc.set_variance(variance);
                enc.set_lwe_dimension(lwe_dimension);
                enc.init_modulus().reborrow().get_modulus().init_native();
            }

            // Compression
            let comp = match compression {
                0 => concrete_protocol_capnp::Compression::None,
                1 => concrete_protocol_capnp::Compression::Seed,
                _ => return Err(format!("unknown compression {}", compression)),
            };
            lwe_info.set_compression(comp);

            // Encoding: integer, native mode
            let mut encoding = lwe_info.init_encoding().init_integer();
            encoding.set_width(encoding_width);
            encoding.set_is_signed(is_signed != 0);
            encoding.init_mode().set_native(());
        }

        let mut buf: Vec<u8> = Vec::new();
        serialize::write_message(&mut buf, &message).map_err(|e| e.to_string())?;

        let (ptr, len) = leak_buf(buf);
        *out = ptr;
        *out_len = len;
        Ok(())
    }) {
        Ok(Ok(())) => 0,
        Ok(Err(_)) => -1,
        Err(_) => -2,
    }
}
```

- [ ] **Step 2: Add deserialize function**

```rust
/// Deserialize a Cap'n Proto Value message, extracting raw ciphertext bytes.
///
/// # Safety
/// `data` must point to `data_len` bytes of Cap'n Proto message.
/// Free output with `fhe_free_buf`.
#[no_mangle]
pub unsafe extern "C" fn fhe_deserialize_value(
    data: *const u8, data_len: usize,
    ct_out: *mut *mut u8, ct_len: *mut usize,
    n_cts_out: *mut u32,
) -> i32 {
    match panic::catch_unwind(|| -> Result<(), String> {
        let bytes = slice::from_raw_parts(data, data_len);

        let mut opts = capnp::message::ReaderOptions::new();
        opts.traversal_limit_in_words(Some(1 << 30)); // ~8 GB for large outputs
        let reader = serialize::read_message(bytes, opts)
            .map_err(|e| e.to_string())?;
        let value = reader
            .get_root::<concrete_protocol_capnp::value::Reader<'_>>()
            .map_err(|e| e.to_string())?;

        // Extract payload
        let payload = value.get_payload().map_err(|e| e.to_string())?;
        let data_list = payload.get_data().map_err(|e| e.to_string())?;
        if data_list.len() == 0 {
            return Err("Value has empty payload".into());
        }
        let raw_data = data_list.get(0);

        // Determine n_cts from concrete shape and compression
        let type_info = value.get_type_info();
        let lwe_info = type_info.which()
            .map_err(|e| format!("TypeInfo: {}", e))?;

        let n_cts = match lwe_info {
            concrete_protocol_capnp::type_info::Which::LweCiphertext(info) => {
                let info = info.map_err(|e| e.to_string())?;
                let concrete_shape = info.get_concrete_shape()
                    .map_err(|e| e.to_string())?;
                let dims = concrete_shape.get_dimensions()
                    .map_err(|e| e.to_string())?;
                // Total elements = product of all dims except the last
                // (last dim is either width for seeded, or lwe_dim+1 for full)
                let mut total: u32 = 1;
                for i in 0..dims.len().saturating_sub(1) {
                    total *= dims.get(i);
                }
                total
            }
            _ => return Err("TypeInfo is not lweCiphertext".into()),
        };

        // Copy payload to output buffer
        let output = raw_data.to_vec();
        let (ptr, len) = leak_buf(output);
        *ct_out = ptr;
        *ct_len = len;
        *n_cts_out = n_cts;
        Ok(())
    }) {
        Ok(Ok(())) => 0,
        Ok(Err(_)) => -1,
        Err(_) => -2,
    }
}
```

- [ ] **Step 3: Write serialize/deserialize round-trip test**

```rust
#[test]
fn value_serialize_deserialize_round_trip() {
    let payload = vec![0u8; 136]; // fake seeded data: 16 seed + 15*8 b-values
    let shape: Vec<u32> = vec![1, 5, 3];
    let abstract_shape: Vec<u32> = vec![1, 5];

    let mut out_ptr: *mut u8 = std::ptr::null_mut();
    let mut out_len: usize = 0;

    let rc = unsafe {
        fhe_serialize_value(
            payload.as_ptr(), payload.len(),
            shape.as_ptr(), shape.len(),
            abstract_shape.as_ptr(), abstract_shape.len(),
            3, 0, // width=3, unsigned
            2048, 0, 8.442253112932959e-31, // lwe_dim, key_id, variance
            1, // compression=seed
            &mut out_ptr, &mut out_len,
        )
    };
    assert_eq!(rc, 0);
    assert!(out_len > 0);

    let serialized = unsafe { slice::from_raw_parts(out_ptr, out_len) }.to_vec();
    unsafe { fhe_free_buf(out_ptr, out_len) };

    // Deserialize
    let mut ct_ptr: *mut u8 = std::ptr::null_mut();
    let mut ct_len: usize = 0;
    let mut n_cts: u32 = 0;

    let rc = unsafe {
        fhe_deserialize_value(
            serialized.as_ptr(), serialized.len(),
            &mut ct_ptr, &mut ct_len, &mut n_cts,
        )
    };
    assert_eq!(rc, 0);
    assert_eq!(ct_len, 136);
    assert_eq!(n_cts, 5); // product of shape dims except last: 1*5=5

    let recovered = unsafe { slice::from_raw_parts(ct_ptr, ct_len) }.to_vec();
    unsafe { fhe_free_buf(ct_ptr, ct_len) };

    assert_eq!(payload, recovered);
}
```

- [ ] **Step 4: Run all tests**

```bash
cd flutter_concrete/rust && cargo test -- --nocapture
```

Expected: All 4 tests pass (existing eval key test + 3 new tests).

- [ ] **Step 5: Commit**

```bash
git add flutter_concrete/rust/src/lib.rs
git commit -m "feat(rust): add fhe_serialize_value and fhe_deserialize_value"
```

---

## Task 6: Cross-Language Integration Test

**Files:**
- Create: `emotion_ml/fhe/test_cross_language.py`

Test that Rust-encrypted values are accepted by the Python `FHEModelServer`. This requires building the Rust library first, then calling it from a Python test via ctypes/subprocess.

Since the Rust library isn't runnable from Python directly, this test is structured as a two-step process:
1. A Rust integration test that encrypts+serializes, writes to a file
2. A Python script that reads the file and runs it through the server

- [ ] **Step 1: Write a Rust integration test that dumps encrypted values**

Add to `lib.rs` tests:

```rust
/// Integration test: encrypt a known vector, serialize as Value, write to file.
/// Run emotion_ml/fhe/test_cross_language.py afterwards to verify with Python server.
#[test]
#[ignore] // Run manually: cargo test cross_language_dump -- --ignored --nocapture
fn cross_language_dump() {
    use std::fs;
    use std::path::Path;

    let config = ConfigBuilder::default()
        .use_custom_parameters(V0_10_PARAM_MESSAGE_2_CARRY_2_KS_PBS_GAUSSIAN_2M64)
        .build();
    let (client_key, _) = tfhe::generate_keys(config);

    let mut ck_buf = Vec::new();
    safe_serialize(&client_key, &mut ck_buf, LIMIT).unwrap();

    // Use reference quantized input if available, otherwise use test values
    let ref_path = Path::new("../../emotion_ml/artifacts/fhe_reference/quantized_input.bin");
    let values: Vec<i64> = if ref_path.exists() {
        let bytes = fs::read(ref_path).unwrap();
        bytemuck::cast_slice::<u8, i64>(&bytes).to_vec()
    } else {
        vec![3, 0, 7, 1, 5] // fallback test values
    };

    let width: u32 = 3;
    let lwe_dim: u32 = 2048;
    let variance: f64 = 8.442253112932959e-31;

    // Encrypt
    let mut ct_ptr: *mut u8 = std::ptr::null_mut();
    let mut ct_len: usize = 0;
    let rc = unsafe {
        fhe_lwe_encrypt_seeded(
            ck_buf.as_ptr(), ck_buf.len(),
            values.as_ptr(), values.len(),
            width, lwe_dim, variance,
            &mut ct_ptr, &mut ct_len,
        )
    };
    assert_eq!(rc, 0);
    let ct_bytes = unsafe { slice::from_raw_parts(ct_ptr, ct_len) }.to_vec();
    unsafe { fhe_free_buf(ct_ptr, ct_len) };

    // Serialize as Value
    let n_vals = values.len() as u32;
    let shape: Vec<u32> = vec![1, n_vals, width];
    let abstract_shape: Vec<u32> = vec![1, n_vals];

    let mut val_ptr: *mut u8 = std::ptr::null_mut();
    let mut val_len: usize = 0;
    let rc = unsafe {
        fhe_serialize_value(
            ct_bytes.as_ptr(), ct_bytes.len(),
            shape.as_ptr(), shape.len(),
            abstract_shape.as_ptr(), abstract_shape.len(),
            width, 0, lwe_dim, 0, variance,
            1, // seed compression
            &mut val_ptr, &mut val_len,
        )
    };
    assert_eq!(rc, 0);
    let serialized = unsafe { slice::from_raw_parts(val_ptr, val_len) }.to_vec();
    unsafe { fhe_free_buf(val_ptr, val_len) };

    // Also dump the eval key
    let topo = Topology {
        sks: vec![/* read from client.specs.json or hardcode test topology */],
        bsks: vec![],
        ksks: vec![],
    };
    // For full integration, topology must match the compiled model.
    // The test at this stage just validates the wire format.

    let out_dir = Path::new("../../emotion_ml/artifacts/fhe_reference");
    fs::create_dir_all(out_dir).unwrap();
    fs::write(out_dir.join("rust_encrypted.bin"), &serialized).unwrap();
    fs::write(out_dir.join("rust_client_key.bin"), &ck_buf).unwrap();

    println!("Wrote rust_encrypted.bin ({} bytes)", serialized.len());
    println!("Wrote rust_client_key.bin ({} bytes)", ck_buf.len());
}
```

**Note:** Full cross-language integration requires the Rust-encrypted values to use the same key that generates the eval keys the server has. This means key generation must happen first (keygen produces client key + eval key), eval key uploaded to server, then the same client key used for encryption. The test above is a starting point — full integration will be validated in Task 9 (Dart end-to-end).

- [ ] **Step 2: Commit**

```bash
git add flutter_concrete/rust/src/lib.rs emotion_ml/fhe/test_cross_language.py
git commit -m "test: add cross-language integration scaffolding"
```

---

## Task 7: Dart — ConcreteCipherInfo & ClientZipParser

**Files:**
- Create: `flutter_concrete/lib/src/concrete_cipher_info.dart`
- Modify: `flutter_concrete/lib/src/client_zip_parser.dart`
- Modify: `flutter_concrete/test/client_zip_parser_test.dart`

- [ ] **Step 1: Write the test for ConcreteCipherInfo parsing**

Add to `flutter_concrete/test/client_zip_parser_test.dart`:

```dart
test('extracts ConcreteCipherInfo from client.specs.json', () {
  final result = ClientZipParser.parse(zipBytes);
  final inputInfo = result.inputCipherInfo;
  final outputInfo = result.outputCipherInfo;

  // Input: seeded, unsigned, native mode
  expect(inputInfo, isNotNull);
  expect(inputInfo!.compression, ConcreteCipherCompression.seed);
  expect(inputInfo.lweDimension, isPositive);
  expect(inputInfo.keyId, isA<int>());
  expect(inputInfo.variance, isPositive);
  expect(inputInfo.encodingWidth, isPositive);
  expect(inputInfo.encodingIsSigned, isFalse);
  expect(inputInfo.isNativeMode, isTrue);
  expect(inputInfo.concreteShape, isNotEmpty);
  expect(inputInfo.abstractShape, isNotEmpty);

  // Output: uncompressed, signed, native mode
  expect(outputInfo, isNotNull);
  expect(outputInfo!.compression, ConcreteCipherCompression.none);
  expect(outputInfo.encodingIsSigned, isTrue);
  expect(outputInfo.isNativeMode, isTrue);
});

test('ConcreteCipherInfo is null for TFHE-rs format specs', () {
  // Minimal specs without lweCiphertext.encryption (TFHE-rs format)
  final specs = _minimalSpecs();
  // _minimalSpecs doesn't include encryption info, so ConcreteCipherInfo should be null
  final proc = {
    'input_quantizers': [
      {
        'serialized_value': {'scale': 0.01, 'zero_point': 0}
      }
    ],
    'output_quantizers': [
      {
        'serialized_value': {'scale': 0.01, 'zero_point': 0, 'offset': 0}
      }
    ],
  };
  final zip = _createZipWithProcessingAndSpecs(proc, specs);
  final result = ClientZipParser.parse(zip);
  expect(result.inputCipherInfo, isNull);
  expect(result.outputCipherInfo, isNull);
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd flutter_concrete && flutter test test/client_zip_parser_test.dart -v
```

Expected: FAIL — `ParseResult` doesn't have `inputCipherInfo`/`outputCipherInfo` yet.

- [ ] **Step 3: Create ConcreteCipherInfo class**

Create `flutter_concrete/lib/src/concrete_cipher_info.dart`:

```dart
/// Compression mode for LWE ciphertexts.
enum ConcreteCipherCompression { none, seed }

/// LWE encryption and encoding parameters parsed from client.specs.json.
///
/// One instance per circuit gate (input or output).
class ConcreteCipherInfo {
  final int lweDimension;
  final int keyId;
  final double variance;
  final ConcreteCipherCompression compression;
  final int encodingWidth;
  final bool encodingIsSigned;
  final bool isNativeMode;
  final List<int> concreteShape;
  final List<int> abstractShape;

  const ConcreteCipherInfo({
    required this.lweDimension,
    required this.keyId,
    required this.variance,
    required this.compression,
    required this.encodingWidth,
    required this.encodingIsSigned,
    required this.isNativeMode,
    required this.concreteShape,
    required this.abstractShape,
  });
}
```

- [ ] **Step 4: Update ClientZipParser and ParseResult**

Add `inputCipherInfo` and `outputCipherInfo` to `ParseResult`:

```dart
class ParseResult {
  final QuantizationParams quantParams;
  final KeyTopology topology;
  final CircuitEncoding encoding;
  final ConcreteCipherInfo? inputCipherInfo;
  final ConcreteCipherInfo? outputCipherInfo;

  const ParseResult({
    required this.quantParams,
    required this.topology,
    required this.encoding,
    this.inputCipherInfo,
    this.outputCipherInfo,
  });
}
```

In `ClientZipParser.parse()`, after parsing `CircuitEncoding`, add parsing of `ConcreteCipherInfo` from the circuit inputs/outputs. Extract from `typeInfo.lweCiphertext`:
- `encryption.lweDimension`, `encryption.keyId`, `encryption.variance`
- `compression` (string → enum)
- `encoding.integer.width`, `encoding.integer.isSigned`
- `encoding.integer.mode` (check for `native` key)
- `concreteShape.dimensions`, `abstractShape.dimensions`

Return `null` if `encryption` field is missing (indicates TFHE-rs format where these fields aren't populated).

```dart
static ConcreteCipherInfo? _parseCipherInfo(Map<String, dynamic> typeInfo) {
  final lweCtInfo = typeInfo['lweCiphertext'] as Map<String, dynamic>?;
  if (lweCtInfo == null) return null;

  final encryption = lweCtInfo['encryption'] as Map<String, dynamic>?;
  if (encryption == null) return null;

  final compressionStr = lweCtInfo['compression'] as String? ?? 'none';
  final compression = compressionStr == 'seed'
      ? ConcreteCipherCompression.seed
      : ConcreteCipherCompression.none;

  final encodingWrapper = lweCtInfo['encoding'] as Map<String, dynamic>?;
  final integer = encodingWrapper?['integer'] as Map<String, dynamic>?;
  if (integer == null) return null;

  final mode = integer['mode'] as Map<String, dynamic>?;
  final isNative = mode != null && mode.containsKey('native');

  final concreteShapeMap = lweCtInfo['concreteShape'] as Map<String, dynamic>?;
  final concreteShape = (concreteShapeMap?['dimensions'] as List<dynamic>?)
          ?.map((d) => (d as num).toInt())
          .toList() ??
      [];

  final abstractShapeMap = lweCtInfo['abstractShape'] as Map<String, dynamic>?;
  final abstractShape = (abstractShapeMap?['dimensions'] as List<dynamic>?)
          ?.map((d) => (d as num).toInt())
          .toList() ??
      [];

  return ConcreteCipherInfo(
    lweDimension: (encryption['lweDimension'] as num).toInt(),
    keyId: (encryption['keyId'] as num).toInt(),
    variance: (encryption['variance'] as num).toDouble(),
    compression: compression,
    encodingWidth: (integer['width'] as num).toInt(),
    encodingIsSigned: integer['isSigned'] as bool,
    isNativeMode: isNative,
    concreteShape: concreteShape,
    abstractShape: abstractShape,
  );
}
```

Call `_parseCipherInfo` for input and output typeInfo maps, pass results to `ParseResult`.

- [ ] **Step 5: Run tests**

```bash
cd flutter_concrete && flutter test test/client_zip_parser_test.dart -v
```

Expected: All tests pass, including new `ConcreteCipherInfo` tests.

- [ ] **Step 6: Commit**

```bash
git add flutter_concrete/lib/src/concrete_cipher_info.dart flutter_concrete/lib/src/client_zip_parser.dart flutter_concrete/test/client_zip_parser_test.dart
git commit -m "feat(dart): parse ConcreteCipherInfo from client.specs.json"
```

---

## Task 8: Dart — FheNative New Methods

**Files:**
- Modify: `flutter_concrete/lib/src/fhe_native.dart`

Add FFI bindings for the 4 new Rust functions.

- [ ] **Step 1: Add C function typedefs and lookups**

Add these typedefs alongside the existing ones in `fhe_native.dart`:

```dart
// fhe_lwe_encrypt_seeded
typedef _FheLweEncryptSeededC = Int32 Function(
    Pointer<Uint8>, Size,           // client_key
    Pointer<Int64>, Size,           // values
    Uint32,                         // encoding_width
    Uint32,                         // lwe_dimension
    Float64,                        // variance
    Pointer<Pointer<Uint8>>, Pointer<Size>);  // ct_out
typedef _FheLweEncryptSeededDart = int Function(
    Pointer<Uint8>, int,
    Pointer<Int64>, int,
    int, int, double,
    Pointer<Pointer<Uint8>>, Pointer<Size>);

// fhe_lwe_decrypt_full
typedef _FheLweDecryptFullC = Int32 Function(
    Pointer<Uint8>, Size,           // client_key
    Pointer<Uint8>, Size,           // ct
    Uint32,                         // n_cts
    Uint32, Uint32,                 // encoding_width, is_signed
    Uint32,                         // lwe_dimension
    Pointer<Pointer<Int64>>, Pointer<Size>);  // scores_out
typedef _FheLweDecryptFullDart = int Function(
    Pointer<Uint8>, int,
    Pointer<Uint8>, int,
    int, int, int, int,
    Pointer<Pointer<Int64>>, Pointer<Size>);

// fhe_serialize_value
typedef _FheSerializeValueC = Int32 Function(
    Pointer<Uint8>, Size,           // ct_data
    Pointer<Uint32>, Size,          // shape
    Pointer<Uint32>, Size,          // abstract_shape
    Uint32, Uint32,                 // encoding_width, is_signed
    Uint32, Uint32, Float64,        // lwe_dim, key_id, variance
    Uint32,                         // compression
    Pointer<Pointer<Uint8>>, Pointer<Size>);  // out
typedef _FheSerializeValueDart = int Function(
    Pointer<Uint8>, int,
    Pointer<Uint32>, int,
    Pointer<Uint32>, int,
    int, int, int, int, double, int,
    Pointer<Pointer<Uint8>>, Pointer<Size>);

// fhe_deserialize_value
typedef _FheDeserializeValueC = Int32 Function(
    Pointer<Uint8>, Size,
    Pointer<Pointer<Uint8>>, Pointer<Size>,
    Pointer<Uint32>);
typedef _FheDeserializeValueDart = int Function(
    Pointer<Uint8>, int,
    Pointer<Pointer<Uint8>>, Pointer<Size>,
    Pointer<Uint32>);
```

- [ ] **Step 2: Add method implementations**

Add methods to `FheNative`:

```dart
Uint8List lweEncryptSeeded(Uint8List clientKey, Int64List values,
    int encodingWidth, int lweDimension, double variance) {
  final ckPtr = _toNativeUint8(clientKey);
  final valPtr = malloc<Int64>(values.length);
  for (int i = 0; i < values.length; i++) valPtr[i] = values[i];
  final ctPtrPtr = malloc<Pointer<Uint8>>();
  final ctLen = malloc<Size>();
  try {
    final rc = _lweEncryptSeeded(ckPtr, clientKey.length, valPtr, values.length,
        encodingWidth, lweDimension, variance, ctPtrPtr, ctLen);
    if (rc != 0) throw StateError('fhe_lwe_encrypt_seeded failed (code $rc)');
    return _readAndFree(ctPtrPtr.value, ctLen.value);
  } finally {
    malloc.free(ckPtr); malloc.free(valPtr);
    malloc.free(ctPtrPtr); malloc.free(ctLen);
  }
}

Int64List lweDecryptFull(Uint8List clientKey, Uint8List ciphertext,
    int nCts, int encodingWidth, bool isSigned, int lweDimension) {
  final ckPtr = _toNativeUint8(clientKey);
  final ctPtr = _toNativeUint8(ciphertext);
  final outPtrPtr = malloc<Pointer<Int64>>();
  final outLen = malloc<Size>();
  try {
    final rc = _lweDecryptFull(ckPtr, clientKey.length, ctPtr, ciphertext.length,
        nCts, encodingWidth, isSigned ? 1 : 0, lweDimension, outPtrPtr, outLen);
    if (rc != 0) throw StateError('fhe_lwe_decrypt_full failed (code $rc)');
    final len = outLen.value;
    final result = Int64List(len);
    for (int i = 0; i < len; i++) result[i] = outPtrPtr.value[i];
    _freeI64Buf(outPtrPtr.value, len);
    return result;
  } finally {
    malloc.free(ckPtr); malloc.free(ctPtr);
    malloc.free(outPtrPtr); malloc.free(outLen);
  }
}

Uint8List serializeValue(Uint8List ctData, List<int> shape, List<int> abstractShape,
    int encodingWidth, bool isSigned,
    int lweDimension, int keyId, double variance, int compression) {
  final ctPtr = _toNativeUint8(ctData);
  final shapePtr = malloc<Uint32>(shape.length);
  for (int i = 0; i < shape.length; i++) shapePtr[i] = shape[i];
  final absShapePtr = malloc<Uint32>(abstractShape.length);
  for (int i = 0; i < abstractShape.length; i++) absShapePtr[i] = abstractShape[i];
  final outPtrPtr = malloc<Pointer<Uint8>>();
  final outLen = malloc<Size>();
  try {
    final rc = _serializeValue(ctPtr, ctData.length,
        shapePtr, shape.length, absShapePtr, abstractShape.length,
        encodingWidth, isSigned ? 1 : 0,
        lweDimension, keyId, variance, compression,
        outPtrPtr, outLen);
    if (rc != 0) throw StateError('fhe_serialize_value failed (code $rc)');
    return _readAndFree(outPtrPtr.value, outLen.value);
  } finally {
    malloc.free(ctPtr); malloc.free(shapePtr); malloc.free(absShapePtr);
    malloc.free(outPtrPtr); malloc.free(outLen);
  }
}

(Uint8List, int) deserializeValue(Uint8List data) {
  final dataPtr = _toNativeUint8(data);
  final ctPtrPtr = malloc<Pointer<Uint8>>();
  final ctLen = malloc<Size>();
  final nCtsPtr = malloc<Uint32>();
  try {
    final rc = _deserializeValue(dataPtr, data.length, ctPtrPtr, ctLen, nCtsPtr);
    if (rc != 0) throw StateError('fhe_deserialize_value failed (code $rc)');
    final ct = _readAndFree(ctPtrPtr.value, ctLen.value);
    return (ct, nCtsPtr.value);
  } finally {
    malloc.free(dataPtr); malloc.free(ctPtrPtr);
    malloc.free(ctLen); malloc.free(nCtsPtr);
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add flutter_concrete/lib/src/fhe_native.dart
git commit -m "feat(dart): add FFI bindings for Concrete LWE encrypt/decrypt/serialize"
```

---

## Task 9: Dart — ConcreteClient Format Routing

**Files:**
- Modify: `flutter_concrete/lib/src/concrete_client.dart`

- [ ] **Step 1: Store ConcreteCipherInfo from setup**

Add fields and update `setup()`:

```dart
ConcreteCipherInfo? _inputCipherInfo;
ConcreteCipherInfo? _outputCipherInfo;
```

In `setup()`, after parsing:

```dart
_inputCipherInfo = result.inputCipherInfo;
_outputCipherInfo = result.outputCipherInfo;
```

In `reset()`, add:

```dart
_inputCipherInfo = null;
_outputCipherInfo = null;
```

- [ ] **Step 2: Update quantizeAndEncrypt**

```dart
Uint8List quantizeAndEncrypt(Float32List features) {
  _requireReady();
  final quantized = _quantParams!.quantizeInputs(features);

  if (_inputCipherInfo != null) {
    final info = _inputCipherInfo!;
    if (!info.isNativeMode) {
      throw UnsupportedError(
          'ConcreteClient: only native encoding mode is supported');
    }
    // Concrete LWE path: seeded encrypt → serialize as Value
    final ct = _native.lweEncryptSeeded(
      _clientKey!, quantized,
      info.encodingWidth, info.lweDimension, info.variance,
    );
    return _native.serializeValue(
      ct, info.concreteShape, info.abstractShape,
      info.encodingWidth, info.encodingIsSigned,
      info.lweDimension, info.keyId, info.variance,
      info.compression == ConcreteCipherCompression.seed ? 1 : 0,
    );
  }

  // TFHE-rs path (existing)
  return _native.encrypt(
    _clientKey!, quantized,
    _encoding!.tfheInputBitWidth, _encoding!.inputIsSigned,
  );
}
```

- [ ] **Step 3: Update decryptAndDequantize**

```dart
Float64List decryptAndDequantize(Uint8List ciphertext) {
  _requireReady();

  if (_outputCipherInfo != null) {
    final info = _outputCipherInfo!;
    if (!info.isNativeMode) {
      throw UnsupportedError(
          'ConcreteClient: only native encoding mode is supported');
    }
    // Concrete LWE path: deserialize Value → full decrypt
    final (ctData, nCts) = _native.deserializeValue(ciphertext);
    final rawScores = _native.lweDecryptFull(
      _clientKey!, ctData,
      nCts, info.encodingWidth, info.encodingIsSigned, info.lweDimension,
    );
    return _quantParams!.dequantizeOutputs(rawScores);
  }

  // TFHE-rs path (existing)
  final rawScores = _native.decrypt(
    _clientKey!, ciphertext,
    _encoding!.tfheOutputBitWidth, _encoding!.outputIsSigned,
  );
  return _quantParams!.dequantizeOutputs(rawScores);
}
```

- [ ] **Step 4: Add import for ConcreteCipherInfo**

Add to top of `concrete_client.dart`:

```dart
import 'concrete_cipher_info.dart';
```

- [ ] **Step 5: Run existing tests**

```bash
cd flutter_concrete && flutter test -v
```

Expected: All existing tests still pass (they don't use the native library, so the new FFI methods aren't called).

- [ ] **Step 6: Commit**

```bash
git add flutter_concrete/lib/src/concrete_client.dart
git commit -m "feat(dart): route ConcreteClient through Concrete LWE or TFHE-rs path"
```

---

## Task 10: End-to-End Validation

This task validates the full pipeline: Flutter app → backend.

- [ ] **Step 1: Build the Rust library**

```bash
cd flutter_concrete/rust && cargo build --release
```

Requires Rust toolchain. The library (`libfhe_client.so` / `.dylib`) must be on the library path for Flutter tests.

- [ ] **Step 2: Run the Flutter app against the backend**

```bash
# Terminal 1: Start backend
cd journal_backend && source .venv/bin/activate && LOG_LEVEL=DEBUG uvicorn main:app --reload --port 8000

# Terminal 2: Run Flutter app
cd journal_app && flutter run
```

Write a journal entry and verify:
- Emotion badge appears after FHE computation
- Backend logs show FHE inference completing
- No errors in Flutter console

- [ ] **Step 3: Compare predictions with Python oracle**

The emotion predictions from the Dart client should match the Python reference oracle's predictions for the same text input. Minor differences are acceptable due to different random noise in encryption, but the argmax (top emotion) should match in most cases.

- [ ] **Step 4: Final commit and update CLAUDE.md**

Update `flutter_concrete/CLAUDE.md` to remove the "CiphertextFormat limitation" section and document the new Concrete format support. Update the main `CLAUDE.md` to reflect the new capability.

```bash
git add -A && git commit -m "feat: end-to-end CiphertextFormat.CONCRETE support in flutter_concrete"
```
