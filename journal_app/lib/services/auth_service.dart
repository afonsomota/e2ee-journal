// services/auth_service.dart
//
// Handles registration, login, and session state.
//
// [Step 3] Password derives local encryption key via CryptoService.
// [Step 4] Registration generates an X25519 keypair; private key is encrypted
//          with the derived key before upload.  Login decrypts it back.

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';
import 'crypto_service.dart';

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

  // ── Step 1 (preserved for reference) ───────────────────────────────────────

  Future<bool> registerStep1(String username, String password) async {
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

  Future<bool> loginStep1(String username, String password) async {
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

  // ── Step 3+ Registration (with key derivation and keypair) ─────────────────

  Future<bool> register(
    String username,
    String password,
    CryptoService crypto,
  ) async {
    try {
      _error = null;

      // [Step 3] Derive local encryption key from password.
      await crypto.deriveKeyFromPassword(password, username);

      // [Step 4] Generate keypair; private key is encrypted with derived key.
      final keys = await crypto.generateAndStoreKeypair();

      final resp = await _dio.post('/auth/register', data: {
        'username': username,
        'password': password,
        'public_key': keys.publicKey,
        'encrypted_private_key': keys.encryptedPrivateKey,
      });

      return _handleAuthResponse(resp.data);
    } on DioException catch (e) {
      _error = e.response?.data?['detail'] ?? 'Registration failed';
      notifyListeners();
      return false;
    }
  }

  // ── Step 3+ Login ──────────────────────────────────────────────────────────

  Future<bool> login(
    String username,
    String password,
    CryptoService crypto,
  ) async {
    try {
      _error = null;

      // [Step 3] Derive key locally first.
      await crypto.deriveKeyFromPassword(password, username);

      final resp = await _dio.post('/auth/login', data: {
        'username': username,
        'password': password,
      });

      if (!_handleAuthResponse(resp.data)) return false;

      // [Step 4] Server returns the encrypted private key; decrypt locally.
      final userData = resp.data['user'] as Map<String, dynamic>;
      if (userData['encrypted_private_key'] != null) {
        await crypto.unlockPrivateKey(
            userData['encrypted_private_key'] as String);
        await crypto.loadPublicKey(userData['public_key'] as String);
      }

      return true;
    } on DioException catch (e) {
      _error = e.response?.data?['detail'] ?? 'Login failed';
      notifyListeners();
      return false;
    }
  }

  // ── Shared ─────────────────────────────────────────────────────────────────

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

  Future<void> logout(CryptoService crypto) async {
    _currentUser = null;
    _token = null;
    _isLoggedIn = false;
    await crypto.clearKeys();
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

  Future<bool> tryRestoreSession(CryptoService crypto) async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_kToken);
    final userId = prefs.getString(_kUserId);
    final username = prefs.getString(_kUsername);

    if (_token == null || userId == null || username == null) return false;

    _currentUser = User(id: userId, username: username);

    final cryptoRestored = await crypto.tryRestoreSession();
    if (!cryptoRestored) {
      await logout(crypto);
      return false;
    }

    _isLoggedIn = true;
    notifyListeners();
    return true;
  }
}
