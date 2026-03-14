// services/emotion_service.dart
//
// Orchestrates the FHE emotion classification flow.
//
// The Dart app is the orchestrator — it calls the local Python sidecar for
// vectorization/encryption/decryption, and the backend server for FHE
// inference. This mirrors production architecture where the sidecar would be
// replaced by native code.
//
// Flow:
//   1. POST sidecar /setup        → get evaluation key
//   2. POST backend /fhe/key      → upload evaluation key
//   3. POST sidecar /vectorize    → get encrypted feature vector
//   4. POST backend /fhe/predict  → get encrypted result
//   5. POST sidecar /decrypt      → get emotion label

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../models/emotion_result.dart';

class EmotionService extends ChangeNotifier {
  // Local sidecar (TF-IDF + FHE encrypt/decrypt)
  final Dio _sidecar = Dio(BaseOptions(
    baseUrl: 'http://localhost:8001',
    connectTimeout: const Duration(seconds: 60),
    receiveTimeout: const Duration(seconds: 60),
  ));

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
      // 1. Get evaluation key from sidecar
      final setupResp = await _sidecar.post('/setup');
      _clientId = setupResp.data['client_id'] as String;
      final evalKeyB64 = setupResp.data['evaluation_key_b64'] as String;

      // 2. Upload evaluation key to backend
      await _backend.post('/fhe/key', data: {
        'client_id': _clientId,
        'evaluation_key_b64': evalKeyB64,
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
      // Sidecar not running — degrade gracefully
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
      // 1. Vectorize + encrypt (sidecar)
      final vecResp = await _sidecar.post('/vectorize', data: {
        'text': plaintext,
      });
      final encryptedVectorB64 = vecResp.data['encrypted_vector_b64'] as String;

      // 2. FHE inference (backend)
      final predResp = await _backend.post('/fhe/predict', data: {
        'client_id': _clientId,
        'encrypted_input_b64': encryptedVectorB64,
      });
      final encryptedResultB64 =
          predResp.data['encrypted_result_b64'] as String;

      // 3. Decrypt (sidecar)
      final decResp = await _sidecar.post('/decrypt', data: {
        'encrypted_result_b64': encryptedResultB64,
      });

      final result = EmotionResult.fromJson(
        decResp.data as Map<String, dynamic>,
      );
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
