// lib/fhe/fhe_client.dart
//
// High-level Dart FHE client.
//
// All FHE operations are performed natively via Dart FFI → libfhe_client
// (Rust/TFHE-rs).  No Python runtime is required on-device.
//
// Flow:
//   setup()                    → base64 server/eval key  (POST to /fhe/key)
//   vectorizeAndEncrypt(text)  → base64 ciphertext  (POST to /fhe/predict)
//   decryptResult(b64)         → EmotionResult

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/emotion_result.dart';
import 'vectorizer.dart';
import 'fhe_native.dart';

/// Emotion label order — must match training config LABELS list.
const List<String> _kLabels = ['anger', 'joy', 'neutral', 'sadness', 'surprise'];

// Secure-storage keys for persisting FHE keys across app launches.
// v2: server key is now a Concrete Cap'n Proto ServerKeyset (not TFHE-rs bincode)
const _kClientKey = 'fhe_client_key_v2';
const _kServerKey = 'fhe_server_key_v2';

/// High-level FHE client; owns the [Vectorizer] and [FheNative] instances.
class FheClient {
  final Vectorizer _vectorizer = Vectorizer();
  final FheNative  _native     = FheNative();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  // Per-feature input quantization params (one per LSA dimension).
  late List<_QuantParam> _inputParams;
  // Single output quantization params (for class scores).
  late _OutputQuantParam _outputParam;

  Uint8List? _clientKey;
  Uint8List? _serverKey;
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
    if (_initialized) return base64Encode(_serverKey!);

    // Load vectoriser and quantization assets in parallel.
    await Future.wait([_vectorizer.load(), _loadQuantParams()]);

    // Try to restore previously persisted keys.
    final storedClient = await _secureStorage.read(key: _kClientKey);
    final storedServer = await _secureStorage.read(key: _kServerKey);

    if (storedClient != null && storedServer != null) {
      _clientKey = base64Decode(storedClient);
      _serverKey = base64Decode(storedServer);
    } else {
      // Generate a fresh TFHE-rs keypair (CPU-intensive).
      final result = _native.keygen();
      _clientKey = result.clientKey;
      _serverKey = result.serverKey;

      await Future.wait([
        _secureStorage.write(key: _kClientKey, value: base64Encode(_clientKey!)),
        _secureStorage.write(key: _kServerKey, value: base64Encode(_serverKey!)),
      ]);
    }

    _initialized = true;
    return base64Encode(_serverKey!);
  }

  /// Vectorise [text] (TF-IDF → LSA → L2-norm), quantise to uint8, and
  /// FHE-encrypt under the client key.
  ///
  /// Returns base64-encoded bincode `Vec<FheUint8>` to send to
  /// `POST /fhe/predict`.
  Future<String> vectorizeAndEncrypt(String text) async {
    _requireInit();
    final features  = _vectorizer.transform(text);
    final quantized = _quantizeInputs(features);
    final ciphertext = _native.encryptU8(_clientKey!, quantized);
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
    final rawScores  = _native.decryptI8(_clientKey!, Uint8List.fromList(ciphertext));

    // Dequantize: float = (raw + offset - zero_point) * scale
    final p = _outputParam;
    int    argmax   = 0;
    double maxScore = double.negativeInfinity;

    for (int i = 0; i < rawScores.length; i++) {
      final score = (rawScores[i] + p.offset - p.zeroPoint) * p.scale;
      if (score > maxScore) {
        maxScore = score;
        argmax   = i;
      }
    }

    final emotion = argmax < _kLabels.length ? _kLabels[argmax] : 'neutral';
    return EmotionResult(emotion: emotion, confidence: maxScore);
  }

  // ── Quantization ────────────────────────────────────────────────────────────

  Uint8List _quantizeInputs(Float32List features) {
    assert(
      features.length == _inputParams.length,
      'Feature length ${features.length} != quant param length ${_inputParams.length}',
    );
    final result = Uint8List(features.length);
    for (int i = 0; i < features.length; i++) {
      final p = _inputParams[i];
      // q = round(float / scale) + zero_point, clamped to uint8 range.
      final q = (features[i] / p.scale).round() + p.zeroPoint;
      result[i] = q.clamp(0, 255);
    }
    return result;
  }

  // ── Asset loading ──────────────────────────────────────────────────────────

  Future<void> _loadQuantParams() async {
    final jsonStr = await rootBundle.loadString('assets/fhe/quantization_params.json');
    final map     = jsonDecode(jsonStr) as Map<String, dynamic>;

    final inputList = map['input'] as List<dynamic>;
    _inputParams = inputList.map((e) {
      final m = e as Map<String, dynamic>;
      return _QuantParam(
        scale:     (m['scale']      as num).toDouble(),
        zeroPoint: (m['zero_point'] as num).toInt(),
      );
    }).toList();

    final out = map['output'] as Map<String, dynamic>;
    _outputParam = _OutputQuantParam(
      scale:     (out['scale']      as num).toDouble(),
      zeroPoint: (out['zero_point'] as num).toInt(),
      offset:    (out['offset']     as num).toInt(),
    );
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  void _requireInit() {
    if (!_initialized || _clientKey == null) {
      throw StateError('FheClient: call setup() before encrypting/decrypting');
    }
  }
}

// ── Internal value types ───────────────────────────────────────────────────────

class _QuantParam {
  final double scale;
  final int    zeroPoint;
  const _QuantParam({required this.scale, required this.zeroPoint});
}

class _OutputQuantParam {
  final double scale;
  final int    zeroPoint;
  final int    offset;
  const _OutputQuantParam({
    required this.scale,
    required this.zeroPoint,
    required this.offset,
  });
}
