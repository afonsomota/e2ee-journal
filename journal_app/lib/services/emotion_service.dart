// services/emotion_service.dart
//
// Orchestrates the FHE emotion classification flow.
//
// All FHE operations (vectorization, encryption, decryption) are performed
// in-process by FheClient via Dart FFI → libfhe_client (native Rust/TFHE-rs).
// No Python runtime is required on-device.
//
// Flow:
//   1. FheClient.setup()             → LWE key (base64)
//   2. POST backend /fhe/setup       → server generates circuit eval keys from LWE key
//   3. FheClient.vectorizeAndEncrypt → encrypted feature vector (base64)
//   4. POST backend /fhe/predict     → encrypted result (base64)
//   5. FheClient.decryptResult       → EmotionResult

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../models/emotion_result.dart';
import '../fhe/fhe_client.dart';

class EmotionService extends ChangeNotifier {
  // Native FHE client (replaces the Python sidecar HTTP calls)
  final FheClient _fheClient = FheClient();

  // Backend server (FHE inference)
  // FHE inference is CPU-intensive and can take several minutes — use a
  // generous receiveTimeout so we don't cut off a running computation.
  final Dio _backend = Dio(BaseOptions(
    baseUrl: 'http://localhost:8000',
    connectTimeout: const Duration(seconds: 60),
    receiveTimeout: const Duration(minutes: 10),
  ));

  String? _clientId;
  bool _initialized = false;
  bool _available = false;

  // In-memory cache: entryId → EmotionResult
  final Map<String, EmotionResult> _cache = {};
  // Tracks entries currently being classified (to distinguish "loading" from "failed")
  final Set<String> _inProgress = {};
  // Entries that failed due to backend unavailability — retried after recovery
  final Map<String, String> _pendingRetry = {}; // entryId → plaintext

  bool get available => _available;
  EmotionResult? cached(String entryId) => _cache[entryId];
  bool isClassifying(String entryId) => _inProgress.contains(entryId);

  /// Initialize FHE keys. Call once after app startup.
  Future<void> initialize() async {
    if (_initialized) return;
    try {
      // 1. Setup native FHE client → get LWE key (derives from private client key)
      final lweKeyB64 = await _fheClient.setup();
      _clientId = 'dart-fhe-client';

      // 2. Upload LWE key to backend so it can generate compatible circuit eval keys.
      await _backend.post('/fhe/setup', data: {
        'client_id': _clientId,
        'lwe_key_b64': lweKeyB64,
      });

      _initialized = true;
      _available = true;
      notifyListeners();

      // Retry any classifications that failed while the backend was down.
      if (_pendingRetry.isNotEmpty) {
        final toRetry = Map<String, String>.from(_pendingRetry);
        _pendingRetry.clear();
        for (final entry in toRetry.entries) {
          unawaited(classifyEntry(entry.key, entry.value));
        }
      }
    } catch (e) {
      // FHE client or backend unavailable — degrade gracefully
      _available = false;
    }
  }

  /// Classify a decrypted journal entry via FHE.
  Future<EmotionResult?> classifyEntry(String entryId, String plaintext) async {
    if (_cache.containsKey(entryId)) return _cache[entryId];
    if (!_available || !_initialized) return null;
    if (_inProgress.contains(entryId)) return null;

    _inProgress.add(entryId);
    notifyListeners();

    try {
      // 1. Vectorize + encrypt (native Dart FHE client)
      final encryptedVectorB64 = await _fheClient.vectorizeAndEncrypt(plaintext);

      // 2. FHE inference (backend)
      final predResp = await _backend.post('/fhe/predict', data: {
        'client_id': _clientId,
        'encrypted_input_b64': encryptedVectorB64,
      });
      final encryptedResultB64 =
          predResp.data['encrypted_result_b64'] as String;

      // 3. Decrypt (native Dart FHE client)
      final result = await _fheClient.decryptResult(encryptedResultB64);
      _cache[entryId] = result;
      _inProgress.remove(entryId);
      notifyListeners();
      return result;
    } catch (e) {
      _inProgress.remove(entryId);
      // If the backend lost our eval key (e.g. it was restarted), reset so
      // the next classify attempt re-runs initialize() and re-uploads the key.
      _pendingRetry[entryId] = plaintext;
      _initialized = false;
      _available = false;
      unawaited(initialize());
      notifyListeners();
      return null;
    }
  }
}
