// services/emotion_service.dart
//
// Orchestrates FHE emotion classification.
//
// Flow:
//   1. ConcreteClient.setup()        → parse client.zip, generate/restore keys
//   2. POST /fhe/key                 → upload eval key to backend
//   3. Vectorizer.transform()        → Float32 feature vector
//   4. ConcreteClient.quantizeAndEncrypt() → encrypted features
//   5. POST /fhe/predict             → encrypted result
//   6. ConcreteClient.decryptAndDequantize() → float scores
//   7. argmax                        → EmotionResult

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_concrete/flutter_concrete.dart';

import '../fhe/vectorizer.dart';
import '../models/emotion_result.dart';
import 'secure_key_storage.dart';

/// Emotion label order — must match training config LABELS list.
const List<String> _kLabels = ['anger', 'joy', 'neutral', 'sadness', 'surprise'];

class EmotionService extends ChangeNotifier {
  final ConcreteClient _concrete = ConcreteClient();
  final Vectorizer _vectorizer = Vectorizer();

  final Dio _backend = Dio(BaseOptions(
    baseUrl: 'http://localhost:8000',
    connectTimeout: const Duration(seconds: 60),
    receiveTimeout: const Duration(minutes: 10),
  ));

  String? _clientId;
  bool _initialized = false;
  bool _available = false;

  final Map<String, EmotionResult> _cache = {};
  final Set<String> _inProgress = {};
  final Map<String, String> _pendingRetry = {};

  bool get available => _available;
  EmotionResult? cached(String entryId) => _cache[entryId];
  bool isClassifying(String entryId) => _inProgress.contains(entryId);

  /// Initialize FHE keys and upload eval key to backend.
  Future<void> initialize() async {
    if (_initialized) {
      dev.log('[EmotionService] already initialized, skipping');
      return;
    }
    try {
      dev.log('[EmotionService] starting FHE setup...');

      // 1. Load vectorizer + setup FHE client in parallel
      final zipData = await rootBundle.load('assets/fhe/client.zip');
      await Future.wait([
        _vectorizer.load(),
        _concrete.setup(
          clientZipBytes: zipData.buffer.asUint8List(),
          storage: SecureKeyStorage(),
        ),
      ]);

      _clientId = 'dart-fhe-client';
      dev.log('[EmotionService] FHE setup complete, uploading eval key...');

      // 2. Upload evaluation key to backend
      await _backend.post('/fhe/key', data: {
        'client_id': _clientId,
        'evaluation_key_b64': _concrete.serverKeyBase64,
      });

      _initialized = true;
      _available = true;
      dev.log('[EmotionService] initialized successfully');
      notifyListeners();

      // Retry pending classifications
      if (_pendingRetry.isNotEmpty) {
        dev.log('[EmotionService] retrying ${_pendingRetry.length} pending');
        final toRetry = Map<String, String>.from(_pendingRetry);
        _pendingRetry.clear();
        for (final entry in toRetry.entries) {
          unawaited(classifyEntry(entry.key, entry.value));
        }
      }
    } catch (e) {
      dev.log('[EmotionService] initialize failed: $e');
      _available = false;
    }
  }

  /// Classify a journal entry via FHE.
  Future<EmotionResult?> classifyEntry(String entryId, String plaintext) async {
    if (_cache.containsKey(entryId)) {
      dev.log('[EmotionService] classifyEntry($entryId): cached');
      return _cache[entryId];
    }
    if (!_available || !_initialized) {
      dev.log('[EmotionService] classifyEntry($entryId): skipped (available=$_available, initialized=$_initialized)');
      return null;
    }
    if (_inProgress.contains(entryId)) {
      dev.log('[EmotionService] classifyEntry($entryId): already in progress');
      return null;
    }

    _inProgress.add(entryId);
    notifyListeners();

    try {
      // 1. Vectorize (app-specific)
      dev.log('[EmotionService] classifyEntry($entryId): vectorizing + encrypting...');
      final features = _vectorizer.transform(plaintext);

      // 2. Encrypt (plugin)
      final ciphertext = _concrete.quantizeAndEncrypt(features);

      // 3. Send to server
      dev.log('[EmotionService] classifyEntry($entryId): posting to /fhe/predict...');
      final predResp = await _backend.post('/fhe/predict', data: {
        'client_id': _clientId,
        'encrypted_input_b64': base64Encode(ciphertext),
      });
      final encryptedResultB64 =
          predResp.data['encrypted_result_b64'] as String;

      // 4. Decrypt (plugin)
      dev.log('[EmotionService] classifyEntry($entryId): decrypting...');
      final scores = _concrete.decryptAndDequantize(
        base64Decode(encryptedResultB64),
      );

      // 5. Interpret (app-specific: argmax)
      int maxIdx = 0;
      for (int i = 1; i < scores.length; i++) {
        if (scores[i] > scores[maxIdx]) maxIdx = i;
      }
      final emotion = maxIdx < _kLabels.length ? _kLabels[maxIdx] : 'neutral';
      final result = EmotionResult(emotion: emotion, confidence: scores[maxIdx]);

      _cache[entryId] = result;
      _inProgress.remove(entryId);
      dev.log('[EmotionService] classifyEntry($entryId): done → ${result.emotion} (${result.confidence})');
      notifyListeners();
      return result;
    } catch (e) {
      dev.log('[EmotionService] classifyEntry($entryId): error: $e');
      _inProgress.remove(entryId);
      _pendingRetry[entryId] = plaintext;
      _initialized = false;
      _available = false;
      unawaited(initialize());
      notifyListeners();
      return null;
    }
  }
}
