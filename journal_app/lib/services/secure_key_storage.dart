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
