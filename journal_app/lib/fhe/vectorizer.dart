// lib/fhe/vectorizer.dart
//
// Pure-Dart TF-IDF + LSA + L2-normalize pipeline.
//
// Replicates the Python sidecar's feature-extraction stage:
//   text → token counts → sublinear TF × IDF → L2 normalize → SVD → L2 normalize
//
// Parameters are loaded from binary assets produced by emotion_ml/export_dart_assets.py:
//   assets/fhe/vocab.json          — word → column index
//   assets/fhe/idf_weights.bin     — float32[5000]
//   assets/fhe/svd_components.bin  — float32[50 × 5000], row-major

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// TF-IDF + TruncatedSVD + L2 normalizer.
///
/// Call [load] once before using [transform].
class Vectorizer {
  static const int _nFeatures = 5000;
  static const int _nComponents = 50;

  // Word → column index in TF-IDF matrix
  late Map<String, int> _vocab;
  // IDF weight per column
  late Float32List _idf; // length = _nFeatures
  // SVD components matrix, stored flat in row-major order
  late Float32List _components; // length = _nComponents * _nFeatures

  bool _loaded = false;

  /// Load binary assets. Safe to call multiple times (no-op after first load).
  Future<void> load() async {
    if (_loaded) return;

    final vocabJson = await rootBundle.loadString('assets/fhe/vocab.json');
    final rawVocab = json.decode(vocabJson) as Map<String, dynamic>;
    _vocab = rawVocab.map((k, v) => MapEntry(k, v as int));

    final idfData = await rootBundle.load('assets/fhe/idf_weights.bin');
    _idf = idfData.buffer.asFloat32List();

    final svdData = await rootBundle.load('assets/fhe/svd_components.bin');
    _components = svdData.buffer.asFloat32List();

    _loaded = true;
  }

  /// Transform [text] → 50-dimensional L2-normalised LSA feature vector.
  ///
  /// Matches the Python pipeline exactly:
  ///   1. Tokenise with \b\w{2,}\b, lowercase
  ///   2. Term frequency: tf = 1 + log(count)  (sublinear_tf=True)
  ///   3. TF-IDF: tfidf[i] = tf[i] * idf[i]
  ///   4. L2-normalise the TF-IDF vector
  ///   5. SVD: out = tfidf_vec × components^T  → 50-dim
  ///   6. L2-normalise the 50-dim vector
  Float32List transform(String text) {
    assert(_loaded, 'Call load() before transform()');

    // ── Step 1: tokenise ─────────────────────────────────────────────────────
    // Python tokenizer pattern: (?u)\b\w\w+\b  (2+ word chars, unicode)
    // For English text [a-zA-Z0-9_]{2,} matches the same vocabulary.
    final tokenRe = RegExp(r'[a-zA-Z0-9_]{2,}');
    final lower = text.toLowerCase();
    final counts = <int, int>{}; // vocab_idx → term count

    // Unigrams
    for (final m in tokenRe.allMatches(lower)) {
      final token = m.group(0)!;
      final idx = _vocab[token];
      if (idx != null) {
        counts[idx] = (counts[idx] ?? 0) + 1;
      }
    }

    // Bigrams: consecutive token pairs separated by the same pattern
    final uniTokens = tokenRe.allMatches(lower).map((m) => m.group(0)!).toList();
    for (int i = 0; i < uniTokens.length - 1; i++) {
      final bigram = '${uniTokens[i]} ${uniTokens[i + 1]}';
      final idx = _vocab[bigram];
      if (idx != null) {
        counts[idx] = (counts[idx] ?? 0) + 1;
      }
    }

    // ── Step 2–3: sublinear TF × IDF ─────────────────────────────────────────
    final tfidf = Float32List(_nFeatures);
    for (final entry in counts.entries) {
      final i = entry.key;
      final count = entry.value;
      final tf = 1.0 + math.log(count); // sublinear_tf
      tfidf[i] = tf * _idf[i];
    }

    // ── Step 4: L2 normalise TF-IDF vector ───────────────────────────────────
    _l2Normalize(tfidf);

    // ── Step 5: SVD — tfidf @ components^T → 50-dim ────────────────────────
    // components shape: (50, 5000), stored row-major in _components.
    // result[j] = dot(tfidf, components[j])
    // Optimised: only iterate non-zero indices of tfidf.
    final nonZeroIdx = counts.keys.toList();
    final svdOut = Float32List(_nComponents);
    for (int j = 0; j < _nComponents; j++) {
      final rowOffset = j * _nFeatures;
      double sum = 0.0;
      for (final i in nonZeroIdx) {
        sum += tfidf[i] * _components[rowOffset + i];
      }
      svdOut[j] = sum;
    }

    // ── Step 6: L2 normalise SVD output ──────────────────────────────────────
    _l2Normalize(svdOut);

    return svdOut;
  }

  static void _l2Normalize(Float32List v) {
    double norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    if (norm == 0.0) return;
    final invNorm = 1.0 / math.sqrt(norm);
    for (int i = 0; i < v.length; i++) {
      v[i] *= invNorm;
    }
  }
}
