# FHE Plugin Restructure — Design Spec

## Problem

The boundary between `flutter_concrete` (plugin) and `journal_app` (app) is unclear. Key persistence, quantization params loading, and asset management live in the app's `FheClient` class, but they are FHE concerns that belong in the plugin. Additionally, quantization parameter extraction from `client.zip` lives in the app's ML export script (`export_dart_assets.py`) as a custom intermediate format (`quantization_params.json`), when the plugin should understand Concrete ML's standard `client.zip` artifact directly.

The plugin should be a self-contained, domain-agnostic FHE client that accepts standard Concrete ML artifacts and can be used by any app regardless of its preprocessing pipeline.

## Design

### Plugin (`flutter_concrete`)

The plugin owns the full FHE lifecycle: setup from Concrete ML's standard `client.zip`, key generation/persistence, encryption, and decryption. It is domain-agnostic — it knows nothing about NLP, emotion classification, or server communication.

#### `client.zip` Parsing (Concrete ML Standard)

Concrete ML's `FHEModelDev.save()` produces `client.zip` containing:
- `serialized_processing.json` — quantizer definitions (input/output scale, zero_point, offset, n_bits, is_signed)
- `client.specs.json` — crypto parameters (future: use for dynamic key topology instead of hardcoded params)
- `versions.json` — Concrete ML version info

During `setup()`, the plugin:
1. Extracts `serialized_processing.json` from the zip
2. Parses input quantizers (per-feature scale + zero_point) and output quantizer (scale + zero_point + offset)
3. Validates `n_bits == 8` and `is_signed` matches expectations (uint8 input, int8 output) — throws if incompatible
4. Constructs `QuantizationParams` internally — the app never sees this type

**Parsing details:** The `serialized_processing.json` structure has nested quantizer objects where `zero_point` can be either a raw int or a `{"serialized_value": int}` dict. The parser must handle both forms. Reference implementation: `export_dart_assets.py` lines 58–91.

This resolves known limitation #3 ("No `client.zip` parsing") from the README.

**Future improvement:** Parse `client.specs.json` to dynamically configure key topology, resolving limitation #1 ("Hardcoded eval key topology").

#### Generic Key Storage Interface

```dart
/// App-provided key persistence strategy.
/// Keeps the plugin free of flutter_secure_storage dependency.
abstract class KeyStorage {
  Future<Uint8List?> read(String key);
  Future<void> write(String key, Uint8List value);
  Future<void> delete(String key);
}
```

#### `ConcreteClient` API (revised)

```dart
class ConcreteClient {
  /// Parse client.zip (Concrete ML standard artifact),
  /// extract quantization params from serialized_processing.json,
  /// generate or restore keys via provided storage.
  ///
  /// Idempotent: subsequent calls with the same zip are no-ops if already
  /// set up. To re-initialize with a different model, call reset() first.
  Future<void> setup({
    required Uint8List clientZipBytes,
    required KeyStorage storage,
  });

  /// Clears internal state, allowing setup() to be called again
  /// with a different client.zip. Does not delete persisted keys.
  void reset();

  /// True after setup() completes successfully (keys + quant params ready).
  bool get isReady;

  /// Raw server key bytes. Throws StateError if called before setup().
  Uint8List get serverKey;

  /// Convenience: base64-encoded serverKey. Cached after first access.
  String get serverKeyBase64;

  /// Quantize float features and FHE-encrypt.
  Uint8List quantizeAndEncrypt(Float32List features);

  /// FHE-decrypt and dequantize back to float scores.
  Float64List decryptAndDequantize(Uint8List ciphertext);
}
```

#### Key Persistence

During `setup()`, the plugin:
1. Checks `KeyStorage` for existing keys (storage keys: `fhe_client_key`, `fhe_server_key`)
2. If found, restores them (skips expensive keygen)
3. If not found, generates new keys and persists via `KeyStorage`

**Migration from existing keys:** The app previously used versioned storage keys (`fhe_client_key_v2`, `fhe_server_key_v2`). The app's `SecureKeyStorage` implementation can handle migration by checking old key names on first access if backward compatibility is needed, or keys can simply be regenerated on first launch after the update.

The `lweKey` from `FheNative.keygen()` is discarded (unused; retained in FFI for ABI stability only).

The app never touches raw key bytes directly.

#### Files Changed in Plugin

| File | Change |
|------|--------|
| `lib/src/concrete_client.dart` | Add `setup()` and `reset()`; remove `QuantizationParams` constructor param and `generateKeys()`/`restoreKeys()` from public API; add `isReady`, `serverKeyBase64`; make `serverKey` non-nullable (throws before setup) |
| `lib/src/client_zip_parser.dart` | New file: parse `serialized_processing.json` from `client.zip`, extract and validate quantization params (logic moved from `export_dart_assets.py`) |
| `lib/src/key_storage.dart` | New file: `KeyStorage` abstract class |
| `lib/flutter_concrete.dart` | Export `KeyStorage`; stop exporting `QuantizationParams`, `KeygenResult` (internal concerns now) |
| `pubspec.yaml` | Add `archive: ^4.0.0` dependency for zip parsing |
| `README.md` | Update diagram (remove server arrows), update API docs, remove limitation #3, document `client.zip` as input |

### App (`journal_app`)

The app owns domain-specific logic: text vectorization, server communication, and emotion label interpretation. `FheClient` is removed; its remaining responsibilities merge into `EmotionService`.

#### `EmotionService` (revised)

Absorbs `FheClient`'s responsibilities. Existing state management (caching via `_cache`, in-progress tracking via `_inProgress`/`isClassifying()`, pending retry via `_pendingRetry`, graceful degradation via `_available`/`available`, and all `notifyListeners()` calls) is preserved unchanged.

```dart
class EmotionService extends ChangeNotifier {
  final ConcreteClient _concrete = ConcreteClient();
  final Vectorizer _vectorizer = Vectorizer();
  late final Dio _backend;

  // Emotion labels (domain-specific, not plugin's concern)
  static const _labels = ['anger', 'joy', 'neutral', 'sadness', 'surprise'];

  // Existing state preserved: _initialized, _available, _cache,
  // _inProgress, _pendingRetry, notifyListeners() calls

  Future<void> initialize() async {
    if (_initialized) return;

    // 1. Load vectorizer + setup FHE client in parallel
    final zipBytes = await rootBundle.load('assets/fhe/client.zip');
    await Future.wait([
      _vectorizer.load(),
      _concrete.setup(
        clientZipBytes: zipBytes.buffer.asUint8List(),
        storage: SecureKeyStorage(),
      ),
    ]);

    // 2. Upload server key to backend
    await _backend.post('/fhe/key', data: {
      'client_id': _clientId,
      'evaluation_key_b64': _concrete.serverKeyBase64,
    });

    _initialized = true;
  }

  Future<EmotionResult?> classifyEntry(String entryId, String plaintext) async {
    // 1. Vectorize (app-specific preprocessing)
    final features = _vectorizer.transform(plaintext);

    // 2. Encrypt (plugin)
    final ciphertext = _concrete.quantizeAndEncrypt(features);

    // 3. Send to server (app-specific)
    final response = await _backend.post('/fhe/predict', data: {
      'client_id': _clientId,
      'encrypted_input_b64': base64Encode(ciphertext),
    });

    // 4. Decrypt (plugin)
    final encryptedResult = base64Decode(response.data['encrypted_result_b64']);
    final scores = _concrete.decryptAndDequantize(encryptedResult);

    // 5. Interpret (app-specific: argmax over scores)
    int maxIdx = 0;
    for (int i = 1; i < scores.length; i++) {
      if (scores[i] > scores[maxIdx]) maxIdx = i;
    }
    return EmotionResult(emotion: _labels[maxIdx], confidence: scores[maxIdx]);
  }

  // Error recovery: on backend failure, set _initialized = false
  // so next call re-uploads server key (setup() is idempotent,
  // so re-calling it is a no-op — only the key upload repeats).
}
```

#### `SecureKeyStorage` (app-provided implementation)

```dart
class SecureKeyStorage implements KeyStorage {
  final _storage = FlutterSecureStorage();

  @override
  Future<Uint8List?> read(String key) async {
    final b64 = await _storage.read(key: key);
    return b64 != null ? base64Decode(b64) : null;
  }

  @override
  Future<void> write(String key, Uint8List value) async {
    await _storage.write(key: key, value: base64Encode(value));
  }

  @override
  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }
}
```

#### `export_dart_assets.py` (revised)

Remove quantization parameter extraction (lines 58–91). The script exports NLP-specific assets only:
- `vocab.json` — TF-IDF vocabulary
- `idf_weights.bin` — IDF weights
- `svd_components.bin` — LSA components
- `client.zip` — copied as-is (Concrete ML standard artifact, parsed by plugin at runtime)

The `quantization_params.json` output is eliminated — the plugin now parses `serialized_processing.json` from `client.zip` directly.

#### Files Changed in App

| File | Change |
|------|--------|
| `lib/fhe/fhe_client.dart` | Delete |
| `lib/services/emotion_service.dart` | Absorb FheClient logic; use revised ConcreteClient API; add inline argmax |
| `lib/services/secure_key_storage.dart` | New file: `KeyStorage` implementation wrapping `FlutterSecureStorage` |
| `lib/fhe/vectorizer.dart` | No change (stays in app) |
| `emotion_ml/export_dart_assets.py` | Remove quantization extraction (lines 58–91); keep NLP asset exports and `client.zip` copy |
| `journal_app/assets/fhe/quantization_params.json` | Delete (no longer needed) |
| `pubspec.yaml` | No change (already depends on `flutter_concrete` and `flutter_secure_storage`) |

### Data Flow (revised)

```
App (EmotionService)                    Plugin (ConcreteClient)         Server
────────────────────                    ───────────────────────         ──────

Load client.zip from assets ──────►  setup(zipBytes, storage)
                                       extract serialized_processing.json
                                       validate n_bits, is_signed
                                       parse quantization params
                                       restore or generate keys
                                     ◄── isReady = true

Get serverKeyBase64 ◄────────────────  serverKeyBase64
Upload key to server ──────────────────────────────────────────────►  store eval key

Vectorize text (Vectorizer)
Float32 features ────────────────────►  quantizeAndEncrypt()
Uint8List ciphertext ◄────────────────
Base64 encode + POST ──────────────────────────────────────────────►  FHE inference
Receive response ◄─────────────────────────────────────────────────
Base64 decode
Uint8List encrypted result ──────────►  decryptAndDequantize()
Float64 scores ◄──────────────────────
Argmax → EmotionResult
```

### What Does NOT Change

- `Vectorizer` — stays in app, domain-specific
- `EmotionResult` model — stays in app
- Backend endpoints — no changes
- Rust native code — no changes (FFI layer is already correct)
- `FheNative` — no changes (low-level FFI stays as-is)
- `QuantizationParams` — stays in plugin, becomes internal (not exported), loaded from `client.zip`

### Testing

- Plugin unit tests: `ConcreteClient.setup()` with mock `KeyStorage`, verify key restore vs generate paths
- Plugin unit tests: zip parsing correctly extracts quantization params from `serialized_processing.json` (including both `zero_point` formats)
- Plugin unit tests: `setup()` is idempotent on repeated calls; `reset()` allows re-setup
- Plugin unit tests: `setup()` throws on incompatible `n_bits` or `is_signed` values
- App unit tests: `EmotionService` with mock `ConcreteClient`, verify full classify flow
- Integration test: end-to-end emotion classification with real backend
