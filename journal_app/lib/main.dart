import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/auth_service.dart';
import 'services/journal_service.dart';
import 'services/crypto_service.dart';
import 'screens/auth_screen.dart';
import 'screens/journal_list_screen.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// BLOG SERIES: E2EE Journal App
///
/// This app is built incrementally across 6 steps:
///
///  Step 1 – No encryption.  Plain text in, plain text out.
///  Step 2 – Server-side encryption at rest (server holds the key).
///           Client is unchanged; server encrypts before persisting.
///  Step 3 – Client-side symmetric encryption.  Password → KDF → AES key.
///           Server only ever sees ciphertext.
///  Step 4 – Asymmetric keypair generation & storage.  Private key encrypted
///           locally with the Step 3 key before upload.
///  Step 5 – Hybrid encryption.  Each entry gets a random content key
///           encrypted with the author's own public key.
///  Step 6 – Sharing.  Content key re-encrypted for each recipient's
///           public key.  Server stores one encrypted key blob per share.
///
/// Each step's code is annotated with // [StepN] so you can follow the
/// progression without hunting through files.
/// ─────────────────────────────────────────────────────────────────────────────
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const JournalApp());
}

class JournalApp extends StatelessWidget {
  const JournalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProvider(create: (_) => CryptoService()),
        ChangeNotifierProxyProvider2<AuthService, CryptoService, JournalService>(
          create: (_) => JournalService(),
          update: (_, auth, crypto, journal) =>
              (journal ?? JournalService())..update(auth, crypto),
        ),
      ],
      child: MaterialApp(
        title: 'E2EE Journal',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(),
        home: const _AppRoot(),
      ),
    );
  }

  ThemeData _buildTheme() {
    const ink = Color(0xFF1A1A2E);
    const parchment = Color(0xFFF5F0E8);
    const accent = Color(0xFF8B6914);

    return ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.light(
        primary: ink,
        secondary: accent,
        surface: parchment,
        onSurface: ink,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: ink,
        foregroundColor: parchment,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: accent, width: 2),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: ink,
          foregroundColor: parchment,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

class _AppRoot extends StatelessWidget {
  const _AppRoot();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    if (auth.isLoggedIn) return const JournalListScreen();
    return const AuthScreen();
  }
}
