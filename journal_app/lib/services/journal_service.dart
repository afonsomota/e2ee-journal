// services/journal_service.dart
//
// Orchestrates journal CRUD.  From Step 3 onward, all content is encrypted
// on the client before being sent to the server.
//
// API contract:
//   Step 1  POST /entries { content: "plaintext" }
//   Step 3  POST /entries { encrypted_blob: "..." }

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

  // ── Step 3: Create entry (client-side symmetric encryption) ────────────────
  //
  // The server receives an encrypted_blob and no content field.
  // A database dump from this point onward reveals only ciphertext.

  Future<void> createEntry(String content) async {
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
    if (blob == null) return entry; // Step 1: plaintext, nothing to do.

    final content = await _crypto!.symmetricDecrypt(blob);
    return entry.copyWith(content: content);
  }

  // ── Update & delete ───────────────────────────────────────────────────────

  Future<void> updateEntry(String entryId, String newContent) async {
    _setLoading(true);
    try {
      final entry = _entries.firstWhere((e) => e.id == entryId);
      Map<String, dynamic> payload;

      if (entry.encryptedBlob != null && _crypto != null) {
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
