// services/auth_service.dart
//
// Handles registration, login, and session state.
// The password never leaves this device in plaintext — it is fed directly
// into CryptoService.deriveKeyFromPassword().

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/user.dart';
import 'crypto_service.dart';

const _kToken = 'auth_token';
const _kUserId = 'auth_user_id';
const _kUsername = 'auth_username';
const _kOfflineMode = 'offline_mode';

class AuthService extends ChangeNotifier {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  User? _currentUser;
  String? _token;
  bool _isLoggedIn = false;
  bool _isOfflineMode = false;
  String? _error;

  User? get currentUser => _currentUser;
  String? get token => _token;
  bool get isLoggedIn => _isLoggedIn;
  bool get isOfflineMode => _isOfflineMode;
  String? get error => _error;

  final Dio _dio = Dio(BaseOptions(
    baseUrl: apiBaseUrl,
    connectTimeout: const Duration(seconds: 10),
  ));

  Future<bool> register(
    String username,
    String password,
    CryptoService crypto,
  ) async {
    try {
      _error = null;

      // Derive local encryption key from password BEFORE any network call.
      // Even if we sniff the traffic, the key is never transmitted.
      await crypto.deriveKeyFromPassword(password, username);

      // Generate keypair; private key is encrypted with derived key.
      final keys = await crypto.generateAndStoreKeypair();

      // Send registration data to server.
      // The server stores: username, bcrypt(password), publicKey,
      //                    encryptedPrivateKey (opaque blob to the server).
      final resp = await _dio.post('/auth/register', data: {
        'username': username,
        'password': password, // server-side auth only (will be bcrypt'd)
        'public_key': keys.publicKey,
        'encrypted_private_key': keys.encryptedPrivateKey,
      });

      final ok = _handleAuthResponse(resp.data);
      if (ok) await _exitOfflineMode();
      return ok;
    } on DioException catch (e) {
      _error = e.response?.data?['detail'] ?? 'Registration failed';
      notifyListeners();
      return false;
    }
  }

  Future<bool> login(
    String username,
    String password,
    CryptoService crypto,
  ) async {
    try {
      _error = null;

      await crypto.deriveKeyFromPassword(password, username);

      final resp = await _dio.post('/auth/login', data: {
        'username': username,
        'password': password,
      });

      if (!_handleAuthResponse(resp.data)) return false;

      // Server returns the user's encrypted private key and public key.
      final userData = resp.data['user'] as Map<String, dynamic>;
      if (userData['encrypted_private_key'] != null) {
        await crypto.unlockPrivateKey(
            userData['encrypted_private_key'] as String);
        await crypto.loadPublicKey(userData['public_key'] as String);
      }

      await _exitOfflineMode();
      return true;
    } on DioException catch (e) {
      _error = e.response?.data?['detail'] ?? 'Login failed';
      notifyListeners();
      return false;
    }
  }

  // ── Offline mode ───────────────────────────────────────────────────────────

  Future<void> enterOfflineMode() async {
    _isOfflineMode = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOfflineMode, true);
    notifyListeners();
  }

  Future<void> _exitOfflineMode() async {
    _isOfflineMode = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kOfflineMode, false);
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
    await _secureStorage.delete(key: _kToken);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUserId);
    await prefs.remove(_kUsername);
    notifyListeners();
  }

  Future<void> _persist() async {
    if (_token != null) {
      await _secureStorage.write(key: _kToken, value: _token!);
    }
    if (_currentUser != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUserId, _currentUser!.id);
      await prefs.setString(_kUsername, _currentUser!.username);
    }
  }

  Future<bool> tryRestoreSession(CryptoService crypto) async {
    final prefs = await SharedPreferences.getInstance();

    // Check if user was in offline mode.
    _isOfflineMode = prefs.getBool(_kOfflineMode) ?? false;

    // Read token from secure storage (preferred), with migration from
    // SharedPreferences for users upgrading from the old storage location.
    _token = await _secureStorage.read(key: _kToken);
    if (_token == null) {
      final oldToken = prefs.getString(_kToken);
      if (oldToken != null) {
        _token = oldToken;
        await _secureStorage.write(key: _kToken, value: oldToken);
        await prefs.remove(_kToken);
      }
    }

    final userId = prefs.getString(_kUserId);
    final username = prefs.getString(_kUsername);

    if (_token == null || userId == null || username == null) return false;

    _currentUser = User(id: userId, username: username);

    final cryptoRestored = await crypto.tryRestoreSession();
    if (!cryptoRestored) {
      // Crypto session could not be restored — force re-login.
      await logout(crypto);
      return false;
    }

    _isLoggedIn = true;
    notifyListeners();
    return true;
  }
}
