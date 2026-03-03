// services/crypto_service.dart
//
// THE CRYPTOGRAPHIC CORE
//
// This service evolves through the blog steps:
//   [Step 3] Argon2id KDF + XSalsa20-Poly1305 secretbox (symmetric)
//   [Step 4] X25519 keypair generation; private key encrypted before upload
//   [Step 5] Per-entry content keys + sealed box (hybrid encryption)
//
// Primitives used (all via sodium_libs / libsodium):
//   KDF       Argon2id          — password → 32-byte symmetric key
//   SecretBox XSalsa20-Poly1305 — symmetric authenticated encryption
//   SealBox   X25519 + XSalsa20 — anonymous asymmetric encryption

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _kPrivateKey = 'e2ee_private_key';
const _kPublicKey = 'e2ee_public_key';
const _kDerivedKey = 'e2ee_derived_key';

class CryptoService extends ChangeNotifier {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  static SodiumSumo? _sodiumInstance;
  static Future<SodiumSumo> _getSodium() async {
    return _sodiumInstance ??= await SodiumSumoInit.init();
  }

  Uint8List? _derivedKey;   // [Step3]
  Uint8List? _privateKey;   // [Step4]
  Uint8List? _publicKey;    // [Step4]

  bool get hasKeys => _privateKey != null && _publicKey != null;

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

  // ── Step 3 ─────────────────────────────────────────────────────────────────

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

  // ── Step 4 ─────────────────────────────────────────────────────────────────

  Future<({String publicKey, String encryptedPrivateKey})>
      generateAndStoreKeypair() async {
    assert(_derivedKey != null, 'Derive key from password first');
    final sodium = await _getSodium();

    final keypair = sodium.crypto.box.keyPair();
    _privateKey = keypair.secretKey.extractBytes();
    _publicKey = keypair.publicKey;
    keypair.secretKey.dispose();

    await _secureStorage.write(key: _kPublicKey, value: _toBase64(_publicKey!));

    final encPrivKey = await _encryptBytes(_privateKey!, _derivedKey!);
    await _secureStorage.write(key: _kPrivateKey, value: encPrivKey);

    notifyListeners();
    return (
      publicKey: _toBase64(_publicKey!),
      encryptedPrivateKey: encPrivKey,
    );
  }

  Future<void> unlockPrivateKey(String encryptedPrivateKeyB64) async {
    assert(_derivedKey != null, 'Derive key from password first');
    _privateKey = await _decryptBytes(encryptedPrivateKeyB64, _derivedKey!);
    await _secureStorage.write(
        key: _kPrivateKey, value: encryptedPrivateKeyB64);
    notifyListeners();
  }

  Future<void> loadPublicKey(String publicKeyB64) async {
    _publicKey = _fromBase64(publicKeyB64);
    await _secureStorage.write(key: _kPublicKey, value: publicKeyB64);
    notifyListeners();
  }

  // ── Step 5 ─────────────────────────────────────────────────────────────────
  // Per-entry content key: a random 32-byte key encrypts the body (secretbox),
  // then the content key itself is encrypted with the author's public key
  // (seal box).  This is the hybrid pattern used by iMessage, PGP, and TLS.

  Future<Uint8List> generateContentKey() async {
    final sodium = await _getSodium();
    return sodium.randombytes.buf(sodium.crypto.secretBox.keyBytes);
  }

  Future<String> encryptWithContentKey(
      String plaintext, Uint8List contentKey) async {
    final sodium = await _getSodium();
    final nonce = sodium.randombytes.buf(sodium.crypto.secretBox.nonceBytes);
    final ct = await _withSecureKey(contentKey, (key) async {
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

  Future<String> decryptWithContentKey(
      String blob, Uint8List contentKey) async {
    final sodium = await _getSodium();
    final combined = _fromBase64(blob);
    final nonceLen = sodium.crypto.secretBox.nonceBytes;
    final nonce = combined.sublist(0, nonceLen);
    final ct = combined.sublist(nonceLen);
    final pt = await _withSecureKey(contentKey, (key) async {
      return sodium.crypto.secretBox.openEasy(
        cipherText: ct,
        nonce: nonce,
        key: key,
      );
    });
    return utf8.decode(pt);
  }

  // crypto_box_seal: anonymous asymmetric encryption (no sender identity).
  Future<String> encryptContentKeyForRecipient(
      Uint8List contentKey, String recipientPublicKeyB64) async {
    final sodium = await _getSodium();
    final recipientPk = _fromBase64(recipientPublicKeyB64);
    final sealed = sodium.crypto.box.seal(
      message: contentKey,
      publicKey: recipientPk,
    );
    return _toBase64(sealed);
  }

  Future<Uint8List> decryptContentKey(String encryptedContentKeyB64) async {
    assert(_privateKey != null && _publicKey != null, 'Keys not loaded');
    final sodium = await _getSodium();
    final sealed = _fromBase64(encryptedContentKeyB64);
    return _withSecureKey(_privateKey!, (sk) async {
      return sodium.crypto.box.sealOpen(
        cipherText: sealed,
        publicKey: _publicKey!,
        secretKey: sk,
      );
    });
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  Future<String> _encryptBytes(Uint8List data, Uint8List key) async {
    final sodium = await _getSodium();
    final nonce = sodium.randombytes.buf(sodium.crypto.secretBox.nonceBytes);
    final ct = await _withSecureKey(key, (sk) async {
      return sodium.crypto.secretBox.easy(message: data, nonce: nonce, key: sk);
    });
    final combined = Uint8List(nonce.length + ct.length)
      ..setAll(0, nonce)
      ..setAll(nonce.length, ct);
    return _toBase64(combined);
  }

  Future<Uint8List> _decryptBytes(String blob, Uint8List key) async {
    final sodium = await _getSodium();
    final combined = _fromBase64(blob);
    final nonceLen = sodium.crypto.secretBox.nonceBytes;
    final nonce = combined.sublist(0, nonceLen);
    final ct = combined.sublist(nonceLen);
    return _withSecureKey(key, (sk) async {
      return sodium.crypto.secretBox.openEasy(
        cipherText: ct,
        nonce: nonce,
        key: sk,
      );
    });
  }

  // ── Session management ────────────────────────────────────────────────────

  Future<void> clearKeys() async {
    _derivedKey = null;
    _privateKey = null;
    _publicKey = null;
    await _secureStorage.deleteAll();
    notifyListeners();
  }

  Future<bool> tryRestoreSession() async {
    final derivedKeyB64 = await _secureStorage.read(key: _kDerivedKey);
    final publicKeyB64 = await _secureStorage.read(key: _kPublicKey);
    final privateKeyBlob = await _secureStorage.read(key: _kPrivateKey);

    if (derivedKeyB64 == null) return false;

    _derivedKey = _fromBase64(derivedKeyB64);

    if (publicKeyB64 != null) _publicKey = _fromBase64(publicKeyB64);

    if (privateKeyBlob != null && _derivedKey != null) {
      try {
        _privateKey = await _decryptBytes(privateKeyBlob, _derivedKey!);
      } catch (_) {
        return false;
      }
    }

    notifyListeners();
    return _privateKey != null;
  }
}
