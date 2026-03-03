import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';

const _kToken = 'auth_token';
const _kUserId = 'auth_user_id';
const _kUsername = 'auth_username';

class AuthService extends ChangeNotifier {
  User? _currentUser;
  String? _token;
  bool _isLoggedIn = false;
  String? _error;

  User? get currentUser => _currentUser;
  String? get token => _token;
  bool get isLoggedIn => _isLoggedIn;
  String? get error => _error;

  final Dio _dio = Dio(BaseOptions(
    baseUrl: 'http://localhost:8000',
    connectTimeout: const Duration(seconds: 10),
  ));

  Future<bool> register(String username, String password) async {
    try {
      final resp = await _dio.post('/auth/register', data: {
        'username': username,
        'password': password,
      });
      return _handleAuthResponse(resp.data);
    } on DioException catch (e) {
      _error = e.response?.data?['detail'] ?? 'Registration failed';
      notifyListeners();
      return false;
    }
  }

  Future<bool> login(String username, String password) async {
    try {
      final resp = await _dio.post('/auth/login', data: {
        'username': username,
        'password': password,
      });
      return _handleAuthResponse(resp.data);
    } on DioException catch (e) {
      _error = e.response?.data?['detail'] ?? 'Login failed';
      notifyListeners();
      return false;
    }
  }

  bool _handleAuthResponse(Map<String, dynamic> data) {
    _token = data['access_token'] as String?;
    final userJson = data['user'] as Map<String, dynamic>?;
    if (_token == null || userJson == null) {
      _error = 'Unexpected server response';
      notifyListeners();
      return false;
    }
    _currentUser = User.fromJson(userJson);
    _isLoggedIn = true;
    _error = null;
    _persist();
    notifyListeners();
    return true;
  }

  Future<void> logout() async {
    _currentUser = null;
    _token = null;
    _isLoggedIn = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (_token != null) await prefs.setString(_kToken, _token!);
    if (_currentUser != null) {
      await prefs.setString(_kUserId, _currentUser!.id);
      await prefs.setString(_kUsername, _currentUser!.username);
    }
  }

  Future<bool> tryRestoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_kToken);
    final userId = prefs.getString(_kUserId);
    final username = prefs.getString(_kUsername);

    if (_token == null || userId == null || username == null) return false;

    _currentUser = User(id: userId, username: username);
    _isLoggedIn = true;
    notifyListeners();
    return true;
  }
}
