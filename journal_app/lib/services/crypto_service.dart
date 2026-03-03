// services/crypto_service.dart
//
// [Step 3] Client-side symmetric encryption.
//
// The user's password is fed into Argon2id to derive a 32-byte symmetric key.
// That key is used with XSalsa20-Poly1305 (libsodium secretbox) to encrypt
// journal entries BEFORE they leave the device.
//
// From this point on, the server only ever sees ciphertext.
//
// Why libsodium?
//   - Well-audited, high-level API that is hard to misuse.
//   - Nonces are generated internally, eliminating the most common mistake.
//   - Used by Signal, Keybase, and many production E2EE systems.

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _kDerivedKey = 'e2ee_derived_key';

class CryptoService extends ChangeNotifier {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  static SodiumSumo? _sodiumInstance;
  static Future<SodiumSumo> _getSodium() async {
    return _sodiumInstance ??= await SodiumSumoInit.init();
  }

  Uint8List? _derivedKey;

  static String _toBase64(Uint8List bytes) => base64.encode(bytes);
  static Uint8List _fromBase64(String s) => base64.decode(s);

  Future<T> _withSecureKey<T>(
      Uint8List raw, Future<T> Function(SecureKey) fn) async {
    final sodium = await _getSodium();
    final sk = SecureKey.fromList(sodium, raw);
    try {
      return await fn(sk);
    } finally {
      sk.dispose();
    }
  }

  // Derive a 32-byte symmetric key from the user's password.
  //
  // In production use a per-user random salt stored server-side.
  // Here we derive the salt from the username so we can reproduce the key
  // across devices without a round-trip during the KDF step.
  Future<Uint8List> deriveKeyFromPassword(
      String password, String username) async {
    final sodium = await _getSodium();

    final saltSource = utf8.encode(username.padRight(16, '\x00'));
    final salt = Uint8List.fromList(saltSource.take(16).toList());

    final secureKey = sodium.crypto.pwhash(
      outLen: sodium.crypto.secretBox.keyBytes,
      password: Int8List.fromList(utf8.encode(password)),
      salt: salt,
      opsLimit: sodium.crypto.pwhash.opsLimitInteractive,
      memLimit: sodium.crypto.pwhash.memLimitInteractive,
      alg: CryptoPwhashAlgorithm.argon2id13,
    );

    final key = secureKey.extractBytes();
    secureKey.dispose();

    _derivedKey = key;
    await _secureStorage.write(key: _kDerivedKey, value: _toBase64(key));
    notifyListeners();
    return key;
  }

  // Encrypt arbitrary plaintext with the Argon2-derived key.
  // Returns base64(nonce || ciphertext).
  Future<String> symmetricEncrypt(String plaintext) async {
    assert(_derivedKey != null, 'Call deriveKeyFromPassword first');
    final sodium = await _getSodium();
    final nonce = sodium.randombytes.buf(sodium.crypto.secretBox.nonceBytes);
    final ct = await _withSecureKey(_derivedKey!, (key) async {
      return sodium.crypto.secretBox.easy(
        message: Uint8List.fromList(utf8.encode(plaintext)),
        nonce: nonce,
        key: key,
      );
    });
    final combined = Uint8List(nonce.length + ct.length)
      ..setAll(0, nonce)
      ..setAll(nonce.length, ct);
    return _toBase64(combined);
  }

  // Decrypt a blob produced by symmetricEncrypt.
  Future<String> symmetricDecrypt(String blob) async {
    assert(_derivedKey != null, 'Call deriveKeyFromPassword first');
    final sodium = await _getSodium();
    final combined = _fromBase64(blob);
    final nonceLen = sodium.crypto.secretBox.nonceBytes;
    final nonce = combined.sublist(0, nonceLen);
    final ct = combined.sublist(nonceLen);
    final pt = await _withSecureKey(_derivedKey!, (key) async {
      return sodium.crypto.secretBox.openEasy(
        cipherText: ct,
        nonce: nonce,
        key: key,
      );
    });
    return utf8.decode(pt);
  }

  Future<void> clearKeys() async {
    _derivedKey = null;
    await _secureStorage.deleteAll();
    notifyListeners();
  }

  Future<bool> tryRestoreSession() async {
    final derivedKeyB64 = await _secureStorage.read(key: _kDerivedKey);
    if (derivedKeyB64 == null) return false;
    _derivedKey = _fromBase64(derivedKeyB64);
    notifyListeners();
    return true;
  }
}
