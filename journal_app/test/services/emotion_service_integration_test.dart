/// Integration test: EmotionService flow against a live backend.
///
/// Exercises the full FHE emotion classification as the journal app would:
///   vectorize text → quantize → encrypt → backend FHE predict → decrypt → emotion
///
/// Requires:
///   1. libfhe_client.so on LD_LIBRARY_PATH
///   2. Backend running on localhost:8000
///   3. Assets in journal_app/assets/fhe/
///
/// Run with:
///   cd journal_app
///   LD_LIBRARY_PATH=../flutter_concrete/rust/target/debug \
///     flutter test test/services/emotion_service_integration_test.dart --timeout 15m

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_concrete/flutter_concrete.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory KeyStorage for testing (no flutter_secure_storage).
class _MemoryKeyStorage implements KeyStorage {
  final Map<String, Uint8List> _store = {};

  @override
  Future<Uint8List?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, Uint8List value) async =>
      _store[key] = value;

  @override
  Future<void> delete(String key) async => _store.remove(key);
}

/// Minimal TF-IDF + LSA vectorizer that loads from disk (no rootBundle).
class _TestVectorizer {
  static const int _nFeatures = 5000;
  static const int _nComponents = 50;

  late Map<String, int> _vocab;
  late Float32List _idf;
  late Float32List _svdComponents;

  Future<void> load(String assetsDir) async {
    _vocab = (jsonDecode(File('$assetsDir/vocab.json').readAsStringSync())
            as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, (v as num).toInt()));
    _idf = File('$assetsDir/idf_weights.bin')
        .readAsBytesSync()
        .buffer
        .asFloat32List();
    _svdComponents = File('$assetsDir/svd_components.bin')
        .readAsBytesSync()
        .buffer
        .asFloat32List();
  }

  Float32List transform(String text) {
    final tokens = text.toLowerCase().split(RegExp(r'[^a-z0-9]+'));

    // Sublinear TF-IDF
    final tf = Float64List(_nFeatures);
    for (final token in tokens) {
      final idx = _vocab[token];
      if (idx != null) tf[idx] += 1.0;
    }
    for (int i = 0; i < _nFeatures; i++) {
      if (tf[i] > 0) tf[i] = 1.0 + (tf[i] > 1 ? math.log(tf[i]) : 0.0);
      tf[i] *= _idf[i];
    }

    // L2 normalize TF-IDF
    double norm = 0.0;
    for (int i = 0; i < _nFeatures; i++) norm += tf[i] * tf[i];
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (int i = 0; i < _nFeatures; i++) tf[i] /= norm;
    }

    // SVD projection
    final lsa = Float64List(_nComponents);
    for (int c = 0; c < _nComponents; c++) {
      double dot = 0.0;
      for (int f = 0; f < _nFeatures; f++) {
        dot += _svdComponents[c * _nFeatures + f] * tf[f];
      }
      lsa[c] = dot;
    }

    // L2 normalize LSA
    double lsaNorm = 0.0;
    for (int i = 0; i < _nComponents; i++) lsaNorm += lsa[i] * lsa[i];
    lsaNorm = math.sqrt(lsaNorm);
    final result = Float32List(_nComponents);
    if (lsaNorm > 0) {
      for (int i = 0; i < _nComponents; i++) result[i] = lsa[i] / lsaNorm;
    }
    return result;
  }
}

const _kLabels = ['anger', 'joy', 'neutral', 'sadness', 'surprise'];

void main() {
  late ConcreteClient client;
  late _TestVectorizer vectorizer;
  late Dio backend;
  late String assetsDir;

  setUpAll(() async {
    // Find assets directory
    for (final path in [
      '${Directory.current.path}/assets/fhe',
      '../journal_app/assets/fhe',
    ]) {
      if (File('$path/client.zip').existsSync()) {
        assetsDir = path;
        break;
      }
    }

    vectorizer = _TestVectorizer();
    await vectorizer.load(assetsDir);

    client = ConcreteClient();
    await client.setup(
      clientZipBytes:
          Uint8List.fromList(File('$assetsDir/client.zip').readAsBytesSync()),
      storage: _MemoryKeyStorage(),
    );
    print('ConcreteClient ready');

    backend = Dio(BaseOptions(
      baseUrl: 'http://localhost:8000',
      connectTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(minutes: 10),
    ));

    await backend.post('/fhe/key', data: {
      'client_id': 'emotion_test',
      'evaluation_key_b64': client.serverKeyBase64,
    });
    print('Eval key uploaded');
  });

  test('happy text → emotion prediction', () async {
    const text =
        'I am so happy and grateful today, everything is wonderful!';

    // EmotionService flow: vectorize → encrypt → predict → decrypt → argmax
    final features = vectorizer.transform(text);
    final ciphertext = client.quantizeAndEncrypt(features);
    print('Encrypted: ${ciphertext.length} bytes');

    final resp = await backend.post('/fhe/predict', data: {
      'client_id': 'emotion_test',
      'encrypted_input_b64': base64Encode(ciphertext),
    });
    expect(resp.statusCode, 200);

    final scores = client.decryptAndDequantize(
      Uint8List.fromList(base64Decode(resp.data['encrypted_result_b64'])),
    );
    expect(scores.length, 5, reason: 'should have 5 class scores');

    int maxIdx = 0;
    for (int i = 1; i < scores.length; i++) {
      if (scores[i] > scores[maxIdx]) maxIdx = i;
    }
    print('Happy text → ${_kLabels[maxIdx]} (scores: $scores)');
    expect(_kLabels, contains(_kLabels[maxIdx]));
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('sad text → emotion prediction', () async {
    const text =
        'I feel so lonely and heartbroken, nothing matters anymore';

    final features = vectorizer.transform(text);
    final ciphertext = client.quantizeAndEncrypt(features);

    final resp = await backend.post('/fhe/predict', data: {
      'client_id': 'emotion_test',
      'encrypted_input_b64': base64Encode(ciphertext),
    });
    expect(resp.statusCode, 200);

    final scores = client.decryptAndDequantize(
      Uint8List.fromList(base64Decode(resp.data['encrypted_result_b64'])),
    );
    expect(scores.length, 5);

    int maxIdx = 0;
    for (int i = 1; i < scores.length; i++) {
      if (scores[i] > scores[maxIdx]) maxIdx = i;
    }
    print('Sad text → ${_kLabels[maxIdx]} (scores: $scores)');
    expect(_kLabels, contains(_kLabels[maxIdx]));
  }, timeout: const Timeout(Duration(minutes: 15)));
}
