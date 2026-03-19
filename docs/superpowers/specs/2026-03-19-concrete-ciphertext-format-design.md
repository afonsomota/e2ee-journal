# Concrete Ciphertext Format Support in flutter_concrete

## Problem

flutter_concrete only speaks TFHE-rs wire format, which forces `n_bits=8` and produces impractically large circuits. The model compiles with `CiphertextFormat.CONCRETE` and `n_bits=3`, but end-to-end FHE only works via the Python `FHEModelClient`.

## Goal

Support `CiphertextFormat.CONCRETE` in flutter_concrete so the native Dart client works with `n_bits=3` circuits. No public API changes. E2EE preserved — encryption/decryption stays on-device.

## Key Facts

- Concrete uses Cap'n Proto for ciphertext serialization — same schema already used for eval keys
- Wire format: Cap'n Proto `Value` message with `Payload`, `RawInfo`, `TypeInfo`
- **Bit decomposition (inputs only)**: Each `n`-bit value is decomposed into `n` individual 1-bit LWE ciphertexts. Per-bit encoding: `bit_value << 62` (Delta = 2^62, always width=1 per ciphertext regardless of the integer's `encoding_width`)
- **No bit decomposition (outputs)**: Each output ciphertext directly encodes a multi-bit value. Encoding: `value << (64 - width - 1)` (e.g. Delta = 2^60 for width=3)
- **Input compression**: `seed` — only `(seed, b_values)` stored, `a` vectors derived from TFHE-rs's `EncryptionRandomGenerator<DefaultRandomGenerator>` (AES-128-CTR). Same CSPRNG the server uses to expand seeds during evaluation. This makes inputs tiny (~1464 bytes for 50 features at 3-bit: 16-byte seed + 150 × 8 bytes)
- **Output compression**: `none` — full `(a, b)` LWE ciphertexts. Output is ~4 MB for 250 ciphertexts of dimension 2048
- **Shape semantics**: Last dimension of `concreteShape` differs by compression: for seeded inputs `[1,50,3]` the `3` = bit count per value; for uncompressed outputs `[1,5,50,2049]` the `2049` = `lwe_dimension + 1`
- **`rawInfo.isSigned`** is always `false` (raw u64 container). The logical signedness comes from `encoding.integer.isSigned`

### Concrete shapes (from current model's `client.specs.json`)

| | Abstract Shape | Concrete Shape | Compression | LWE Dim | Encoding |
|---|---|---|---|---|---|
| Input | [1, 50] | [1, 50, 3] | seed | 2048 | 3-bit unsigned, native |
| Output | [1, 5, 50] | [1, 5, 50, 2049] | none | 2048 | 3-bit signed, native |

50 features → 150 bit-ciphertexts (seeded) in. 5 classes × 50 trees = 250 full LWE ciphertexts out.

## Scope

- Native encoding mode only. Fail-fast on chunked/CRT.
- Any `width` (1-7) and signedness, not hardcoded to 3.
- Support both seeded (input) and uncompressed (output) ciphertexts.
- No public API changes to `ConcreteClient`.

## Architecture

### Rust FFI — 4 new C functions

```
fhe_lwe_encrypt_seeded(
    client_key, client_key_len,
    values, n_vals,              // quantized integers (pre-bit-decomposition)
    encoding_width,              // e.g. 3 — each value decomposed into this many bits
    lwe_dimension,               // from specs (e.g. 2048)
    variance,                    // from specs
    ct_out, ct_len               // output: seed (16 bytes) + n_vals*width b-values (u64)
) -> i32
```

Extracts LWE secret key from TFHE-rs ClientKey. Bit-decomposes each value into `encoding_width` individual bits (LSB first). Generates a fresh 128-bit seed, derives `a` vectors via TFHE-rs `EncryptionRandomGenerator<DefaultRandomGenerator>` (AES-128-CTR CSPRNG — must match the server's seed expansion). Encrypts each bit with Delta = 2^62 (always width=1 per ciphertext, NOT `encoding_width`): `b = <a,s> + noise + (bit << 62)`. Outputs `(seed_16bytes || b_0 || b_1 || ... || b_{n_vals*encoding_width-1})` where each `b` is one u64.

```
fhe_lwe_decrypt_full(
    client_key, client_key_len,
    ct, ct_len,                  // full LWE ciphertexts: n_cts * (lwe_dim+1) u64s
    n_cts,                       // number of ciphertexts
    encoding_width, is_signed,   // for decoding
    lwe_dimension,
    scores_out, scores_len       // output: n_cts decoded integer values
) -> i32
```

For each ciphertext: LWE decrypts `plaintext = b - <a,s>`, then applies round-to-nearest decoding:
```
shift = 64 - width - 1
half = 1 << (shift - 1)
decoded = ((plaintext + half) >> shift) & ((1 << width) - 1)
if is_signed and (decoded >= (1 << (width - 1))):
    decoded -= (1 << width)
```

Outputs one i64 per ciphertext. Dart-side `dequantizeOutputs` handles tree aggregation (250 values → 5 class scores).

```
fhe_serialize_value(
    ct_data, ct_len,             // raw ciphertext bytes (seeded or full)
    shape, shape_len,            // concrete shape as u32 array (e.g. [1,50,3])
    abstract_shape, abstract_shape_len,  // abstract shape (e.g. [1,50])
    encoding_width, is_signed,
    lwe_dimension, key_id, variance,
    compression,                 // 0=none, 1=seed
    out, out_len
) -> i32
```

Builds Cap'n Proto `Value` message with correct `Payload` (single `Data` entry, not chunked), `RawInfo` (note: `isSigned` is always `false` here — raw u64 container), `TypeInfo.lweCiphertext` (encoding params from specs).

```
fhe_deserialize_value(
    data, data_len,
    ct_out, ct_len,
    n_cts_out                    // number of ciphertexts
) -> i32
```

Extracts raw ciphertext bytes from Cap'n Proto `Value`.

### Cap'n Proto Schema

Extend existing `concrete-protocol.capnp` with types from Concrete's canonical schema:

- `Value { payload, rawInfo, typeInfo }`
- `RawInfo { shape, integerPrecision, isSigned }`
- `TypeInfo { union { lweCiphertext, plaintext, index } }`
- `LweCiphertextTypeInfo { abstractShape, concreteShape, integerPrecision, encryption, compression, encoding }`
- `LweCiphertextEncryptionInfo { keyId, variance, lweDimension, modulus }`
- `IntegerCiphertextEncodingInfo { width, isSigned, mode: union { native, chunked, crt } }`

### Dart — FheNative

4 new methods: `lweEncryptSeeded`, `lweDecryptFull`, `serializeValue`, `deserializeValue`.

### Dart — ClientZipParser

Additionally extract from circuit inputs/outputs `TypeInfo`:
- `lweDimension`, `keyId`, `variance` from `encryption`
- `compression` (seed vs none)
- `concreteShape`, `abstractShape`
- Encoding mode and width

Store in a new internal `ConcreteCipherInfo` class (one for input, one for output).

### Dart — ConcreteClient

`quantizeAndEncrypt` and `decryptAndDequantize` detect format from parsed specs:
- Concrete LWE encoding present → `lweEncryptSeeded → serializeValue` / `deserializeValue → lweDecryptFull`
- TFHE-rs encoding (tfhers_specs non-null) → existing `fhe_encrypt` path
- Chunked/CRT → throw `UnsupportedError`

No public signature changes.

## Verification Plan

1. **Python reference oracle** (`emotion_ml/fhe/dump_reference.py`): Encrypt a known sample, dump quantized values, bit-decomposed values, raw seeded ciphertext bytes, serialized Value bytes, and decrypted output. Also test reverse: encrypt in Python → dump → verify Rust can decrypt.

2. **Rust LWE round-trip** (`cargo test`): Bit-decompose + seeded encrypt → full decrypt (expand seed to get `a` vectors) → assert values match. Pure math.

3. **Rust serialization round-trip** (`cargo test`): Serialize → deserialize → assert bytes match. Compare Cap'n Proto structure against Python reference dump.

4. **Cross-language integration** (Python + Rust): Rust encrypts+serializes → Python `FHEModelServer.run()` → Rust deserializes+decrypts → assert predictions match Python oracle.

5. **Dart end-to-end**: Full `ConcreteClient` flow against running backend. Assert emotion predictions match.
