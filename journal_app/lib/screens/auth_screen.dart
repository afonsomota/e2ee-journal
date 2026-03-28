// screens/auth_screen.dart

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/crypto_service.dart';
import '../theme.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit(bool isRegister) async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;

    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields')),
      );
      return;
    }

    if (isRegister && password.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Password must be at least 8 characters')),
      );
      return;
    }

    setState(() => _loading = true);

    final auth = context.read<AuthService>();
    final crypto = context.read<CryptoService>();

    final ok = isRegister
        ? await auth.register(username, password, crypto)
        : await auth.login(username, password, crypto);

    if (mounted) {
      setState(() => _loading = false);
      if (!ok && auth.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(auth.error!),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Branding
                  Center(
                    child: Image.asset('assets/logo.png', width: 80, height: 80),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      'InnerApple',
                      style: GoogleFonts.newsreader(
                        fontSize: 36,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.shield_outlined,
                            size: 12, color: AppColors.outline),
                        const SizedBox(width: 6),
                        Text(
                          'END-TO-END ENCRYPTED',
                          style: AppTypography.labelSmall.copyWith(
                            color: AppColors.outline,
                            letterSpacing: 2.5,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 40),

                  // Form card
                  Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Tabs
                        AnimatedBuilder(
                          animation: _tabs,
                          builder: (_, _) => Row(
                            children: [
                              _TabButton(
                                label: 'Sign In',
                                isActive: _tabs.index == 0,
                                onTap: () =>
                                    _tabs.animateTo(0),
                              ),
                              const SizedBox(width: 24),
                              _TabButton(
                                label: 'Register',
                                isActive: _tabs.index == 1,
                                onTap: () =>
                                    _tabs.animateTo(1),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 28),

                        // Username
                        Text(
                          'USERNAME',
                          style: AppTypography.labelSmall.copyWith(
                            color: AppColors.outline,
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _usernameCtrl,
                          decoration: const InputDecoration(
                            hintText: 'Enter your username',
                          ),
                          textInputAction: TextInputAction.next,
                          autocorrect: false,
                          style: AppTypography.bodyLarge,
                        ),

                        const SizedBox(height: 20),

                        // Password
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'PASSWORD',
                              style: AppTypography.labelSmall.copyWith(
                                color: AppColors.outline,
                              ),
                            ),
                            AnimatedBuilder(
                              animation: _tabs,
                              builder: (_, _) => _tabs.index == 0
                                  ? GestureDetector(
                                      onTap: () {},
                                      child: Text(
                                        'FORGOT?',
                                        style:
                                            AppTypography.labelSmall.copyWith(
                                          color: AppColors.primary,
                                          letterSpacing: 1.0,
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _passwordCtrl,
                          decoration: InputDecoration(
                            hintText: '\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022',
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                color: AppColors.outline,
                              ),
                              onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword),
                            ),
                          ),
                          obscureText: _obscurePassword,
                          textInputAction: TextInputAction.done,
                          style: AppTypography.bodyLarge,
                          onSubmitted: (_) {
                            _submit(_tabs.index == 1);
                          },
                        ),

                        const SizedBox(height: 16),

                        // KDF warning (register tab)
                        AnimatedBuilder(
                          animation: _tabs,
                          builder: (_, _) {
                            if (_tabs.index != 1) {
                              return const SizedBox.shrink();
                            }
                            return Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: AppColors.secondaryFixed
                                    .withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.warning_rounded,
                                      color: AppColors.secondary, size: 20),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'CRITICAL SECURITY NOTE',
                                          style: GoogleFonts.manrope(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 1.5,
                                            color: AppColors.secondary,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Your password is your unique encryption key. '
                                          'If lost, your data cannot be recovered by '
                                          'anyone\u2014even us.',
                                          style: GoogleFonts.manrope(
                                            fontSize: 12,
                                            color: const Color(0xFF541100),
                                            height: 1.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),

                        // Loading state
                        if (_loading) ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              _BouncingDots(),
                              const SizedBox(width: 10),
                              Text(
                                'DERIVING SECURE LOCAL KEY\u2026',
                                style: AppTypography.labelSmall.copyWith(
                                  color: AppColors.outline,
                                ),
                              ),
                            ],
                          ),
                        ],

                        const SizedBox(height: 24),

                        // Continue button (gradient)
                        AnimatedBuilder(
                          animation: _tabs,
                          builder: (_, _) {
                            final isRegister = _tabs.index == 1;
                            return _GradientButton(
                              label: 'CONTINUE',
                              icon: Icons.arrow_forward,
                              onPressed:
                                  _loading ? null : () => _submit(isRegister),
                            );
                          },
                        ),

                        // Divider "or"
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Row(
                            children: [
                              Expanded(
                                child: Container(
                                  height: 1,
                                  color: AppColors.outlineVariant
                                      .withValues(alpha: 0.3),
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: Text(
                                  'OR',
                                  style: AppTypography.labelSmall.copyWith(
                                    color: AppColors.outline,
                                    letterSpacing: 3.0,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Container(
                                  height: 1,
                                  color: AppColors.outlineVariant
                                      .withValues(alpha: 0.3),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Continue with Google
                        Material(
                          color: AppColors.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: _loading
                                ? null
                                : () {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content:
                                            Text('Google sign-in coming soon'),
                                      ),
                                    );
                                  },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.g_mobiledata,
                                      size: 24,
                                      color: AppColors.onSurface),
                                  const SizedBox(width: 8),
                                  Text(
                                    'CONTINUE WITH GOOGLE',
                                    style: GoogleFonts.manrope(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.5,
                                      color: AppColors.onSurface,
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

                  const SizedBox(height: 24),

                  // Footer
                  Center(
                    child: Text(
                      'By continuing, you agree to our Privacy Charter.\n'
                      'InnerApple uses Zero-Knowledge architecture.',
                      textAlign: TextAlign.center,
                      style: AppTypography.bodySmall.copyWith(
                        color: AppColors.outline,
                        height: 1.6,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Supporting Widgets ──

class _TabButton extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.newsreader(
              fontSize: 24,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
              color: isActive ? AppColors.onSurface : AppColors.outline,
            ),
          ),
          const SizedBox(height: 4),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 2,
            width: isActive ? 32 : 0,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ),
    );
  }
}

class _GradientButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  const _GradientButton({
    required this.label,
    required this.icon,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Ink(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.primary, AppColors.primaryContainer],
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: GoogleFonts.manrope(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.0,
                    color: AppColors.onPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(icon, size: 18, color: AppColors.onPrimary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BouncingDots extends StatefulWidget {
  @override
  State<_BouncingDots> createState() => _BouncingDotsState();
}

class _BouncingDotsState extends State<_BouncingDots>
    with TickerProviderStateMixin {
  late final List<AnimationController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(3, (i) {
      final ctrl = AnimationController(
        duration: const Duration(milliseconds: 600),
        vsync: this,
      );
      Future.delayed(Duration(milliseconds: i * 200), () {
        if (mounted) ctrl.repeat(reverse: true);
      });
      return ctrl;
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _controllers.map((ctrl) {
        return AnimatedBuilder(
          animation: ctrl,
          builder: (_, _) => Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.4 + ctrl.value * 0.6),
              shape: BoxShape.circle,
            ),
          ),
        );
      }).toList(),
    );
  }
}
