// services/journal_service.dart
//
// Orchestrates journal CRUD and sharing.

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../config.dart';
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
      baseUrl: apiBaseUrl,
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

  // ── Create entry (hybrid encryption) ─────────────────────────────────────
  //
  // Flow:
  //   1. Generate a random content key (32 bytes).
  //   2. Encrypt the entry body with the content key (secretbox).
  //   3. Encrypt the content key with our own public key (seal box).
  //   4. Upload both blobs.  The server has no key to either.

  Future<void> createEntry(String content) async {
    assert(_crypto != null && _auth?.currentUser != null);
    _setLoading(true);
    try {
      final contentKey = await _crypto!.generateContentKey();

      final encryptedBlob =
          await _crypto!.encryptWithContentKey(content, contentKey);

      final myPublicKey = _auth!.currentUser!.publicKey;
      if (myPublicKey == null) {
        throw Exception('Public key not set');
      }
      final encryptedContentKey =
          await _crypto!.encryptContentKeyForRecipient(contentKey, myPublicKey);

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

  // ── Create entry (plaintext) ──────────────────────────────────────────────

  Future<void> createEntryPlaintext(String content) async {
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

  // ── Fetch & decrypt entries ───────────────────────────────────────────────

  Future<void> fetchAll() async {
    _setLoading(true);
    try {
      // My entries
      final myResp = await _dio.get('/entries');
      final myRaw = (myResp.data as List)
          .map((j) => JournalEntry.fromJson(j as Map<String, dynamic>))
          .toList();
      _entries = await _decryptEntries(myRaw, shared: false);

      // Entries shared with me
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
    if (blob == null) return entry;

    final eckForMe = shared
        ? entry.sharedEncryptedContentKey
        : entry.encryptedContentKey;

    if (eckForMe != null && _crypto!.hasKeys) {
      final contentKey = await _crypto!.decryptContentKey(eckForMe);
      final content = await _crypto!.decryptWithContentKey(blob, contentKey);
      return entry.copyWith(content: content);
    }

    return entry.copyWith(content: '[Key unavailable]');
  }

  // ── Share an entry ────────────────────────────────────────────────────────

  Future<void> shareEntry(String entryId, String recipientUsername) async {
    _setLoading(true);
    try {
      final entry = _entries.firstWhere((e) => e.id == entryId);
      final myEncryptedContentKey = entry.encryptedContentKey;

      String? recipientEncryptedContentKey;
      if (myEncryptedContentKey != null && _crypto != null) {
        // Encrypted entry: re-encrypt the content key for the recipient.
        final recipientResp =
            await _dio.get('/users/$recipientUsername/public-key');
        final recipientPublicKey =
            recipientResp.data['public_key'] as String;

        recipientEncryptedContentKey =
            await _crypto!.reEncryptContentKeyForRecipient(
          myEncryptedContentKey,
          recipientPublicKey,
        );
      }
      // Plaintext entry: no key to re-encrypt, just grant access.

      await _dio.post('/entries/$entryId/share', data: {
        'recipient_username': recipientUsername,
        'encrypted_content_key': ?recipientEncryptedContentKey,
      });

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

  // ── Update & delete ──────────────────────────────────────────────────────

  Future<void> updateEntry(String entryId, String newContent) async {
    assert(_crypto != null);
    _setLoading(true);
    try {
      final entry = _entries.firstWhere((e) => e.id == entryId);
      Map<String, dynamic> payload;

      if (entry.encryptedContentKey != null && _crypto!.hasKeys) {
        final contentKey =
            await _crypto!.decryptContentKey(entry.encryptedContentKey!);
        final newBlob =
            await _crypto!.encryptWithContentKey(newContent, contentKey);
        payload = {'encrypted_blob': newBlob};
      } else if (entry.encryptedBlob != null) {
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

  // ── Helpers ──────────────────────────────────────────────────────────────

  void _setLoading(bool v) {
    _loading = v;
    notifyListeners();
  }

  String _extractError(DioException e, String fallback) {
    return (e.response?.data as Map<String, dynamic>?)?['detail'] as String? ??
        fallback;
  }
}
