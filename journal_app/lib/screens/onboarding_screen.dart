// screens/onboarding_screen.dart
//
// First-launch experience.  No login required — the user writes their
// first journal entry immediately.  After saving, a warm dialog
// encourages account creation for cross-device sync and sharing.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/journal_service.dart';
import '../services/local_storage_service.dart';
import '../theme.dart';
import 'auth_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _ctrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _saveFirstEntry() async {
    final content = _ctrl.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Write something before saving')),
      );
      return;
    }

    setState(() => _saving = true);

    final auth = context.read<AuthService>();
    final journal = context.read<JournalService>();
    final localStorage = LocalStorageService();

    // Enter offline mode and persist onboarding state.
    await auth.enterOfflineMode();
    await localStorage.setOnboardingCompleted(true);

    // Create the first local entry.
    await journal.createEntryLocal(content);

    if (!mounted) return;
    setState(() => _saving = false);

    // Show the registration encouragement dialog.
    await _showRegistrationDialog();
  }

  Future<void> _showRegistrationDialog() async {
    if (!mounted) return;

    final wantsAccount = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const _RegistrationEncouragementDialog(),
    );

    if (!mounted) return;

    if (wantsAccount == true) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const AuthScreen()),
      );
    }
    // If "Maybe later" — _AppRoot will rebuild to show JournalListScreen
    // because auth.isOfflineMode is now true and onboarding is completed.
  }

  void _goToSignIn() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar with branding ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: [
                  Image.asset('assets/logo.png', width: 36, height: 36),
                  const SizedBox(width: 10),
                  Text(
                    'InnerApple',
                    style: GoogleFonts.newsreader(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
            ),

            // ── Content ──
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Headline
                    Text(
                      'How was your day?',
                      style: GoogleFonts.newsreader(
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        fontStyle: FontStyle.italic,
                        color: AppColors.onSurface,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Subtext
                    Text(
                      'This is your private space. No account needed\u00a0\u2014 '
                      'just start writing.',
                      style: AppTypography.bodyMedium.copyWith(
                        color: AppColors.outline,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Date label
                    Text(
                      _formatDate(DateTime.now()).toUpperCase(),
                      style: GoogleFonts.manrope(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 2.0,
                        color: AppColors.tertiary,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Text field
                    Container(
                      constraints: const BoxConstraints(minHeight: 200),
                      child: TextField(
                        controller: _ctrl,
                        maxLines: null,
                        decoration: InputDecoration(
                          hintText:
                              'Write about your day, a thought, a feeling\u2026',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          hintStyle: GoogleFonts.manrope(
                            fontSize: 17,
                            color: AppColors.onSurfaceVariant
                                .withValues(alpha: 0.3),
                          ),
                        ),
                        style: GoogleFonts.manrope(
                          fontSize: 17,
                          height: 1.8,
                          color: AppColors.onSurfaceVariant,
                        ),
                        autofocus: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Bottom section ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                children: [
                  // Save button
                  SizedBox(
                    width: double.infinity,
                    child: _saving
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: CircularProgressIndicator(
                                color: AppColors.primary,
                              ),
                            ),
                          )
                        : _GradientButton(
                            label: 'SAVE MY FIRST ENTRY',
                            icon: Icons.arrow_forward,
                            onPressed: _saveFirstEntry,
                          ),
                  ),
                  const SizedBox(height: 16),

                  // Sign-in link
                  GestureDetector(
                    onTap: _goToSignIn,
                    child: Text(
                      'Already have an account? Sign in',
                      style: AppTypography.bodySmall.copyWith(
                        color: AppColors.outline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }
}

// ── Registration Encouragement Dialog ──

class _RegistrationEncouragementDialog extends StatelessWidget {
  const _RegistrationEncouragementDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.primaryContainer.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.cloud_sync_outlined,
                size: 28,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 20),

            // Headline
            Text(
              'Your words are safe here',
              textAlign: TextAlign.center,
              style: GoogleFonts.newsreader(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                fontStyle: FontStyle.italic,
                color: AppColors.onSurface,
              ),
            ),
            const SizedBox(height: 12),

            // Body
            Text(
              'Right now your journal lives only on this device. '
              'Create a free account to sync your entries across all '
              'your devices, share thoughts with trusted people, and '
              'protect everything with end-to-end encryption\u00a0\u2014 '
              'so only you can read what you write.',
              textAlign: TextAlign.center,
              style: AppTypography.bodyMedium.copyWith(height: 1.6),
            ),
            const SizedBox(height: 24),

            // Primary action
            SizedBox(
              width: double.infinity,
              child: _GradientButton(
                label: 'CREATE FREE ACCOUNT',
                icon: Icons.person_add_outlined,
                onPressed: () => Navigator.pop(context, true),
              ),
            ),
            const SizedBox(height: 8),

            // Secondary action
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(
                  'Maybe later',
                  style: GoogleFonts.manrope(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.outline,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Gradient Button (reused pattern) ──

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
