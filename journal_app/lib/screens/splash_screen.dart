// screens/splash_screen.dart

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';

class SplashScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const SplashScreen({super.key, required this.onComplete});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _logoController;
  late final AnimationController _textController;
  late final AnimationController _fadeOutController;

  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _titleOpacity;
  late final Animation<Offset> _titleSlide;
  late final Animation<double> _taglineOpacity;
  late final Animation<Offset> _taglineSlide;
  late final Animation<double> _fadeOut;

  @override
  void initState() {
    super.initState();

    _logoController = AnimationController(
      duration: const Duration(milliseconds: 900),
      vsync: this,
    );

    _logoScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOutBack),
    );

    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );

    _textController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _titleOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _textController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );

    _titleSlide = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _textController,
        curve: const Interval(0.0, 0.7, curve: Curves.easeOutCubic),
      ),
    );

    _taglineOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _textController,
        curve: const Interval(0.3, 0.8, curve: Curves.easeOut),
      ),
    );

    _taglineSlide = Tween<Offset>(
      begin: const Offset(0, 0.4),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _textController,
        curve: const Interval(0.3, 0.9, curve: Curves.easeOutCubic),
      ),
    );

    _fadeOutController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _fadeOut = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _fadeOutController, curve: Curves.easeIn),
    );

    _startSequence();
  }

  Future<void> _startSequence() async {
    await Future.delayed(const Duration(milliseconds: 200));
    _logoController.forward();
    await Future.delayed(const Duration(milliseconds: 500));
    _textController.forward();
    await Future.delayed(const Duration(milliseconds: 1600));
    await _fadeOutController.forward();
    widget.onComplete();
  }

  @override
  void dispose() {
    _logoController.dispose();
    _textController.dispose();
    _fadeOutController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _fadeOut,
      builder: (_, __) => Opacity(
        opacity: _fadeOut.value,
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo
                AnimatedBuilder(
                  animation: _logoController,
                  builder: (_, __) => Opacity(
                    opacity: _logoOpacity.value,
                    child: Transform.scale(
                      scale: _logoScale.value,
                      child: Image.asset(
                        'assets/logo.png',
                        width: 140,
                        height: 140,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                // App title — serif
                AnimatedBuilder(
                  animation: _textController,
                  builder: (_, __) => SlideTransition(
                    position: _titleSlide,
                    child: Opacity(
                      opacity: _titleOpacity.value,
                      child: Text(
                        'InnerApple',
                        style: GoogleFonts.newsreader(
                          fontSize: 36,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 8),

                // Tagline
                AnimatedBuilder(
                  animation: _textController,
                  builder: (_, __) => SlideTransition(
                    position: _taglineSlide,
                    child: Opacity(
                      opacity: _taglineOpacity.value,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.shield_outlined,
                              size: 14,
                              color: AppColors.primary.withValues(alpha: 0.5)),
                          const SizedBox(width: 6),
                          Text(
                            'END-TO-END ENCRYPTED',
                            style: AppTypography.labelSmall.copyWith(
                              color: AppColors.outline,
                              letterSpacing: 3.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
