// lib/fhe/fhe_client.dart
//
// High-level Dart FHE client.
//
// Replaces the three Python sidecar endpoints (/setup, /vectorize, /decrypt)
// with direct in-process calls:
//
//   setup()                    → base64 evaluation key  (cf. POST /setup)
//   vectorizeAndEncrypt(text)  → base64 ciphertext      (cf. POST /vectorize)
//   decryptResult(b64)         → EmotionResult          (cf. POST /decrypt)
//
// Internally combines:
//   • Vectorizer  — pure Dart TF-IDF + LSA + L2-normalise
//   • FheNative   — Dart FFI → libfhe_wrapper.so → Python → concrete-ml
//
// Asset extraction:
//   client.zip and fhe_helper.py are bundled as Flutter assets and are
//   written to the app-support directory on first use.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/emotion_result.dart';
import 'vectorizer.dart';
import 'fhe_native.dart';

/// Emotion label order — must match training config LABELS list.
const List<String> _kLabels = ['anger', 'joy', 'neutral', 'sadness', 'surprise'];

/// High-level FHE client; owns the [Vectorizer] and [FheNative] instances.
class FheClient {
  final Vectorizer _vectorizer = Vectorizer();
  FheNative? _native;
  bool _initialized = false;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Load assets and initialise the FHE client.
  ///
  /// Returns the base64-encoded serialised evaluation key to be uploaded to
  /// the backend via `POST /fhe/key`.
  Future<String> setup() async {
    if (_initialized) {
      return base64Encode(_native!.getEvalKey());
    }

    // Load vectoriser assets (vocab, IDF, SVD components)
    await _vectorizer.load();

    // Extract binary assets to filesystem so C wrapper can read them
    final supportDir = await _fheDataDir();
    final clientZipPath = await _extractAsset('assets/fhe/client.zip', supportDir);
    final helperPyPath = await _extractAsset('assets/fhe/fhe_helper.py', supportDir);
    final keyDir = '${supportDir.path}/keys';
    await Directory(keyDir).create(recursive: true);

    _native = FheNative();
    final ret = _native!.init(helperPyPath, clientZipPath, keyDir);
    if (ret != 0) {
      _native = null;
      throw StateError('fhe_init() failed (code $ret). '
          'Is FHE_PYTHON_HOME set and concrete-ml installed?');
    }

    _initialized = true;
    return base64Encode(_native!.getEvalKey());
  }

  /// Vectorise [text] (TF-IDF → LSA → L2-norm) and FHE-encrypt the result.
  ///
  /// Returns the base64-encoded serialised ciphertext to be sent to the
  /// backend via `POST /fhe/predict`.
  Future<String> vectorizeAndEncrypt(String text) async {
    if (!_initialized) throw StateError('Call setup() first');
    final features = _vectorizer.transform(text);
    final encrypted = _native!.encrypt(features);
    return base64Encode(encrypted);
  }

  /// Decrypt an FHE inference result and return the predicted emotion.
  ///
  /// [encryptedB64] is the `encrypted_result_b64` field from the backend
  /// response.
  Future<EmotionResult> decryptResult(String encryptedB64) async {
    if (!_initialized) throw StateError('Call setup() first');
    final encrypted = base64Decode(encryptedB64);
    final scores = _native!.decrypt(Uint8List.fromList(encrypted));

    int argmax = 0;
    for (int i = 1; i < scores.length; i++) {
      if (scores[i] > scores[argmax]) argmax = i;
    }
    return EmotionResult(
      emotion: _kLabels[argmax],
      confidence: scores[argmax].toDouble(),
    );
  }

  // ── Asset helpers ──────────────────────────────────────────────────────────

  /// Return (and create) the app-support directory used for FHE assets.
  Future<Directory> _fheDataDir() async {
    final appSupport = await getApplicationSupportDirectory();
    final dir = Directory('${appSupport.path}/fhe');
    await dir.create(recursive: true);
    return dir;
  }

  /// Extract a Flutter asset to [destDir] and return its filesystem path.
  ///
  /// [assetKey] — key as registered in pubspec.yaml, e.g. 'assets/fhe/client.zip'
  Future<String> _extractAsset(String assetKey, Directory destDir) async {
    final filename = assetKey.split('/').last;
    final destPath = '${destDir.path}/$filename';
    final dest = File(destPath);
    if (!await dest.exists()) {
      final data = await rootBundle.load(assetKey);
      await dest.writeAsBytes(data.buffer.asUint8List());
    }
    return destPath;
  }
}
