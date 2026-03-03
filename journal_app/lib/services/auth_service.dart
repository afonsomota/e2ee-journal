// services/auth_service.dart
//
// Handles registration, login, and session state.
// From Step 3 onward, the password never leaves this device in plaintext —
// it is fed directly into CryptoService.deriveKeyFromPassword().
//
// BLOG NOTE (Step 3): Compare this to a conventional auth flow where the
// password is hashed server-side (bcrypt/scrypt).  Here the password does TWO
// jobs: it authenticates the user (via a separate auth token) AND it derives
// the encryption key.  These are independent operations and that's intentional
// — auth and encryption are separate concerns.

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
    baseUrl: 'http://localhost:8000', // Point to your FastAPI server
    connectTimeout: const Duration(seconds: 10),
  ));

  // ── Step 1 ─────────────────────────────────────────────────────────────────
  // Basic registration.  Username + password, server creates the user.

  Future<bool> registerStep1(String username, String password) async {
    try {
      final resp = await _dio.post('/auth/register', data: {
        'username': username,
        'password': password, // [Step1] password sent to server for hashing
      });
      return _handleAuthResponse(resp.data);
    } on DioException catch (e) {
      _error = e.response?.data?['detail'] ?? 'Registration failed';
      notifyListeners();
      return false;
    }
  }

  // ── Step 3+ ────────────────────────────────────────────────────────────────
  // Registration with client-side key derivation.
  // The password still goes to the server for authentication (bcrypt there),
  // but CryptoService also derives the local encryption key from it.
  //
  // BLOG NOTE: The server never sees the encryption key — only the auth token
  // it issues.  The password leaves the device once for auth, but key
  // derivation happens locally before that call.

  Future<bool> register(
    String username,
    String password,
    CryptoService crypto,
  ) async {
    try {
      _error = null;

      // [Step3] Derive local encryption key from password BEFORE any network
      // call.  Even if we sniff the traffic, the key is never transmitted.
      await crypto.deriveKeyFromPassword(password, username);

      // [Step4] Generate keypair; private key is encrypted with derived key.
      final keys = await crypto.generateAndStoreKeypair();

      // Send registration data to server.
      // The server stores: username, bcrypt(password), publicKey,
      //                    encryptedPrivateKey (opaque blob to the server).
      final resp = await _dio.post('/auth/register', data: {
        'username': username,
        'password': password, // server-side auth only (will be bcrypt'd)
        'public_key': keys.publicKey,                       // [Step4]
        'encrypted_private_key': keys.encryptedPrivateKey,  // [Step4]
      });

      return _handleAuthResponse(resp.data);
    } on DioException catch (e) {
      _error = e.response?.data?['detail'] ?? 'Registration failed';
      notifyListeners();
      return false;
    }
  }

  // ── Step 1 login (no crypto) ───────────────────────────────────────────────
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

  // ── Step 3+ login ──────────────────────────────────────────────────────────
  // After auth, fetch the encrypted private key from the server and decrypt it
  // locally.  The server returns an opaque blob; we decrypt with the derived
  // key.  If the password is wrong, decryption fails — this is the correct
  // behaviour.
  Future<bool> login(
    String username,
    String password,
    CryptoService crypto,
  ) async {
    try {
      _error = null;

      // [Step3] Derive key locally first.
      await crypto.deriveKeyFromPassword(password, username);

      final resp = await _dio.post('/auth/login', data: {
        'username': username,
        'password': password,
      });

      if (!_handleAuthResponse(resp.data)) return false;

      // [Step4] Server returns the user's encrypted private key and public key.
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
      // Crypto session could not be restored — force re-login.
      await logout(crypto);
      return false;
    }

    _isLoggedIn = true;
    notifyListeners();
    return true;
  }
}
