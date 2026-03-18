# FHE Plugin Restructure — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the boundary between `flutter_concrete` plugin and `journal_app` so the plugin owns the full FHE lifecycle (client.zip parsing, key persistence, encrypt/decrypt) and the app owns domain logic (vectorization, server communication, result interpretation).

**Architecture:** Plugin accepts Concrete ML's standard `client.zip`, parses `serialized_processing.json` for quantization params, manages key generation/persistence via a generic `KeyStorage` interface, and exposes `quantizeAndEncrypt`/`decryptAndDequantize`. The app's `FheClient` is removed; `EmotionService` directly uses `ConcreteClient` and handles vectorization + HTTP + argmax.

**Tech Stack:** Dart (Flutter plugin), `archive` package for zip parsing, `flutter_secure_storage` (app-side `KeyStorage` impl)

**Spec:** `docs/superpowers/specs/2026-03-16-fhe-plugin-restructure-design.md`

---

## File Structure

### Plugin (`flutter_concrete/`)

| File | Responsibility | Change |
|------|---------------|--------|
| `lib/src/key_storage.dart` | `KeyStorage` abstract interface | **Create** |
| `lib/src/client_zip_parser.dart` | Parse `serialized_processing.json` from `client.zip` → `QuantizationParams` | **Create** |
| `lib/src/concrete_client.dart` | `setup()`, `reset()`, `isReady`, key persistence, encrypt/decrypt | **Rewrite** |
| `lib/src/quantizer.dart` | `QuantizationParams`, `InputQuantParam`, `OutputQuantParam` (internal) | **Minor edit** (remove `fromJson`) |
| `lib/src/fhe_native.dart` | FFI bindings (unchanged) | **No change** |
| `lib/flutter_concrete.dart` | Barrel exports | **Edit** |
| `pubspec.yaml` | Add `archive` dependency | **Edit** |
| `README.md` | Update diagram, API docs, limitations | **Rewrite** |
| `test/client_zip_parser_test.dart` | Unit tests for zip parsing | **Create** |
| `test/concrete_client_test.dart` | Unit tests for setup/reset/idempotency | **Create** |

### App (`journal_app/`)

| File | Responsibility | Change |
|------|---------------|--------|
| `lib/services/secure_key_storage.dart` | `KeyStorage` impl wrapping `FlutterSecureStorage` | **Create** |
| `lib/services/emotion_service.dart` | Absorb FheClient logic, use new ConcreteClient API | **Rewrite** |
| `lib/fhe/fhe_client.dart` | Was: FHE orchestration | **Delete** |
| `assets/fhe/quantization_params.json` | Was: custom quant params format | **Delete** |
| `lib/fhe/vectorizer.dart` | Text vectorization | **No change** |
| `lib/models/emotion_result.dart` | Emotion result model | **No change** |
| `lib/main.dart` | Provider tree | **No change** |
| `pubspec.yaml` | Remove quantization_params.json, add client.zip to assets | **Edit** |
| `test/fhe/quantization_test.dart` | Update to load params from client.zip instead of quantization_params.json | **Edit** |

### ML Pipeline (`emotion_ml/`)

| File | Responsibility | Change |
|------|---------------|--------|
| `export_dart_assets.py` | Remove quant param extraction, keep NLP exports + client.zip copy | **Edit** |

---

## Chunk 1: Plugin — KeyStorage Interface + Client Zip Parser

### Task 1: Create `KeyStorage` abstract interface

**Files:**
- Create: `flutter_concrete/lib/src/key_storage.dart`

- [ ] **Step 1: Create KeyStorage interface**

```dart
// lib/src/key_storage.dart

import 'dart:typed_data';

/// App-provided key persistence strategy.
///
/// Keeps the plugin free of flutter_secure_storage or any
/// specific storage dependency.
abstract class KeyStorage {
  /// Read raw bytes for [key], or null if not found.
  Future<Uint8List?> read(String key);

  /// Persist raw [value] bytes under [key].
  Future<void> write(String key, Uint8List value);

  /// Delete the entry for [key].
  Future<void> delete(String key);
}
```

- [ ] **Step 2: Commit**

```bash
git add flutter_concrete/lib/src/key_storage.dart
git commit -m "feat(plugin): add KeyStorage abstract interface"
```

---

### Task 2: Create `ClientZipParser`

**Files:**
- Create: `flutter_concrete/lib/src/client_zip_parser.dart`
- Create: `flutter_concrete/test/client_zip_parser_test.dart`
- Modify: `flutter_concrete/pubspec.yaml`

- [ ] **Step 1: Add `archive` dependency to pubspec.yaml**

In `flutter_concrete/pubspec.yaml`, add under `dependencies`:

```yaml
  archive: ^4.0.0
```

- [ ] **Step 2: Write the failing test**

Create `flutter_concrete/test/client_zip_parser_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_concrete/src/client_zip_parser.dart';

void main() {
  late Uint8List zipBytes;

  setUpAll(() {
    // Use the real client.zip from the journal_app assets for testing.
    // This ensures parser stays compatible with actual Concrete ML output.
    final file = File('${Directory.current.parent.path}/journal_app/assets/fhe/client.zip');
    if (!file.existsSync()) {
      // Fallback: try relative to project root
      final alt = File('../journal_app/assets/fhe/client.zip');
      if (!alt.existsSync()) {
        fail('client.zip not found — run from flutter_concrete/ or project root');
      }
      zipBytes = alt.readAsBytesSync();
    } else {
      zipBytes = file.readAsBytesSync();
    }
  });

  group('ClientZipParser', () {
    test('parses input quantizers from client.zip', () {
      final params = ClientZipParser.parse(zipBytes);
      // 200 input features (LSA components)
      expect(params.input.length, 200);
      // Each has scale > 0 and integer zero_point
      for (final p in params.input) {
        expect(p.scale, isPositive);
        expect(p.zeroPoint, isA<int>());
      }
    });

    test('parses output quantizer from client.zip', () {
      final params = ClientZipParser.parse(zipBytes);
      expect(params.output.scale, isPositive);
      expect(params.output.offset, isA<int>());
    });

    test('validates n_bits is 8', () {
      final badProc = {
        'input_quantizers': [
          {
            'type_name': 'UniformQuantizer',
            'serialized_value': {
              'n_bits': 16,
              'is_signed': false,
              'scale': {'type_name': 'numpy_float', 'serialized_value': 0.01},
              'zero_point': 0,
              'offset': 0,
            }
          }
        ],
        'output_quantizers': [
          {
            'type_name': 'UniformQuantizer',
            'serialized_value': {
              'n_bits': 8,
              'is_signed': true,
              'scale': {'type_name': 'numpy_float', 'serialized_value': 0.01},
              'zero_point': 0,
              'offset': 128,
            }
          }
        ],
      };
      final badZip = _createZipWithProcessing(badProc);
      expect(
        () => ClientZipParser.parse(badZip),
        throwsA(isA<FormatException>().having(
          (e) => e.message, 'message', contains('n_bits'),
        )),
      );
    });

    test('handles zero_point as raw int and as dict', () {
      final proc = {
        'input_quantizers': [
          {
            'type_name': 'UniformQuantizer',
            'serialized_value': {
              'n_bits': 8,
              'is_signed': false,
              'scale': {'type_name': 'numpy_float', 'serialized_value': 0.01},
              'zero_point': {'type_name': 'numpy_integer', 'serialized_value': 42},
              'offset': 0,
            }
          }
        ],
        'output_quantizers': [
          {
            'type_name': 'UniformQuantizer',
            'serialized_value': {
              'n_bits': 8,
              'is_signed': true,
              'scale': {'type_name': 'numpy_float', 'serialized_value': 0.05},
              'zero_point': 7,
              'offset': 128,
            }
          }
        ],
      };
      final zip = _createZipWithProcessing(proc);
      final params = ClientZipParser.parse(zip);
      expect(params.input[0].zeroPoint, 42);
      expect(params.output.zeroPoint, 7);
    });
  });
}

/// Helper: create a minimal zip containing serialized_processing.json.
Uint8List _createZipWithProcessing(Map<String, dynamic> processing) {
  final archive = Archive();
  final jsonBytes = utf8.encode(jsonEncode(processing));
  archive.addFile(ArchiveFile('serialized_processing.json', jsonBytes.length, jsonBytes));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd flutter_concrete && flutter test test/client_zip_parser_test.dart
```

Expected: compilation error — `ClientZipParser` doesn't exist yet.

- [ ] **Step 4: Implement `ClientZipParser`**

Create `flutter_concrete/lib/src/client_zip_parser.dart`:

```dart
// lib/src/client_zip_parser.dart
//
// Parses Concrete ML's client.zip to extract quantization parameters
// from serialized_processing.json.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'quantizer.dart';

/// Parses a Concrete ML `client.zip` and extracts [QuantizationParams].
///
/// The zip must contain `serialized_processing.json` with `input_quantizers`
/// and `output_quantizers` arrays in Concrete ML's UniformQuantizer format.
class ClientZipParser {
  ClientZipParser._();

  /// Parse [zipBytes] and return [QuantizationParams].
  ///
  /// Throws [FormatException] if the zip structure is invalid or
  /// quantization bit width is not 8.
  static QuantizationParams parse(Uint8List zipBytes) {
    final archive = ZipDecoder().decodeBytes(zipBytes);

    final procFile = archive.findFile('serialized_processing.json');
    if (procFile == null) {
      throw FormatException(
        'client.zip missing serialized_processing.json',
      );
    }

    final proc = jsonDecode(utf8.decode(procFile.content as List<int>))
        as Map<String, dynamic>;

    final inputQuantizers = proc['input_quantizers'] as List<dynamic>;
    final outputQuantizers = proc['output_quantizers'] as List<dynamic>;

    if (outputQuantizers.isEmpty) {
      throw FormatException('client.zip has no output_quantizers');
    }

    // Parse input quantizers
    final input = <InputQuantParam>[];
    for (final q in inputQuantizers) {
      final sv = (q as Map<String, dynamic>)['serialized_value']
          as Map<String, dynamic>;
      _validateNBits(sv, signed: false);
      input.add(InputQuantParam(
        scale: _extractFloat(sv['scale']),
        zeroPoint: _extractInt(sv['zero_point']),
      ));
    }

    // Parse output quantizer (first one)
    final outSv = (outputQuantizers[0] as Map<String, dynamic>)
        ['serialized_value'] as Map<String, dynamic>;
    _validateNBits(outSv, signed: true);
    final output = OutputQuantParam(
      scale: _extractFloat(outSv['scale']),
      zeroPoint: _extractInt(outSv['zero_point']),
      offset: _extractInt(outSv['offset']),
    );

    return QuantizationParams(input: input, output: output);
  }

  /// Extract a float value that may be raw or wrapped in
  /// `{"serialized_value": ...}`.
  static double _extractFloat(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is Map<String, dynamic>) {
      return (value['serialized_value'] as num).toDouble();
    }
    throw FormatException('Cannot parse float from: $value');
  }

  /// Extract an int value that may be raw or wrapped in
  /// `{"serialized_value": ...}`.
  static int _extractInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is Map<String, dynamic>) {
      return (value['serialized_value'] as num).toInt();
    }
    throw FormatException('Cannot parse int from: $value');
  }

  /// Validate that n_bits == 8 and is_signed matches expectations.
  static void _validateNBits(Map<String, dynamic> sv, {required bool signed}) {
    final nBits = sv['n_bits'] as int;
    if (nBits != 8) {
      throw FormatException(
        'Unsupported n_bits=$nBits (expected 8). '
        'flutter_concrete only supports 8-bit quantization.',
      );
    }
    final isSigned = sv['is_signed'] as bool;
    if (isSigned != signed) {
      throw FormatException(
        'Unexpected is_signed=$isSigned for ${signed ? "output" : "input"} '
        'quantizer (expected $signed).',
      );
    }
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd flutter_concrete && flutter test test/client_zip_parser_test.dart
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add flutter_concrete/lib/src/client_zip_parser.dart \
        flutter_concrete/test/client_zip_parser_test.dart \
        flutter_concrete/pubspec.yaml
git commit -m "feat(plugin): add ClientZipParser for Concrete ML client.zip"
```

---

## Chunk 2: Plugin — Revise ConcreteClient API

### Task 3: Remove `QuantizationParams.fromJson` and update barrel exports

**Files:**
- Modify: `flutter_concrete/lib/src/quantizer.dart`
- Modify: `flutter_concrete/lib/flutter_concrete.dart`

- [ ] **Step 1: Remove `fromJson` factory from `QuantizationParams`**

In `flutter_concrete/lib/src/quantizer.dart`, delete the `factory QuantizationParams.fromJson` method (lines 35–53). The `QuantizationParams` class, `InputQuantParam`, and `OutputQuantParam` remain — they are now constructed by `ClientZipParser` instead of by app code.

- [ ] **Step 2: Update barrel exports**

Replace `flutter_concrete/lib/flutter_concrete.dart` with:

```dart
/// Concrete ML FHE client for Flutter.
///
/// Provides native TFHE-rs encryption/decryption via Dart FFI,
/// with quantization support for Concrete ML models.
library flutter_concrete;

export 'src/concrete_client.dart' show ConcreteClient;
export 'src/key_storage.dart' show KeyStorage;
```

`FheNative`, `KeygenResult`, `QuantizationParams`, `InputQuantParam`, `OutputQuantParam` are no longer exported — they are internal implementation details.

- [ ] **Step 3: Commit**

```bash
git add flutter_concrete/lib/src/quantizer.dart \
        flutter_concrete/lib/flutter_concrete.dart
git commit -m "refactor(plugin): internalize QuantizationParams, export KeyStorage"
```

---

### Task 4: Rewrite `ConcreteClient` with `setup()`/`reset()` API

**Files:**
- Rewrite: `flutter_concrete/lib/src/concrete_client.dart`
- Create: `flutter_concrete/test/concrete_client_test.dart`

- [ ] **Step 1: Write failing tests for `ConcreteClient`**

Create `flutter_concrete/test/concrete_client_test.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_concrete/flutter_concrete.dart';

/// In-memory KeyStorage for testing.
class MemoryKeyStorage implements KeyStorage {
  final Map<String, Uint8List> _store = {};

  @override
  Future<Uint8List?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, Uint8List value) async => _store[key] = value;

  @override
  Future<void> delete(String key) async => _store.remove(key);

  bool containsKey(String key) => _store.containsKey(key);
}

void main() {
  group('ConcreteClient', () {
    test('isReady is false before setup', () {
      final client = ConcreteClient();
      expect(client.isReady, isFalse);
    });

    test('serverKey throws before setup', () {
      final client = ConcreteClient();
      expect(() => client.serverKey, throwsStateError);
    });

    test('serverKeyBase64 throws before setup', () {
      final client = ConcreteClient();
      expect(() => client.serverKeyBase64, throwsStateError);
    });

    test('reset makes isReady false again', () async {
      // Note: full setup test requires native library + real client.zip.
      // This test validates reset logic on a client that hasn't been set up.
      final client = ConcreteClient();
      client.reset();
      expect(client.isReady, isFalse);
    });
  });
}
```

**Note:** Full integration tests for `setup()` (keygen, zip parsing, key persistence) require the native Rust library and a real `client.zip`. These are better tested as integration tests. The unit tests above verify the state machine behavior.

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd flutter_concrete && flutter test test/concrete_client_test.dart
```

Expected: failures because `ConcreteClient()` no longer accepts no-arg constructor (current code requires `quantParams`).

- [ ] **Step 3: Rewrite `ConcreteClient`**

Replace `flutter_concrete/lib/src/concrete_client.dart`:

```dart
// lib/src/concrete_client.dart
//
// High-level Concrete ML FHE client.
//
// Owns the full FHE lifecycle: client.zip parsing, key management,
// quantization, encryption, and decryption.

import 'dart:convert';
import 'dart:typed_data';

import 'client_zip_parser.dart';
import 'fhe_native.dart';
import 'key_storage.dart';
import 'quantizer.dart';

// Storage key names for key persistence.
const _kClientKeyStorageKey = 'fhe_client_key';
const _kServerKeyStorageKey = 'fhe_server_key';

/// High-level client for Concrete ML FHE operations.
///
/// Call [setup] once with the Concrete ML `client.zip` bytes and a
/// [KeyStorage] implementation. After setup, use [quantizeAndEncrypt]
/// and [decryptAndDequantize] for FHE inference.
class ConcreteClient {
  final FheNative _native = FheNative();

  QuantizationParams? _quantParams;
  Uint8List? _clientKey;
  Uint8List? _serverKey;
  String? _serverKeyB64Cache;
  bool _isReady = false;

  /// True after [setup] completes successfully.
  bool get isReady => _isReady;

  /// Raw server (evaluation) key bytes.
  ///
  /// Throws [StateError] if called before [setup].
  Uint8List get serverKey {
    _requireReady();
    return _serverKey!;
  }

  /// Base64-encoded server key. Cached after first access.
  String get serverKeyBase64 {
    _requireReady();
    return _serverKeyB64Cache ??= base64Encode(_serverKey!);
  }

  /// Parse [clientZipBytes] (Concrete ML `client.zip`), extract
  /// quantization params, and generate or restore FHE keys via [storage].
  ///
  /// Idempotent: subsequent calls are no-ops if already set up.
  /// Call [reset] first to re-initialize with a different model.
  Future<void> setup({
    required Uint8List clientZipBytes,
    required KeyStorage storage,
  }) async {
    if (_isReady) return;

    // 1. Parse quantization params from client.zip
    _quantParams = ClientZipParser.parse(clientZipBytes);

    // 2. Try to restore persisted keys
    final storedClient = await storage.read(_kClientKeyStorageKey);
    final storedServer = await storage.read(_kServerKeyStorageKey);

    if (storedClient != null && storedServer != null) {
      _clientKey = storedClient;
      _serverKey = storedServer;
    } else {
      // Generate fresh keys (CPU-intensive)
      final result = _native.keygen();
      _clientKey = result.clientKey;
      _serverKey = result.serverKey;
      // lweKey is discarded (unused, retained in FFI for ABI stability)

      // Persist for next launch
      await Future.wait([
        storage.write(_kClientKeyStorageKey, _clientKey!),
        storage.write(_kServerKeyStorageKey, _serverKey!),
      ]);
    }

    _isReady = true;
  }

  /// Clear internal state so [setup] can be called again.
  ///
  /// Does not delete persisted keys from storage.
  void reset() {
    _isReady = false;
    _quantParams = null;
    _clientKey = null;
    _serverKey = null;
    _serverKeyB64Cache = null;
  }

  /// Quantize a float feature vector to uint8 and FHE-encrypt it.
  ///
  /// Returns encrypted ciphertext bytes (bincode `Vec<FheUint8>`).
  Uint8List quantizeAndEncrypt(Float32List features) {
    _requireReady();
    final quantized = _quantParams!.quantizeInputs(features);
    return _native.encryptU8(_clientKey!, quantized);
  }

  /// FHE-decrypt ciphertext and dequantize to float scores.
  ///
  /// Returns dequantized float64 scores (one per output class).
  Float64List decryptAndDequantize(Uint8List ciphertext) {
    _requireReady();
    final rawScores = _native.decryptI8(_clientKey!, ciphertext);
    return _quantParams!.dequantizeOutputs(rawScores);
  }

  void _requireReady() {
    if (!_isReady) {
      throw StateError('ConcreteClient: call setup() first');
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd flutter_concrete && flutter test test/concrete_client_test.dart
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add flutter_concrete/lib/src/concrete_client.dart \
        flutter_concrete/test/concrete_client_test.dart
git commit -m "feat(plugin): rewrite ConcreteClient with setup()/reset() API"
```

---

### Task 5: Update README

**Files:**
- Rewrite: `flutter_concrete/README.md`

- [ ] **Step 1: Rewrite README**

```markdown
# flutter_concrete

A Flutter FFI plugin that brings [Concrete ML](https://docs.zama.ai/concrete-ml) FHE (Fully Homomorphic Encryption) to mobile apps. The native cryptographic operations — key generation, encryption, and decryption — run entirely on-device via [TFHE-rs](https://github.com/zama-ai/tfhe-rs), with no server-side private key material.

The Rust library builds automatically during `flutter build` thanks to [Cargokit](https://github.com/irondash/cargokit) — no manual build scripts or precompiled binaries required.

## How it works

```
Your App                              flutter_concrete
───────                               ────────────────
                                           │
Load client.zip from assets ──────►  setup(zipBytes, storage)
                                       parse serialized_processing.json
                                       restore or generate keys
                                     ◄── isReady = true
                                           │
Get serverKey ◄────────────────────  serverKey / serverKeyBase64
Upload to your server (your code)          │
                                           │
Float32 features ──────────────────►  quantizeAndEncrypt()
Uint8List ciphertext ◄──────────────       │
Send to server (your code)                 │
Receive result (your code)                 │
Uint8List encrypted result ────────►  decryptAndDequantize()
Float64 class scores ◄──────────────       │
Interpret scores (your code)
```

The server performs ML inference on **encrypted** data — it never sees plaintext inputs or predictions.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_concrete:
    git:
      url: https://github.com/afonsomota/flutter_concrete.git
```

Or as a local path dependency:

```yaml
dependencies:
  flutter_concrete:
    path: ../flutter_concrete
```

### Prerequisites

- **Rust toolchain** — install via [rustup](https://rustup.rs/)
- iOS targets: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios`
- Android targets: `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android`

## Usage

```dart
import 'package:flutter_concrete/flutter_concrete.dart';

// 1. Implement KeyStorage (e.g. wrapping flutter_secure_storage)
class MyKeyStorage implements KeyStorage {
  @override
  Future<Uint8List?> read(String key) async { /* ... */ }
  @override
  Future<void> write(String key, Uint8List value) async { /* ... */ }
  @override
  Future<void> delete(String key) async { /* ... */ }
}

// 2. Create client and set up from Concrete ML's client.zip
final client = ConcreteClient();
final zipBytes = await loadClientZipFromAssets(); // your asset loading
await client.setup(
  clientZipBytes: zipBytes,
  storage: MyKeyStorage(),
);
// First call generates keys (~10-60s on mobile), subsequent calls restore.

// 3. Get server key to upload to your backend
final serverKey = client.serverKey;       // Uint8List
final serverKeyB64 = client.serverKeyBase64; // String (cached)
// Upload to your server however you want

// 4. Encrypt features
final ciphertext = client.quantizeAndEncrypt(featureVector);
// Send ciphertext to your server for FHE inference

// 5. Decrypt server response
final scores = client.decryptAndDequantize(encryptedResult);
// scores is Float64List — apply argmax for classification
```

## API

### `ConcreteClient`

| Method | Description |
|--------|-------------|
| `Future<void> setup({clientZipBytes, storage})` | Parse `client.zip`, generate/restore keys |
| `void reset()` | Clear state so `setup()` can be called with a different model |
| `bool get isReady` | True after `setup()` completes |
| `Uint8List get serverKey` | Raw evaluation key bytes (throws before setup) |
| `String get serverKeyBase64` | Base64-encoded server key (cached) |
| `Uint8List quantizeAndEncrypt(Float32List)` | Quantize + FHE encrypt |
| `Float64List decryptAndDequantize(Uint8List)` | FHE decrypt + dequantize |

### `KeyStorage` (abstract — you implement this)

| Method | Description |
|--------|-------------|
| `Future<Uint8List?> read(String key)` | Read stored bytes, or null |
| `Future<void> write(String key, Uint8List value)` | Persist bytes |
| `Future<void> delete(String key)` | Delete entry |

## Compatibility

- **Concrete ML**: Accepts standard `client.zip` from `FHEModelDev.save()`
- **TFHE-rs**: Git revision `1ec21a5` (matching `concrete-ml-extensions` 0.2.0)
- **Parameter set**: `V0_10_PARAM_MESSAGE_2_CARRY_2_KS_PBS_GAUSSIAN_2M64`
- **Serialization**: bincode (ciphertexts), Cap'n Proto (evaluation keys)
- **Platforms**: iOS, Android

## Known limitations

1. **Hardcoded eval key topology** — key generation produces 4 BSKs and 8 KSKs matching a specific Concrete ML circuit. Future: parse `client.specs.json` for dynamic key topology.

2. **uint8 input / int8 output only** — matches 8-bit quantization. Other bit widths are not yet supported.

3. **Single input/output tensor** — assumes one input and one output tensor per circuit.

4. **No precompiled binaries** — requires Rust toolchain on the build machine.

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add flutter_concrete/README.md
git commit -m "docs(plugin): update README for new setup() API and client.zip parsing"
```

---

## Chunk 3: App — SecureKeyStorage + EmotionService Rewrite

### Task 6: Create `SecureKeyStorage`

**Files:**
- Create: `journal_app/lib/services/secure_key_storage.dart`

- [ ] **Step 1: Create SecureKeyStorage**

```dart
// lib/services/secure_key_storage.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_concrete/flutter_concrete.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// [KeyStorage] implementation backed by [FlutterSecureStorage].
///
/// Stores raw bytes as base64-encoded strings since
/// flutter_secure_storage only supports String values.
///
/// Handles migration from legacy versioned key names (`_v2` suffix)
/// used by the old FheClient.
class SecureKeyStorage implements KeyStorage {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  // Old key names from FheClient (v2 = Cap'n Proto ServerKeyset format).
  static const _legacyKeyMap = {
    'fhe_client_key': 'fhe_client_key_v2',
    'fhe_server_key': 'fhe_server_key_v2',
  };

  @override
  Future<Uint8List?> read(String key) async {
    // Try new key name first
    var b64 = await _storage.read(key: key);
    if (b64 != null) return base64Decode(b64);

    // Fall back to legacy key name (one-time migration)
    final legacyKey = _legacyKeyMap[key];
    if (legacyKey != null) {
      b64 = await _storage.read(key: legacyKey);
      if (b64 != null) {
        // Migrate: write under new name, delete old
        await _storage.write(key: key, value: b64);
        await _storage.delete(key: legacyKey);
        return base64Decode(b64);
      }
    }
    return null;
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

- [ ] **Step 2: Commit**

```bash
git add journal_app/lib/services/secure_key_storage.dart
git commit -m "feat(app): add SecureKeyStorage implementing KeyStorage"
```

---

### Task 7: Rewrite `EmotionService` to use new `ConcreteClient` API

**Files:**
- Rewrite: `journal_app/lib/services/emotion_service.dart`
- Delete: `journal_app/lib/fhe/fhe_client.dart`

- [ ] **Step 1: Rewrite EmotionService**

Replace `journal_app/lib/services/emotion_service.dart`:

```dart
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
```

- [ ] **Step 2: Delete `fhe_client.dart`**

```bash
rm journal_app/lib/fhe/fhe_client.dart
```

- [ ] **Step 3: Verify no remaining imports of `fhe_client.dart`**

```bash
cd journal_app && grep -r "fhe_client" lib/ --include="*.dart"
```

Expected: no results (the only import was in `emotion_service.dart` which is now rewritten).

- [ ] **Step 4: Commit**

```bash
git add journal_app/lib/services/emotion_service.dart \
        journal_app/lib/services/secure_key_storage.dart
git rm journal_app/lib/fhe/fhe_client.dart
git commit -m "refactor(app): merge FheClient into EmotionService, use new ConcreteClient API"
```

---

## Chunk 4: Cleanup — Export Script + Remove Stale Assets

### Task 8: Simplify `export_dart_assets.py`

**Files:**
- Modify: `emotion_ml/export_dart_assets.py`

- [ ] **Step 1: Remove quantization extraction from export script**

Replace `emotion_ml/export_dart_assets.py`:

```python
#!/usr/bin/env python3
"""
Export TF-IDF, SVD, and FHE client assets to portable formats
for use by the Flutter app.

Run once after training:
    python emotion_ml/export_dart_assets.py

Outputs to journal_app/assets/fhe/:
    vocab.json              — word → index map (str → int)
    idf_weights.bin         — 5000 × float32, little-endian
    svd_components.bin      — 200 × 5000 × float32, little-endian, row-major
    client.zip              — Concrete ML client model (parsed by flutter_concrete plugin)
"""

import json
import shutil
from pathlib import Path

import joblib
import numpy as np

ROOT = Path(__file__).parent.parent
ASSETS_SRC = ROOT / "fhe_client" / "assets"
ASSETS_OUT = ROOT / "journal_app" / "assets" / "fhe"
CLIENT_ZIP = ASSETS_SRC / "fhe_model" / "client.zip"


def main() -> None:
    ASSETS_OUT.mkdir(parents=True, exist_ok=True)

    # ── Load sklearn artifacts ─────────────────────────────────────────────────
    tfidf = joblib.load(ASSETS_SRC / "tfidf_vectorizer.pkl")
    svd = joblib.load(ASSETS_SRC / "svd.pkl")

    # ── 1. vocab.json — word → column-index ───────────────────────────────────
    vocab: dict[str, int] = {word: int(idx) for word, idx in tfidf.vocabulary_.items()}
    (ASSETS_OUT / "vocab.json").write_text(
        json.dumps(vocab, ensure_ascii=False, separators=(",", ":"))
    )
    print(f"vocab.json        : {len(vocab)} terms")

    # ── 2. idf_weights.bin — float32 array, length = n_features ──────────────
    idf = tfidf.idf_.astype(np.float32)
    (ASSETS_OUT / "idf_weights.bin").write_bytes(idf.tobytes())
    print(f"idf_weights.bin   : {idf.shape} float32  ({idf.nbytes} bytes)")

    # ── 3. svd_components.bin — (n_components × n_features) float32, row-major
    components = svd.components_.astype(np.float32)  # (200, 5000)
    (ASSETS_OUT / "svd_components.bin").write_bytes(components.tobytes())
    print(
        f"svd_components.bin: {components.shape} float32  ({components.nbytes} bytes)"
    )

    # ── 4. client.zip — Concrete ML standard artifact ─────────────────────────
    # Parsed at runtime by flutter_concrete plugin (extracts quantization
    # params from serialized_processing.json inside the zip).
    shutil.copy2(CLIENT_ZIP, ASSETS_OUT / "client.zip")
    print(f"client.zip        : {(ASSETS_OUT / 'client.zip').stat().st_size} bytes")

    print(f"\nAll assets written to: {ASSETS_OUT}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Delete `quantization_params.json` from app assets**

```bash
rm journal_app/assets/fhe/quantization_params.json
```

- [ ] **Step 3: Update `journal_app/pubspec.yaml` assets list**

In `journal_app/pubspec.yaml`, under `flutter: assets:`:
- Remove `- assets/fhe/quantization_params.json` (line 56)
- Add `- assets/fhe/client.zip` (needed by `rootBundle.load` in EmotionService)

- [ ] **Step 4: Commit**

```bash
git add emotion_ml/export_dart_assets.py
git rm journal_app/assets/fhe/quantization_params.json 2>/dev/null || true
git add journal_app/pubspec.yaml
git commit -m "cleanup: remove quantization_params.json, simplify export script"
```

---

### Task 9: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md architecture section**

Update the Architecture section to reflect the new boundary:
- `flutter_concrete` now owns: client.zip parsing, key persistence via KeyStorage, encrypt/decrypt
- `FheClient` class no longer exists
- `EmotionService` directly uses `ConcreteClient`
- `quantization_params.json` no longer exists (plugin parses `client.zip` directly)

Update the Status section:
- Move "flutter_concrete plugin" to completed with note about client.zip parsing and KeyStorage
- Remove references to `quantization_params.json`

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for plugin restructure"
```

---

### Task 10: Verify build

- [ ] **Step 1: Run flutter analyze on plugin**

```bash
cd flutter_concrete && flutter analyze
```

Expected: no errors.

- [ ] **Step 2: Run plugin tests**

```bash
cd flutter_concrete && flutter test
```

Expected: all tests pass.

- [ ] **Step 3: Run flutter analyze on app**

```bash
cd journal_app && flutter analyze
```

Expected: no errors.

- [ ] **Step 4: Run app tests**

```bash
cd journal_app && flutter test
```

Expected: all tests pass (vectorizer tests should still pass, quantization tests may need updating if they imported `QuantizationParams` from the plugin).

- [ ] **Step 5: Update `quantization_test.dart`**

The test at `journal_app/test/fhe/quantization_test.dart` loads `quantization_params.json` from assets (line 110). Since that file is deleted, update the test to load params from `client.zip` using `ClientZipParser`.

In `setUpAll()`, replace:
```dart
final raw = await rootBundle.loadString('assets/fhe/quantization_params.json');
final params = json.decode(raw) as Map<String, dynamic>;
inputQuantizers = (params['input'] as List)
    .cast<Map<String, dynamic>>();
outputQuantizer = params['output'] as Map<String, dynamic>;
```

With:
```dart
// Load quantization params from client.zip via ClientZipParser
final zipBytes = File('../journal_app/assets/fhe/client.zip').readAsBytesSync();
final qp = ClientZipParser.parse(zipBytes);
// Convert to the Map format the test expects
inputQuantizers = qp.input.map((p) => {
  'scale': p.scale,
  'zero_point': p.zeroPoint,
}).toList();
outputQuantizer = {
  'scale': qp.output.scale,
  'zero_point': qp.output.zeroPoint,
  'offset': qp.output.offset,
  'n_classes': 5,
};
```

Add imports at the top:
```dart
import 'dart:io';
import 'package:flutter_concrete/src/client_zip_parser.dart';
```

Remove the now-unused imports:
```dart
// Remove: import 'package:flutter/services.dart';
```

Remove the `TestWidgetsFlutterBinding.ensureInitialized();` call (no longer needed since we're not using `rootBundle`).

Remove the `'output quantizer has required fields'` test that checks for `n_classes` (that was our custom field, not in `ClientZipParser` output — or update the assertion to just check `scale`, `zero_point`, `offset`).

- [ ] **Step 6: Run app tests to verify everything passes**

```bash
cd journal_app && flutter test
```

Expected: all tests pass.

- [ ] **Step 7: Commit test fixes**

```bash
git add journal_app/test/fhe/quantization_test.dart
git commit -m "fix: update quantization test to load params from client.zip"
```
