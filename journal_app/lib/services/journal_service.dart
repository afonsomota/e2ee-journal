import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import '../models/journal_entry.dart';
import 'auth_service.dart';

class JournalService extends ChangeNotifier {
  AuthService? _auth;

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

  void update(AuthService auth) {
    _auth = auth;
    if (auth.isLoggedIn) fetchAll();
  }

  Future<void> createEntry(String content) async {
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

  Future<void> fetchAll() async {
    _setLoading(true);
    try {
      final resp = await _dio.get('/entries');
      _entries = (resp.data as List)
          .map((j) => JournalEntry.fromJson(j as Map<String, dynamic>))
          .toList();
      notifyListeners();
    } on DioException catch (e) {
      _error = _extractError(e, 'Failed to fetch entries');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> updateEntry(String entryId, String newContent) async {
    _setLoading(true);
    try {
      await _dio.put('/entries/$entryId', data: {'content': newContent});
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

  void _setLoading(bool v) {
    _loading = v;
    notifyListeners();
  }

  String _extractError(DioException e, String fallback) {
    return (e.response?.data as Map<String, dynamic>?)?['detail'] as String? ??
        fallback;
  }
}
