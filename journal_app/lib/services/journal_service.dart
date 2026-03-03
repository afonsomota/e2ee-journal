// services/journal_service.dart
//
// Orchestrates journal CRUD.  This is where the encryption steps are most
// visible: the same "create entry" action changes significantly between steps.
//
// API contract:
//   Step 1  POST /entries { content: "plaintext" }
//   Step 3  POST /entries { encrypted_blob: "..." }
//   Step 5  POST /entries { encrypted_blob: "...", encrypted_content_key: "..." }

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../models/journal_entry.dart';
import 'auth_service.dart';
import 'crypto_service.dart';

class JournalService extends ChangeNotifier {
  AuthService? _auth;
  CryptoService? _crypto;

  List<JournalEntry> _entries = [];
  bool _loading = false;
  String? _error;

  List<JournalEntry> get entries => _entries;
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

  // ── Step 1: Create entry (plaintext) — preserved for reference ─────────────

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

  // ── Step 3: Create entry (symmetric) — preserved for reference ─────────────

  Future<void> createEntryStep3(String content) async {
    assert(_crypto != null);
    _setLoading(true);
    try {
      final encryptedBlob = await _crypto!.symmetricEncrypt(content);

      final resp = await _dio.post('/entries', data: {
        'encrypted_blob': encryptedBlob,
      });

      final entry = JournalEntry.fromJson(resp.data).copyWith(content: content);
      _entries.insert(0, entry);
      notifyListeners();
    } on DioException catch (e) {
      _error = _extractError(e, 'Failed to create entry');
    } finally {
      _setLoading(false);
    }
  }

  // ── Step 5: Create entry (hybrid encryption) ──────────────────────────────
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
        throw Exception('Public key not set — are you on Step 5+?');
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

  // ── Fetch & decrypt entries ────────────────────────────────────────────────

  Future<void> fetchAll() async {
    _setLoading(true);
    try {
      final resp = await _dio.get('/entries');
      final raw = (resp.data as List)
          .map((j) => JournalEntry.fromJson(j as Map<String, dynamic>))
          .toList();
      _entries = await _decryptEntries(raw);
      notifyListeners();
    } on DioException catch (e) {
      _error = _extractError(e, 'Failed to fetch entries');
    } finally {
      _setLoading(false);
    }
  }

  Future<List<JournalEntry>> _decryptEntries(List<JournalEntry> raw) async {
    if (_crypto == null) return raw;
    final decrypted = <JournalEntry>[];
    for (final entry in raw) {
      try {
        decrypted.add(await _decryptEntry(entry));
      } catch (e) {
        decrypted.add(entry.copyWith(content: '[Decryption failed]'));
      }
    }
    return decrypted;
  }

  Future<JournalEntry> _decryptEntry(JournalEntry entry) async {
    final blob = entry.encryptedBlob;
    if (blob == null) return entry; // Step 1: plaintext.

    if (entry.encryptedContentKey != null && _crypto!.hasKeys) {
      // Step 5: hybrid — decrypt content key first, then body.
      final contentKey =
          await _crypto!.decryptContentKey(entry.encryptedContentKey!);
      final content = await _crypto!.decryptWithContentKey(blob, contentKey);
      return entry.copyWith(content: content);
    } else if (!_crypto!.hasKeys) {
      // Step 3: symmetric-only path (no keypair yet).
      final content = await _crypto!.symmetricDecrypt(blob);
      return entry.copyWith(content: content);
    }

    return entry.copyWith(content: '[Key unavailable]');
  }

  // ── Update & delete ───────────────────────────────────────────────────────

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

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _setLoading(bool v) {
    _loading = v;
    notifyListeners();
  }

  String _extractError(DioException e, String fallback) {
    return (e.response?.data as Map<String, dynamic>?)?['detail'] as String? ??
        fallback;
  }
}
