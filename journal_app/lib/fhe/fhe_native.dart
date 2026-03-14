// lib/fhe/fhe_native.dart
//
// Dart FFI bindings for libfhe_wrapper.so.
//
// The shared library (built from native/fhe_wrapper.cpp) embeds the Python
// interpreter and calls concrete-ml's FHEModelClient for setup, encrypt, and
// decrypt.
//
// Environment:
//   Set FHE_PYTHON_HOME in the process environment to point at the venv root
//   that contains concrete-ml before this library is loaded.  The C wrapper
//   reads this env-var during fhe_init().

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ── C function signatures ─────────────────────────────────────────────────────

typedef _FheInitC = Int32 Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FheInitDart = int Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _FheGetEvalKeyC = Pointer<Uint8> Function(Pointer<Int32>);
typedef _FheGetEvalKeyDart = Pointer<Uint8> Function(Pointer<Int32>);

typedef _FheEncryptC = Pointer<Uint8> Function(
    Pointer<Float>, Int32, Pointer<Int32>);
typedef _FheEncryptDart = Pointer<Uint8> Function(
    Pointer<Float>, int, Pointer<Int32>);

typedef _FheDecryptC = Pointer<Float> Function(
    Pointer<Uint8>, Int32, Pointer<Int32>);
typedef _FheDecryptDart = Pointer<Float> Function(
    Pointer<Uint8>, int, Pointer<Int32>);

typedef _FheFreeC = Void Function(Pointer<Void>);
typedef _FheFreeDart = void Function(Pointer<Void>);

// ── FheNative ─────────────────────────────────────────────────────────────────

/// Low-level Dart FFI bindings for the native FHE wrapper.
///
/// Prefer using [FheClient] which adds asset extraction, base64 encoding, and
/// error handling.
class FheNative {
  late final _FheInitDart _fheInit;
  late final _FheGetEvalKeyDart _fheGetEvalKey;
  late final _FheEncryptDart _fheEncrypt;
  late final _FheDecryptDart _fheDecrypt;
  late final _FheFreeDart _fheFree;

  FheNative() {
    final lib = DynamicLibrary.open(_libraryPath());
    _fheInit =
        lib.lookupFunction<_FheInitC, _FheInitDart>('fhe_init');
    _fheGetEvalKey =
        lib.lookupFunction<_FheGetEvalKeyC, _FheGetEvalKeyDart>('fhe_get_eval_key');
    _fheEncrypt =
        lib.lookupFunction<_FheEncryptC, _FheEncryptDart>('fhe_encrypt');
    _fheDecrypt =
        lib.lookupFunction<_FheDecryptC, _FheDecryptDart>('fhe_decrypt');
    _fheFree =
        lib.lookupFunction<_FheFreeC, _FheFreeDart>('fhe_free');
  }

  static String _libraryPath() {
    if (Platform.isLinux) {
      return 'libfhe_wrapper.so';
    } else if (Platform.isMacOS) {
      return 'libfhe_wrapper.dylib';
    }
    throw UnsupportedError(
        'FHE native library not supported on ${Platform.operatingSystem}');
  }

  /// Initialise Python + FHEModelClient.
  ///
  /// [helperPyPath]   — filesystem path to fhe_helper.py
  /// [clientZipPath]  — filesystem path to client.zip
  /// [keyDir]         — directory for FHE key storage
  ///
  /// Returns 0 on success, -1 on failure.
  int init(String helperPyPath, String clientZipPath, String keyDir) {
    final pHelper = helperPyPath.toNativeUtf8();
    final pZip = clientZipPath.toNativeUtf8();
    final pKeys = keyDir.toNativeUtf8();
    try {
      return _fheInit(pHelper, pZip, pKeys);
    } finally {
      malloc.free(pHelper);
      malloc.free(pZip);
      malloc.free(pKeys);
    }
  }

  /// Return the serialised evaluation key as a [Uint8List].
  Uint8List getEvalKey() {
    final lenPtr = malloc<Int32>();
    try {
      final ptr = _fheGetEvalKey(lenPtr);
      if (ptr == nullptr) throw StateError('fhe_get_eval_key returned null');
      final result = Uint8List.fromList(ptr.asTypedList(lenPtr.value));
      _fheFree(ptr.cast());
      return result;
    } finally {
      malloc.free(lenPtr);
    }
  }

  /// Quantise, encrypt and serialise a float32 feature vector.
  ///
  /// [features] — 200-dimensional L2-normalised LSA features.
  Uint8List encrypt(Float32List features) {
    final lenPtr = malloc<Int32>();
    final featurePtr = malloc<Float>(features.length);
    // Copy Dart list into C memory
    for (int i = 0; i < features.length; i++) {
      featurePtr[i] = features[i];
    }
    try {
      final ptr = _fheEncrypt(featurePtr, features.length, lenPtr);
      if (ptr == nullptr) throw StateError('fhe_encrypt returned null');
      final result = Uint8List.fromList(ptr.asTypedList(lenPtr.value));
      _fheFree(ptr.cast());
      return result;
    } finally {
      malloc.free(lenPtr);
      malloc.free(featurePtr);
    }
  }

  /// Deserialise, decrypt and dequantise an FHE inference result.
  ///
  /// Returns a [Float32List] of length 5 (one score per emotion class).
  Float32List decrypt(Uint8List encrypted) {
    final lenPtr = malloc<Int32>();
    final encPtr = malloc<Uint8>(encrypted.length);
    for (int i = 0; i < encrypted.length; i++) {
      encPtr[i] = encrypted[i];
    }
    try {
      final ptr = _fheDecrypt(encPtr, encrypted.length, lenPtr);
      if (ptr == nullptr) throw StateError('fhe_decrypt returned null');
      final result = Float32List.fromList(ptr.asTypedList(lenPtr.value));
      _fheFree(ptr.cast());
      return result;
    } finally {
      malloc.free(lenPtr);
      malloc.free(encPtr);
    }
  }
}
