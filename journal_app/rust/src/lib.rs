// journal_app/rust/src/lib.rs
//
// Native TFHE-rs FHE client — C FFI layer for Dart.
//
// Serialisation compatibility:
//   • Key generation matches concrete-ml-extensions (cml-ext 0.2.0) keygen_radix()
//   • Encryption matches cml-ext encrypt_serialize_u8_radix_2d()
//   • Decryption matches cml-ext decrypt_serialized_i8_radix_2d()
//   • Parameter set: PARAM_MESSAGE_2_CARRY_2_KS_PBS
//
// Exported C functions (return 0 on success, negative code on failure):
//   fhe_keygen(ck_out, ck_len, sk_out, sk_len, lwe_out, lwe_len) → i32
//   fhe_encrypt_u8(ck, ck_len, vals, n, ct_out, ct_len) → i32
//   fhe_decrypt_i8(ck, ck_len, ct, ct_len, out, out_len) → i32
//   fhe_free_buf(ptr, len)
//   fhe_free_i8_buf(ptr, len)

use std::io::Cursor;
use std::panic;
use std::slice;

use tfhe::prelude::*;
use tfhe::safe_serialization::{safe_deserialize, safe_serialize};
use tfhe::shortint::client_key::atomic_pattern::AtomicPatternClientKey;
use tfhe::shortint::parameters::PARAM_MESSAGE_2_CARRY_2_KS_PBS;
use tfhe::{ClientKey, ConfigBuilder, FheInt8, FheUint8};

// ── Serialisation limit ───────────────────────────────────────────────────────
const LIMIT: u64 = 1_000_000_000;

// ── LWE key extraction ────────────────────────────────────────────────────────
//
// Mirrors concrete-ml-extensions keygen_radix():
//   ClientKey → IntegerClientKey → ShortintClientKey → AtomicPatternClientKey::Standard
//   → StandardAtomicPatternClientKey → glwe_secret_key → into_lwe_secret_key()
//
// The resulting LweSecretKey is serialised with safe_serialize and sent to the
// server so it can call keygen_with_initial_keys({0: lwe_key}) on the concrete
// bridge, linking TFHE-rs ciphertexts to the compiled FHE circuit.
fn extract_and_serialise_lwe_key(ck: &ClientKey) -> Result<Vec<u8>, String> {
    let (integer_ck, _, _, _, _) = ck.clone().into_raw_parts();
    let shortint_ck = integer_ck.into_raw_parts();

    let AtomicPatternClientKey::Standard(std_ck) = shortint_ck.atomic_pattern else {
        return Err("unexpected atomic pattern variant — expected Standard".into());
    };

    let (glwe_secret_key, _lwe_secret_key, _params, _wopbs) = std_ck.into_raw_parts();
    // The GLWE key is the "big" encryption key when EncryptionKeyChoice::Big is set,
    // which is the case for PARAM_MESSAGE_2_CARRY_2_KS_PBS.
    let lwe_key = glwe_secret_key.into_lwe_secret_key();

    let mut buf = Vec::new();
    safe_serialize(&lwe_key, &mut buf, LIMIT).map_err(|e| e.to_string())?;
    Ok(buf)
}

// ── FFI helpers ───────────────────────────────────────────────────────────────

/// Leak a Vec<u8> into a raw pointer/length pair that Dart will free later.
fn leak_buf(v: Vec<u8>) -> (*mut u8, usize) {
    let len = v.len();
    let ptr = Box::into_raw(v.into_boxed_slice()) as *mut u8;
    (ptr, len)
}

// ── Exported C symbols ────────────────────────────────────────────────────────

/// Generate a fresh TFHE-rs keypair.
///
/// Outputs three buffers (all freed with `fhe_free_buf`):
///   - `client_key_*` — private; store encrypted on-device
///   - `server_key_*` — evaluation key; upload to `POST /fhe/key`
///   - `lwe_key_*`    — send to `POST /fhe/setup` for server-side circuit binding
///
/// # Safety
/// All six pointer-to-pointer arguments must not be null.
#[no_mangle]
pub unsafe extern "C" fn fhe_keygen(
    client_key_out: *mut *mut u8, client_key_len: *mut usize,
    server_key_out: *mut *mut u8, server_key_len: *mut usize,
    lwe_key_out:    *mut *mut u8, lwe_key_len:    *mut usize,
) -> i32 {
    match panic::catch_unwind(|| -> Result<(), String> {
        let config = ConfigBuilder::default()
            .use_custom_parameters(PARAM_MESSAGE_2_CARRY_2_KS_PBS)
            .build();
        let (client_key, server_key) = tfhe::generate_keys(config);

        // Serialise client key
        let mut ck_buf = Vec::new();
        safe_serialize(&client_key, &mut ck_buf, LIMIT).map_err(|e| e.to_string())?;

        // Serialise server (evaluation) key
        let mut sk_buf = Vec::new();
        safe_serialize(&server_key, &mut sk_buf, LIMIT).map_err(|e| e.to_string())?;

        // Extract and serialise the LWE secret key for server bridge binding
        let lwe_buf = extract_and_serialise_lwe_key(&client_key)?;

        let (ck_ptr, ck_len)   = leak_buf(ck_buf);
        let (sk_ptr, sk_len)   = leak_buf(sk_buf);
        let (lwe_ptr, lwe_len) = leak_buf(lwe_buf);

        *client_key_out = ck_ptr;  *client_key_len = ck_len;
        *server_key_out = sk_ptr;  *server_key_len = sk_len;
        *lwe_key_out    = lwe_ptr; *lwe_key_len    = lwe_len;
        Ok(())
    }) {
        Ok(Ok(())) => 0,
        Ok(Err(_)) => -1,
        Err(_) => -2,
    }
}

/// Encrypt `n_vals` uint8 values (quantized inputs) with the client key.
///
/// Output is a bincode-serialised `Vec<FheUint8>` compatible with
/// `concrete-ml-extensions::encrypt_serialize_u8_radix_2d()`.
/// Send the output bytes to `POST /fhe/predict`.
///
/// # Safety
/// `client_key`, `values` must point to valid buffers of the given lengths.
/// Free the output with `fhe_free_buf`.
#[no_mangle]
pub unsafe extern "C" fn fhe_encrypt_u8(
    client_key:     *const u8, client_key_len: usize,
    values:         *const u8, n_vals:         usize,
    ct_out:         *mut *mut u8, ct_len: *mut usize,
) -> i32 {
    match panic::catch_unwind(|| -> Result<(), String> {
        let ck_bytes = slice::from_raw_parts(client_key, client_key_len);
        let vals     = slice::from_raw_parts(values, n_vals);

        let ck: ClientKey = safe_deserialize(Cursor::new(ck_bytes), LIMIT)
            .map_err(|e| e.to_string())?;

        let cts: Vec<FheUint8> = vals.iter().map(|&v| FheUint8::encrypt(v, &ck)).collect();
        let serialised = bincode::serialize(&cts).map_err(|e| e.to_string())?;

        let (ptr, len) = leak_buf(serialised);
        *ct_out = ptr;
        *ct_len = len;
        Ok(())
    }) {
        Ok(Ok(())) => 0,
        Ok(Err(_)) => -1,
        Err(_) => -2,
    }
}

/// Decrypt a bincode-serialised `Vec<FheInt8>` (server result) with the client key.
///
/// Compatible with `concrete-ml-extensions::decrypt_serialized_i8_radix_2d()`.
/// The raw i8 scores are then dequantised in Dart using quantization_params.json.
///
/// # Safety
/// `client_key`, `ct` must point to valid buffers.  Free output with `fhe_free_i8_buf`.
#[no_mangle]
pub unsafe extern "C" fn fhe_decrypt_i8(
    client_key:  *const u8, client_key_len: usize,
    ct:          *const u8, ct_len:         usize,
    scores_out:  *mut *mut i8, scores_len: *mut usize,
) -> i32 {
    match panic::catch_unwind(|| -> Result<(), String> {
        let ck_bytes  = slice::from_raw_parts(client_key, client_key_len);
        let ct_bytes  = slice::from_raw_parts(ct, ct_len);

        let ck: ClientKey = safe_deserialize(Cursor::new(ck_bytes), LIMIT)
            .map_err(|e| e.to_string())?;
        let fhe_ints: Vec<FheInt8> = bincode::deserialize(ct_bytes)
            .map_err(|e| e.to_string())?;

        let raw: Vec<i8> = fhe_ints.iter().map(|v| v.decrypt(&ck)).collect();
        let len = raw.len();
        let ptr = Box::into_raw(raw.into_boxed_slice()) as *mut i8;
        *scores_out = ptr;
        *scores_len = len;
        Ok(())
    }) {
        Ok(Ok(())) => 0,
        Ok(Err(_)) => -1,
        Err(_) => -2,
    }
}

/// Free a `u8` buffer returned by `fhe_keygen` or `fhe_encrypt_u8`.
///
/// # Safety
/// `ptr` must have been returned by this library with the matching `len`.
#[no_mangle]
pub unsafe extern "C" fn fhe_free_buf(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        drop(Box::from_raw(slice::from_raw_parts_mut(ptr, len)));
    }
}

/// Free an `i8` buffer returned by `fhe_decrypt_i8`.
///
/// # Safety
/// `ptr` must have been returned by this library with the matching `len`.
#[no_mangle]
pub unsafe extern "C" fn fhe_free_i8_buf(ptr: *mut i8, len: usize) {
    if !ptr.is_null() && len > 0 {
        drop(Box::from_raw(slice::from_raw_parts_mut(ptr, len)));
    }
}
