// lib/fhe/fhe_client.dart
//
// High-level Dart FHE client.
//
// All FHE operations are performed natively via flutter_concrete plugin
// (Rust/TFHE-rs).  No Python runtime is required on-device.
//
// Flow:
//   setup()                    → base64 server/eval key  (POST to /fhe/key)
//   vectorizeAndEncrypt(text)  → base64 ciphertext  (POST to /fhe/predict)
//   decryptResult(b64)         → EmotionResult

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_concrete/flutter_concrete.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/emotion_result.dart';
import 'vectorizer.dart';

/// Emotion label order — must match training config LABELS list.
const List<String> _kLabels = ['anger', 'joy', 'neutral', 'sadness', 'surprise'];

// Secure-storage keys for persisting FHE keys across app launches.
// v2: server key is now a Concrete Cap'n Proto ServerKeyset (not TFHE-rs bincode)
const _kClientKey = 'fhe_client_key_v2';
const _kServerKey = 'fhe_server_key_v2';

/// High-level FHE client; owns the [Vectorizer] and [ConcreteClient] instances.
class FheClient {
  final Vectorizer _vectorizer = Vectorizer();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  ConcreteClient? _concrete;
  bool _initialized = false;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Load assets and generate (or restore) FHE keys.
  ///
  /// Returns the base64-encoded TFHE-rs server (evaluation) key to be
  /// uploaded to the backend via `POST /fhe/key`.  The private client key
  /// never leaves the device.
  ///
  /// Key generation is CPU-intensive (~10–60 s on mobile) and is skipped on
  /// subsequent calls by restoring the persisted keys from secure storage.
  Future<String> setup() async {
    if (_initialized) return base64Encode(_concrete!.serverKey!);

    // Load vectoriser and quantization assets in parallel.
    late QuantizationParams quantParams;
    await Future.wait([
      _vectorizer.load(),
      _loadQuantParams().then((p) => quantParams = p),
    ]);

    _concrete = ConcreteClient(quantParams: quantParams);

    // Try to restore previously persisted keys.
    final storedClient = await _secureStorage.read(key: _kClientKey);
    final storedServer = await _secureStorage.read(key: _kServerKey);

    if (storedClient != null && storedServer != null) {
      _concrete!.restoreKeys(
        clientKey: base64Decode(storedClient),
        serverKey: base64Decode(storedServer),
      );
    } else {
      // Generate a fresh TFHE-rs keypair (CPU-intensive).
      _concrete!.generateKeys();

      await Future.wait([
        _secureStorage.write(
            key: _kClientKey, value: base64Encode(_concrete!.clientKey!)),
        _secureStorage.write(
            key: _kServerKey, value: base64Encode(_concrete!.serverKey!)),
      ]);
    }

    _initialized = true;
    return base64Encode(_concrete!.serverKey!);
  }

  /// Vectorise [text] (TF-IDF → LSA → L2-norm), quantise to uint8, and
  /// FHE-encrypt under the client key.
  ///
  /// Returns base64-encoded bincode `Vec<FheUint8>` to send to
  /// `POST /fhe/predict`.
  Future<String> vectorizeAndEncrypt(String text) async {
    _requireInit();
    final features = _vectorizer.transform(text);
    final ciphertext = _concrete!.quantizeAndEncrypt(features);
    return base64Encode(ciphertext);
  }

  /// Decrypt an FHE inference result and return the predicted emotion.
  ///
  /// [encryptedB64] is the `encrypted_result_b64` field from the backend.
  /// The raw int8 scores are dequantised using the output quantization params
  /// before argmax is applied.
  Future<EmotionResult> decryptResult(String encryptedB64) async {
    _requireInit();
    final ciphertext = base64Decode(encryptedB64);
    final scores = _concrete!.decryptAndDequantize(Uint8List.fromList(ciphertext));

    int argmax = 0;
    double maxScore = double.negativeInfinity;
    for (int i = 0; i < scores.length; i++) {
      if (scores[i] > maxScore) {
        maxScore = scores[i];
        argmax = i;
      }
    }

    final emotion = argmax < _kLabels.length ? _kLabels[argmax] : 'neutral';
    return EmotionResult(emotion: emotion, confidence: maxScore);
  }

  // ── Asset loading ──────────────────────────────────────────────────────────

  Future<QuantizationParams> _loadQuantParams() async {
    final jsonStr =
        await rootBundle.loadString('assets/fhe/quantization_params.json');
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    return QuantizationParams.fromJson(map);
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  void _requireInit() {
    if (!_initialized || _concrete == null) {
      throw StateError('FheClient: call setup() before encrypting/decrypting');
    }
  }
}
