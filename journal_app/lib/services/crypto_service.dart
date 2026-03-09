// services/crypto_service.dart
//
// ─────────────────────────────────────────────────────────────────────────────
// THE CRYPTOGRAPHIC CORE
//
// This service evolves through the blog steps.  Each method is tagged with the
// step that introduces it.  Prior-step methods are never removed so readers can
// follow the full progression.
//
// Primitives used (all via sodium_libs / libsodium):
//
//   KDF       Argon2id          — password → 32-byte symmetric key
//   SecretBox XSalsa20-Poly1305 — symmetric authenticated encryption
//   Box       X25519 + XSalsa20 — asymmetric authenticated encryption
//   SealBox   X25519 + XSalsa20 — anonymous asymmetric encryption (no sender)
//
// Why libsodium?
//   • Well-audited, high-level API that is hard to misuse.
//   • Nonces are generated internally, eliminating the most common mistake.
//   • Used by Signal, Keybase, and many production E2EE systems.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Storage keys
const _kPrivateKey = 'e2ee_private_key';
const _kPublicKey = 'e2ee_public_key';
const _kDerivedKey = 'e2ee_derived_key';

class CryptoService extends ChangeNotifier {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  // Lazily-initialized libsodium (sumo build for pwhash support).
  static SodiumSumo? _sodiumInstance;
  static Future<SodiumSumo> _getSodium() async {
    return _sodiumInstance ??= await SodiumSumoInit.init();
  }

  // In-memory key material (cleared on logout).
  // These are raw bytes, never serialised to disk in plaintext.
  Uint8List? _derivedKey;   // [Step3] 32-byte Argon2 output
  Uint8List? _privateKey;   // [Step4] X25519 private key (decrypted)
  Uint8List? _publicKey;    // [Step4] X25519 public key

  bool get hasKeys => _privateKey != null && _publicKey != null;

  // ── Helpers ────────────────────────────────────────────────────────────────

  static String _toBase64(Uint8List bytes) => base64.encode(bytes);
  static Uint8List _fromBase64(String s) => base64.decode(s);

  // Wrap raw bytes in a SecureKey for use with sodium APIs, run [fn], then
  // dispose the wrapper.  The caller's Uint8List is NOT zeroed.
  Future<T> _withSecureKey<T>(Uint8List raw, Future<T> Function(SecureKey) fn) async {
    final sodium = await _getSodium();
    final sk = SecureKey.fromList(sodium, raw);
    try {
      return await fn(sk);
    } finally {
      sk.dispose();
    }
  }

  // ── Step 3 ─────────────────────────────────────────────────────────────────
  // Derive a 32-byte symmetric key from the user's password + a fixed salt.
  //
  // In production use a per-user random salt stored server-side.
  // Here we derive the salt from the username so we can reproduce the key
  // across devices without a round-trip during the KDF step.  This is a
  // simplification.
  //
  // Argon2id parameters: these are the libsodium "interactive" presets.
  // They are deliberately expensive to defeat brute-force offline attacks.
  Future<Uint8List> deriveKeyFromPassword(
      String password, String username) async {
    final sodium = await _getSodium();

    // Deterministic salt from username — 16 bytes, zero-padded.
    // Production: store a random salt per user on the server.
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
    // Persist in secure storage so the app can unlock without re-hashing.
    await _secureStorage.write(key: _kDerivedKey, value: _toBase64(key));
    notifyListeners();
    return key;
  }

  // [Step3] Encrypt arbitrary plaintext with the Argon2-derived key.
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
    // Prepend nonce so we can decrypt later without storing it separately.
    final combined = Uint8List(nonce.length + ct.length)
      ..setAll(0, nonce)
      ..setAll(nonce.length, ct);
    return _toBase64(combined);
  }

  // [Step3] Decrypt a blob produced by symmetricEncrypt.
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
  // Generate an X25519 keypair.  The private key is immediately encrypted with
  // the derived key and the ciphertext is what gets uploaded to the server.
  // The plaintext private key is kept only in memory (_privateKey).
  //
  // BLOG NOTE: This mirrors what ProtonMail does at account creation.
  Future<({String publicKey, String encryptedPrivateKey})>
      generateAndStoreKeypair() async {
    assert(_derivedKey != null, 'Derive key from password first');
    final sodium = await _getSodium();

    final keypair = sodium.crypto.box.keyPair();
    _privateKey = keypair.secretKey.extractBytes();
    _publicKey = keypair.publicKey;
    keypair.secretKey.dispose();

    // Persist public key in secure storage (non-sensitive, but convenient).
    await _secureStorage.write(key: _kPublicKey, value: _toBase64(_publicKey!));

    // Encrypt private key with the Argon2-derived key before upload.
    final encPrivKey = await _encryptBytes(_privateKey!, _derivedKey!);
    // Do NOT persist plaintext private key.  Only the encrypted form goes to
    // the server and optionally local secure storage.
    await _secureStorage.write(key: _kPrivateKey, value: encPrivKey);

    notifyListeners();
    return (
      publicKey: _toBase64(_publicKey!),
      encryptedPrivateKey: encPrivKey,
    );
  }

  // [Step4] Load and decrypt the private key from server-provided ciphertext.
  // Called on login: server returns the stored encryptedPrivateKey blob.
  Future<void> unlockPrivateKey(String encryptedPrivateKeyB64) async {
    assert(_derivedKey != null, 'Derive key from password first');
    _privateKey = await _decryptBytes(encryptedPrivateKeyB64, _derivedKey!);
    await _secureStorage.write(
        key: _kPrivateKey, value: encryptedPrivateKeyB64);
    notifyListeners();
  }

  // [Step4] Load public key (from server or local cache).
  Future<void> loadPublicKey(String publicKeyB64) async {
    _publicKey = _fromBase64(publicKeyB64);
    await _secureStorage.write(key: _kPublicKey, value: publicKeyB64);
    notifyListeners();
  }

  // ── Step 5 ─────────────────────────────────────────────────────────────────
  // Generate a random 32-byte content key (one per journal entry).
  // This is the symmetric key that actually encrypts the entry body.
  //
  // BLOG NOTE: We use a fresh random key per entry — not the derived key.
  // This is important: if we always used the derived key, sharing would require
  // giving the recipient the master key.  Per-entry keys mean sharing is
  // surgical: you only share the key for one entry.
  Future<Uint8List> generateContentKey() async {
    final sodium = await _getSodium();
    return sodium.randombytes.buf(sodium.crypto.secretBox.keyBytes);
  }

  // [Step5] Encrypt entry body with a content key.
  // Returns base64(nonce || ciphertext).
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

  // [Step5] Decrypt entry body with a content key.
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

  // [Step5] Encrypt a content key with a recipient's public key (seal box).
  // crypto_box_seal is anonymous — it does not authenticate the sender, which
  // is what we want: the server can store it without learning who encrypted it.
  // Returns base64(sealed content key).
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

  // [Step5] Decrypt an encrypted content key using our private key.
  // Requires both the private key (to decrypt) and public key (for the box).
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

  // ── Step 6 ─────────────────────────────────────────────────────────────────
  // Sharing an entry = encrypt the content key for the recipient's public key.
  // The entry body (encryptedBlob) never changes.  Only a new encrypted key
  // blob is created and sent to the server.
  //
  // BLOG NOTE: This is exactly how iMessage handles group messages and how
  // Tresorit handles shared folders.  The data is encrypted once; access
  // control is managed entirely through key distribution.
  Future<String> encryptContentKeyForSharing(
    Uint8List contentKey,
    String recipientPublicKeyB64,
  ) async {
    // Identical to encryptContentKeyForRecipient — extracted for blog clarity.
    return encryptContentKeyForRecipient(contentKey, recipientPublicKeyB64);
  }

  // [Step6] Full share flow: given an encrypted content key (for the author),
  // decrypt it, then re-encrypt for the recipient.
  Future<String> reEncryptContentKeyForRecipient(
    String myEncryptedContentKeyB64,
    String recipientPublicKeyB64,
  ) async {
    // 1. Decrypt with our private key.
    final contentKey = await decryptContentKey(myEncryptedContentKeyB64);
    // 2. Re-encrypt for the recipient.
    return encryptContentKeyForSharing(contentKey, recipientPublicKeyB64);
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  // Encrypt raw bytes with a 32-byte symmetric key (secretbox).
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

  // ── Session management ─────────────────────────────────────────────────────

  Future<void> clearKeys() async {
    _derivedKey = null;
    _privateKey = null;
    _publicKey = null;
    await _secureStorage.deleteAll();
    notifyListeners();
  }

  // Attempt to restore session from secure storage (avoids re-hashing on app
  // restart if the OS keeps the secure storage intact).
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
        // Corrupted storage — require full re-login.
        return false;
      }
    }

    notifyListeners();
    return _privateKey != null;
  }
}
