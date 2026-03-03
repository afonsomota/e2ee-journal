// services/journal_service.dart
//
// Orchestrates journal CRUD and sharing.  This is where the encryption steps
// are most visible: the same "create entry" action changes significantly
// between steps.  Each method is tagged clearly.
//
// API contract (what the server sees at each step):
//
//  Step 1  POST /entries { content: "plaintext" }
//  Step 2  POST /entries { content: "plaintext" }  — server encrypts at rest
//  Step 3  POST /entries { encrypted_blob: "..." }
//  Step 5  POST /entries { encrypted_blob: "...", encrypted_content_key: "..." }
//  Step 6  POST /entries/:id/share { recipient_username: "...",
//                                     encrypted_content_key: "..." }

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../models/journal_entry.dart';
import 'auth_service.dart';
import 'crypto_service.dart';

class JournalService extends ChangeNotifier {
  AuthService? _auth;
  CryptoService? _crypto;

  List<JournalEntry> _entries = [];
  List<JournalEntry> _sharedWithMe = [];
  bool _loading = false;
  String? _error;

  List<JournalEntry> get entries => _entries;
  List<JournalEntry> get sharedWithMe => _sharedWithMe;
  bool get loading => _loading;
  String? get error => _error;


  Dio get _dio {
    final d = Dio(BaseOptions(
      baseUrl: 'http://localhost:8000',
      connectTimeout: const Duration(seconds: 10),
    ));
    d.interceptors.add(InterceptorsWrapper(onRequest: (opts, handler) {
      if (_auth?.token != null) {
        opts.headers['Authorization'] = 'Bearer ${_auth!.token}';
      }
      handler.next(opts);
    }));
    return d;
  }

  void update(AuthService auth, CryptoService crypto) {
    _auth = auth;
    _crypto = crypto;
    if (auth.isLoggedIn) fetchAll();
  }

  // ── Step 1: Create entry (plaintext) ───────────────────────────────────────

  Future<void> createEntryStep1(String content) async {
    _setLoading(true);
    try {
      final resp = await _dio.post('/entries', data: {'content': content});
      final entry = JournalEntry.fromJson(resp.data);
      _entries.insert(0, entry);
      notifyListeners();
    } on DioException catch (e) {
      _error = _extractError(e, 'Failed to create entry');
    } finally {
      _setLoading(false);
    }
  }

  // ── Step 3: Create entry (client-side symmetric encryption) ───────────────
  //
  // BLOG NOTE: The server receives an encrypted_blob and no content field.
  // A database dump from this point onward reveals only ciphertext.
  // The server admin cannot distinguish a love letter from a grocery list.

  Future<void> createEntryStep3(String content) async {
    assert(_crypto != null);
    _setLoading(true);
    try {
      // Encrypt locally before the HTTP call is even constructed.
      final encryptedBlob = await _crypto!.symmetricEncrypt(content);

      final resp = await _dio.post('/entries', data: {
        'encrypted_blob': encryptedBlob,
        // content is intentionally absent
      });
      // Store with decrypted content locally for display (we already know it).
      final entry = JournalEntry.fromJson(resp.data).copyWith(content: content);
      _entries.insert(0, entry);
      notifyListeners();
    } on DioException catch (e) {
      _error = _extractError(e, 'Failed to create entry');
    } finally {
      _setLoading(false);
    }
  }

  // ── Step 5: Create entry (hybrid encryption) ───────────────────────────────
  //
  // Flow:
  //   1. Generate a random content key (32 bytes).
  //   2. Encrypt the entry body with the content key (secretbox).
  //   3. Encrypt the content key with our own public key (seal box).
  //   4. Upload both blobs.  The server has no key to either.
  //
  // BLOG NOTE: This is the pattern used by iMessage.  The message is encrypted
  // once with a symmetric key; that key is then wrapped for each device the
  // recipient owns.  Adding a new recipient (Step 6) only requires wrapping
  // the key again — the ciphertext body is never re-encrypted.

  Future<void> createEntry(String content) async {
    assert(_crypto != null && _auth?.currentUser != null);
    _setLoading(true);
    try {
      // [Step5-1] Fresh random key for this entry only.
      final contentKey = await _crypto!.generateContentKey();

      // [Step5-2] Encrypt body.
      final encryptedBlob =
          await _crypto!.encryptWithContentKey(content, contentKey);

      // [Step5-3] Encrypt content key for ourselves (so we can read it back).
      final myPublicKey = _auth!.currentUser!.publicKey;
      if (myPublicKey == null) {
        throw Exception('Public key not set — are you on Step 5+?');
      }
      final encryptedContentKey =
          await _crypto!.encryptContentKeyForRecipient(contentKey, myPublicKey);

      // [Step5-4] Upload.  Server stores two opaque blobs.
      final resp = await _dio.post('/entries', data: {
        'encrypted_blob': encryptedBlob,
        'encrypted_content_key': encryptedContentKey,
      });

      final entry =
          JournalEntry.fromJson(resp.data).copyWith(content: content);
      _entries.insert(0, entry);
      notifyListeners();
    } on DioException catch (e) {
      _error = _extractError(e, 'Failed to create entry');
    } finally {
      _setLoading(false);
    }
  }

  // ── Fetch & decrypt entries ─────────────────────────────────────────────────

  Future<void> fetchAll() async {
    _setLoading(true);
    try {
      // My entries
      final myResp = await _dio.get('/entries');
      final myRaw = (myResp.data as List)
          .map((j) => JournalEntry.fromJson(j as Map<String, dynamic>))
          .toList();
      _entries = await _decryptEntries(myRaw, shared: false);

      // Entries shared with me [Step6]
      final sharedResp = await _dio.get('/entries/shared-with-me');
      final sharedRaw = (sharedResp.data as List)
          .map((j) => JournalEntry.fromJson(j as Map<String, dynamic>))
          .toList();
      _sharedWithMe = await _decryptEntries(sharedRaw, shared: true);

      notifyListeners();
    } on DioException catch (e) {
      _error = _extractError(e, 'Failed to fetch entries');
    } finally {
      _setLoading(false);
    }
  }

  // Decrypt a list of entries, handling all steps gracefully.
  Future<List<JournalEntry>> _decryptEntries(
    List<JournalEntry> raw, {
    required bool shared,
  }) async {
    if (_crypto == null) return raw;

    final decrypted = <JournalEntry>[];
    for (final entry in raw) {
      try {
        decrypted.add(await _decryptEntry(entry, shared: shared));
      } catch (e) {
        // Decryption failed — include entry with error content so UI doesn't
        // silently drop it.
        decrypted.add(entry.copyWith(content: '[Decryption failed]'));
      }
    }
    return decrypted;
  }

  Future<JournalEntry> _decryptEntry(
    JournalEntry entry, {
    required bool shared,
  }) async {
    final blob = entry.encryptedBlob;
    if (blob == null) return entry; // Step 1/2: plaintext, nothing to do.

    final eckForMe = shared
        ? entry.sharedEncryptedContentKey // [Step6] key encrypted for me
        : entry.encryptedContentKey;      // [Step5] key encrypted for author

    if (eckForMe != null && _crypto!.hasKeys) {
      // Step 5+: hybrid — decrypt content key first, then body.
      final contentKey = await _crypto!.decryptContentKey(eckForMe);
      final content = await _crypto!.decryptWithContentKey(blob, contentKey);
      return entry.copyWith(content: content);
    } else if (!_crypto!.hasKeys) {
      // Step 3: symmetric-only path (no keypair yet).
      final content = await _crypto!.symmetricDecrypt(blob);
      return entry.copyWith(content: content);
    }

    return entry.copyWith(content: '[Key unavailable]');
  }

  // ── Step 6: Share an entry ─────────────────────────────────────────────────
  //
  // BLOG NOTE: Watch what is NOT happening here.  We are not touching the
  // encrypted body at all.  The only thing that changes is a new key blob is
  // created and stored server-side.  This is computationally cheap regardless
  // of entry size — sharing a 100MB file requires the same work as sharing
  // a 10-byte note.
  //
  // Revoking access is equally elegant: the server deletes the key blob for
  // that user.  They can no longer decrypt new downloads.  (Content already
  // cached on their device is a separate problem — see the blog discussion on
  // revocation.)

  Future<void> shareEntry(String entryId, String recipientUsername) async {
    assert(_crypto != null);
    _setLoading(true);
    try {
      // 1. Fetch the recipient's public key from the server.
      //
      //    BLOG NOTE (Trust): At this point we are trusting the server to give
      //    us the correct public key.  A malicious server could substitute its
      //    own key (MITM).  Mitigations: key transparency logs, out-of-band
      //    fingerprint verification (like Signal's safety numbers).  We cover
      //    this in Step 8.
      final recipientResp =
          await _dio.get('/users/$recipientUsername/public-key');
      final recipientPublicKey =
          recipientResp.data['public_key'] as String;

      // 2. Find the entry and get its encrypted content key (for us as author).
      final entry = _entries.firstWhere((e) => e.id == entryId);
      final myEncryptedContentKey = entry.encryptedContentKey;
      if (myEncryptedContentKey == null) {
        throw Exception('Entry has no encrypted content key (pre-Step 5?)');
      }

      // 3. Decrypt with our private key, re-encrypt for recipient.
      final recipientEncryptedContentKey =
          await _crypto!.reEncryptContentKeyForRecipient(
        myEncryptedContentKey,
        recipientPublicKey,
      );

      // 4. Upload only the new key blob.  The encrypted body is untouched.
      await _dio.post('/entries/$entryId/share', data: {
        'recipient_username': recipientUsername,
        'encrypted_content_key': recipientEncryptedContentKey,
      });

      // Update local state.
      final idx = _entries.indexWhere((e) => e.id == entryId);
      if (idx != -1) {
        _entries[idx] = _entries[idx].copyWith(
          sharedWith: [..._entries[idx].sharedWith, recipientUsername],
        );
      }
      notifyListeners();
    } on DioException catch (e) {
      _error = _extractError(e, 'Failed to share entry');
    } finally {
      _setLoading(false);
    }
  }

  // ── Update & delete ────────────────────────────────────────────────────────

  Future<void> updateEntry(String entryId, String newContent) async {
    assert(_crypto != null);
    _setLoading(true);
    try {
      final entry = _entries.firstWhere((e) => e.id == entryId);
      Map<String, dynamic> payload;

      if (entry.encryptedContentKey != null && _crypto!.hasKeys) {
        // Step 5+: decrypt existing content key and re-encrypt new content.
        final contentKey =
            await _crypto!.decryptContentKey(entry.encryptedContentKey!);
        final newBlob =
            await _crypto!.encryptWithContentKey(newContent, contentKey);
        payload = {'encrypted_blob': newBlob};
      } else if (entry.encryptedBlob != null) {
        // Step 3: symmetric encryption.
        final newBlob = await _crypto!.symmetricEncrypt(newContent);
        payload = {'encrypted_blob': newBlob};
      } else {
        payload = {'content': newContent};
      }

      await _dio.put('/entries/$entryId', data: payload);

      final idx = _entries.indexWhere((e) => e.id == entryId);
      if (idx != -1) {
        _entries[idx] = _entries[idx].copyWith(content: newContent);
        notifyListeners();
      }
    } on DioException catch (e) {
      _error = _extractError(e, 'Failed to update entry');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> deleteEntry(String entryId) async {
    _setLoading(true);
    try {
      await _dio.delete('/entries/$entryId');
      _entries.removeWhere((e) => e.id == entryId);
      notifyListeners();
    } on DioException catch (e) {
      _error = _extractError(e, 'Failed to delete entry');
    } finally {
      _setLoading(false);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _setLoading(bool v) {
    _loading = v;
    notifyListeners();
  }

  String _extractError(DioException e, String fallback) {
    return (e.response?.data as Map<String, dynamic>?)?['detail'] as String? ??
        fallback;
  }
}
