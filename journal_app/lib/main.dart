import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/auth_service.dart';
import 'services/emotion_service.dart';
import 'services/journal_service.dart';
import 'services/crypto_service.dart';
import 'screens/auth_screen.dart';
import 'screens/journal_list_screen.dart';
import 'screens/splash_screen.dart';
import 'theme.dart';

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
        ChangeNotifierProxyProvider<AuthService, EmotionService>(
          create: (_) => EmotionService(),
          update: (_, auth, emotion) =>
              (emotion ?? EmotionService())..update(auth),
        ),
      ],
      child: MaterialApp(
        title: 'InnerApple',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const _AppRoot(),
      ),
    );
  }
}

class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  bool _showSplash = true;

  @override
  Widget build(BuildContext context) {
    if (_showSplash) {
      return SplashScreen(
        onComplete: () => setState(() => _showSplash = false),
      );
    }

    final auth = context.watch<AuthService>();
    if (auth.isLoggedIn) return const JournalListScreen();
    return const AuthScreen();
  }
}
