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
  final _focusNode = FocusNode();
  bool _saving = false;
  bool _isBlank = true;

  // A believable first entry, in the user's own voice. Single source of
  // truth — shown in the starter card and inserted when it's tapped.
  static const _exampleEntry =
      'Today I installed Inner Apple. '
      'Tomorrow I’ll write one emotion I felt.';

  @override
  void initState() {
    super.initState();
    // Focusing the field enters "writing mode" — collapse the intro and
    // surface a compact example hint above the keyboard.
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() => setState(() {});

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // Seed the field with the example so the user can edit it instead of
  // facing a blank page, then drop them straight into writing.
  void _useExample() {
    _ctrl.text = _exampleEntry;
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    _isBlank = false;
    _focusNode.requestFocus();
    setState(() {});
  }

  // Rebuild only when the blank/non-blank boundary flips — not on every
  // keystroke — so typing stays smooth on device.
  void _handleTextChanged() {
    final blank = _ctrl.text.trim().isEmpty;
    if (blank != _isBlank) setState(() => _isBlank = blank);
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
    // because auth.isOfflineMode is now true.
  }

  void _goToSignIn() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Writing mode: the field is focused and the keyboard is up. We strip the
    // intro (brand, headline, prompt, date) down to a bare writing canvas.
    final writing = _focusNode.hasFocus;
    final isBlank = _isBlank;
    final motion = MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 220);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        // Tap anywhere outside the field to dismiss the keyboard.
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.opaque,
          child: Column(
            children: [
            // ── Brand bar — collapses in writing mode ──
            AnimatedSize(
              duration: motion,
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: writing
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: Row(
                        children: [
                          Image.asset('assets/logo.png',
                              width: 36, height: 36),
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
            ),

            // ── Content ──
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(24, writing ? 12 : 40, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Intro (headline + prompt) \u2014 collapses in writing
                    // mode for a distraction-free canvas.
                    AnimatedSize(
                      duration: motion,
                      curve: Curves.easeInOut,
                      alignment: Alignment.topCenter,
                      child: writing
                          ? const SizedBox(width: double.infinity)
                          : Column(
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
                                  'This is your private space. No account '
                                  'needed\u00a0\u2014 just start writing.',
                                  style: AppTypography.bodyMedium.copyWith(
                                    color: AppColors.outline,
                                    height: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 32),
                              ],
                            ),
                    ),

                    // Date label — always visible; the anchor for the entry,
                    // so it stays put even when the keyboard is up.
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
                      constraints: const BoxConstraints(minHeight: 132),
                      child: TextField(
                        controller: _ctrl,
                        focusNode: _focusNode,
                        maxLines: null,
                        onChanged: (_) => _handleTextChanged(),
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
                      ),
                    ),

                    // Starter example \u2014 only while the page is blank, so it
                    // nudges without cluttering once writing begins.
                    if (!writing && isBlank) ...[
                      const SizedBox(height: 12),
                      _StarterPrompt(
                        text: _exampleEntry,
                        onTap: _useExample,
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // ── Compact example hint — above the keyboard while blank ──
            if (writing && isBlank)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: _ExampleHint(
                  text: _exampleEntry,
                  onTap: _useExample,
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
                  // Sign-in link — hidden in writing mode to stay focused.
                  if (!writing) ...[
                    const SizedBox(height: 16),
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
                ],
              ),
            ),
          ],
          ),
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

// ── Starter Prompt ──
//
// A sample first entry the user can tap to begin with. Framed plainly as an
// example (gold eyebrow) and set in the journal's editorial italic, with a
// left archival margin rule — the "Quiet Archivist" signature.

class _StarterPrompt extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const _StarterPrompt({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Start with an example entry',
      child: Material(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Archival margin rule
                Container(width: 3, color: AppColors.tertiary),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Eyebrow — names it plainly as an example
                        Text(
                          'FOR EXAMPLE',
                          style: GoogleFonts.manrope(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2.0,
                            color: AppColors.tertiary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // The sample entry, in the journal's editorial voice
                        Text(
                          '“$text”',
                          style: GoogleFonts.newsreader(
                            fontSize: 17,
                            fontStyle: FontStyle.italic,
                            height: 1.5,
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Affordance — what a tap does
                        Row(
                          children: [
                            const Icon(
                              Icons.edit_outlined,
                              size: 15,
                              color: AppColors.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Tap to start with this',
                              style: GoogleFonts.manrope(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primary,
                              ),
                            ),
                          ],
                        ),
                      ],
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

// ── Example Hint (compact) ──
//
// The starter example condensed to one tappable line. Shown above the keyboard
// in writing mode, so the nudge stays in reach without the full card.

class _ExampleHint extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const _ExampleHint({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Start with an example entry',
      child: Material(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.edit_outlined,
                  size: 16,
                  color: AppColors.tertiary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'FOR EXAMPLE',
                        style: GoogleFonts.manrope(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2.0,
                          color: AppColors.tertiary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '“$text”',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.newsreader(
                          fontSize: 14,
                          fontStyle: FontStyle.italic,
                          color: AppColors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.arrow_forward,
                  size: 16,
                  color: AppColors.primary,
                ),
              ],
            ),
          ),
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
