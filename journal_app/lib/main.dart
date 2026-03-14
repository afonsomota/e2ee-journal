import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/auth_service.dart';
import 'services/emotion_service.dart';
import 'services/journal_service.dart';
import 'services/crypto_service.dart';
import 'screens/auth_screen.dart';
import 'screens/journal_list_screen.dart';

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
        ChangeNotifierProvider(create: (_) => EmotionService()..initialize()),
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
